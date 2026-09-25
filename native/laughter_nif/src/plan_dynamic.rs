//! A bounded native worker for dynamic element decisions. Only this opt-in path
//! needs an OS thread: the parser must pause while the BEAM remains responsive.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use rustler::{Atom, Binary, Encoder, Env, LocalPid, NifResult, OwnedEnv, ResourceArc, Term};

use rustler::env::SavedTerm;

use crate::plan::{
    apply_mutation, build_with_handlers, rule_handlers, Mutation, Rule, WorkerOptions,
};
use crate::plan_stream::OutputBuffer;
use crate::{atoms, OutputSink};

include!("generated_events.rs");

pub struct DynamicSession {
    channels: Mutex<Option<Channels>>,
    cancelled: Arc<AtomicBool>,
    max_input: usize,
}

struct Channels {
    commands: mpsc::SyncSender<Command>,
    replies: mpsc::SyncSender<Reply>,
}

enum Command {
    Write(u64, Vec<u8>),
    Finish(u64),
}

struct Reply {
    id: u64,
    mutations: Vec<Mutation>,
}

struct Notifier {
    pid: LocalPid,
    env: OwnedEnv,
    token: SavedTerm,
}

impl Notifier {
    fn send(&self, event: impl for<'a> FnOnce(Env<'a>) -> Term<'a>) -> bool {
        self.env.run(|token_env| {
            let token = self.token.load(token_env);
            OwnedEnv::new()
                .send_and_clear(&self.pid, |env| {
                    worker_envelope(env, token.in_env(env), event(env))
                })
                .is_ok()
        })
    }

    fn error(&self, reason: &str) {
        self.send(|env| worker_error(env, reason.encode(env)));
    }
}

fn error(reason: impl Into<String>) -> rustler::Error {
    rustler::Error::Term(Box::new(reason.into()))
}

impl Drop for DynamicSession {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        // Dropping the only senders also wakes an idle worker or waiting handler.
    }
}

pub fn dynamic_new_impl(
    rules: Vec<Rule>,
    selector: String,
    options: WorkerOptions,
    pid: LocalPid,
    token: Term<'_>,
) -> NifResult<(Atom, ResourceArc<DynamicSession>)> {
    if options.chunk_size == 0
        || options.max_output_bytes == 0
        || options.max_memory == 0
        || options.reply_timeout == 0
    {
        return Err(error("session limits must be positive"));
    }
    let mut handlers = rule_handlers(rules).map_err(error)?;
    let selector = selector
        .parse::<lol_html::Selector>()
        .map_err(|e| error(format!("invalid selector: {e}")))?;
    let token_env = OwnedEnv::new();
    let saved_token = token_env.save(token);
    let notify = Arc::new(Mutex::new(Notifier {
        pid,
        env: token_env,
        token: saved_token,
    }));
    let (commands, command_rx) = mpsc::sync_channel(1);
    let (replies, reply_rx) = mpsc::sync_channel::<Reply>(1);
    let cancelled = Arc::new(AtomicBool::new(false));
    let handler_cancelled = Arc::clone(&cancelled);
    let handler_notify = Arc::clone(&notify);
    let timeout = Duration::from_millis(options.reply_timeout as u64);
    let mut request_id = 0_u64;

    handlers.push((
        std::borrow::Cow::Owned(selector),
        lol_html::send::ElementContentHandlers::default().element(
            move |element: &mut lol_html::send::Element<'_, '_>| {
                if handler_cancelled.load(Ordering::Acquire) {
                    return Err("session cancelled".into());
                }
                // Native rules run first. Do not ask Elixir about removed nodes.
                if element.removed() {
                    return Ok(());
                }
                request_id += 1;
                let tag = element.tag_name();
                let attrs: Vec<_> = element
                    .attributes()
                    .iter()
                    .map(|attr| (attr.name(), attr.value()))
                    .collect();
                let sent = handler_notify
                    .lock()
                    .unwrap()
                    .send(|env| worker_element(env, request_id, tag, attrs));
                if !sent {
                    return Err("session unavailable".into());
                }
                let reply = reply_rx.recv_timeout(timeout).map_err(|err| match err {
                    mpsc::RecvTimeoutError::Timeout => "reply timeout",
                    mpsc::RecvTimeoutError::Disconnected => "session cancelled",
                })?;
                if reply.id != request_id {
                    return Err("unexpected native reply".into());
                }
                if handler_cancelled.load(Ordering::Acquire) {
                    return Err("session cancelled".into());
                }
                for mutation in reply.mutations {
                    apply_mutation(element, &mutation)?;
                }
                Ok(())
            },
        ),
    ));

    let output = Arc::new(Mutex::new(OutputBuffer::new(options.max_output_bytes)?));
    let sink_output = Arc::clone(&output);
    let sink: OutputSink = Box::new(move |bytes| sink_output.lock().unwrap().write(bytes));
    let mut rewriter =
        build_with_handlers(handlers, options.encoding, options.max_memory, sink).map_err(error)?;
    let worker_cancelled = Arc::clone(&cancelled);
    let worker = crate::diagnostics::Allocation::worker();
    std::thread::Builder::new()
        .name("laughter-rewriter".into())
        .spawn(move || {
            let _worker = worker;
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                while let Ok(command) = command_rx.recv() {
                    if worker_cancelled.load(Ordering::Acquire) {
                        break;
                    }
                    let (id, finished, result) = match command {
                        Command::Write(id, input) => (id, false, rewriter.write(&input)),
                        Command::Finish(id) => {
                            let result = rewriter.end();
                            emit_result(&notify, &output, id, true, result);
                            return;
                        }
                    };
                    if !emit_result(&notify, &output, id, finished, result) {
                        break;
                    }
                }
            }));
            if result.is_err() {
                notify
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .error("native worker panicked");
            }
        })
        .map_err(|e| error(e.to_string()))?;

    Ok((
        atoms::ok(),
        ResourceArc::new(DynamicSession {
            channels: Mutex::new(Some(Channels { commands, replies })),
            cancelled,
            max_input: options.chunk_size,
        }),
    ))
}

fn emit_result(
    notify: &Mutex<Notifier>,
    output: &Mutex<OutputBuffer>,
    id: u64,
    finished: bool,
    result: Result<(), lol_html::errors::RewritingError>,
) -> bool {
    let notify = notify.lock().unwrap();
    if let Err(reason) = result {
        notify.error(&reason.to_string());
        return false;
    }
    let mut succeeded = true;
    let sent = notify.send(|env| match output.lock().unwrap().drain(env) {
        Ok((_, binary)) => worker_output(env, id, binary, finished),
        Err(rustler::Error::Term(reason)) => {
            succeeded = false;
            worker_error(env, reason.encode(env))
        }
        Err(_) => {
            succeeded = false;
            worker_error(env, "output allocation failed".encode(env))
        }
    });
    sent && succeeded
}

pub fn dynamic_write_impl(
    session: ResourceArc<DynamicSession>,
    id: u64,
    input: Binary<'_>,
) -> NifResult<Atom> {
    if input.len() > session.max_input {
        return Err(error("rewrite input chunk limit exceeded"));
    }
    let channels = session
        .channels
        .lock()
        .map_err(|_| error("lock poisoned"))?;
    let channels = channels.as_ref().ok_or_else(|| error("session closed"))?;
    channels
        .commands
        .try_send(Command::Write(id, input.as_slice().to_vec()))
        .map_err(|_| error("worker busy or closed"))
        .map(|_| atoms::ok())
}

pub fn dynamic_finish_impl(session: ResourceArc<DynamicSession>, id: u64) -> NifResult<Atom> {
    let channels = session
        .channels
        .lock()
        .map_err(|_| error("lock poisoned"))?;
    let channels = channels.as_ref().ok_or_else(|| error("session closed"))?;
    channels
        .commands
        .try_send(Command::Finish(id))
        .map_err(|_| error("worker busy or closed"))
        .map(|_| atoms::ok())
}

pub fn dynamic_reply_impl(
    session: ResourceArc<DynamicSession>,
    id: u64,
    mutations: Vec<Mutation>,
) -> NifResult<Atom> {
    let channels = session
        .channels
        .lock()
        .map_err(|_| error("lock poisoned"))?;
    let channels = channels.as_ref().ok_or_else(|| error("session closed"))?;
    channels
        .replies
        .try_send(Reply { id, mutations })
        .map_err(|_| error("worker busy or closed"))
        .map(|_| atoms::ok())
}

pub fn dynamic_close_impl(session: ResourceArc<DynamicSession>) -> Atom {
    session.cancelled.store(true, Ordering::Release);
    session
        .channels
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .take();
    atoms::ok()
}
