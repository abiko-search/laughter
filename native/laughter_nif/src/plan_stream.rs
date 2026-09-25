//! Bounded, synchronous streaming sessions. The resource can move between BEAM
//! schedulers; its mutex serializes access, not the order of concurrent callers.

use std::sync::{Arc, Mutex};

use rustler::{Atom, Binary, Env, NifResult, ResourceArc};

use crate::plan::{build_rewriter, encode_output, Rule};
use crate::{OutputSink, SendableRewriter};

// RustQ generates Resource registration from the session type declaration.
pub struct StreamSession {
    active: Mutex<Option<ActiveSession>>,
}

struct ActiveSession {
    rewriter: SendableRewriter,
    output: Arc<Mutex<OutputBuffer>>,
    max_input_bytes: usize,
}

pub(super) struct OutputBuffer {
    bytes: Vec<u8>,
    limit: usize,
    exceeded: bool,
    _allocation: crate::diagnostics::Allocation,
}

impl OutputBuffer {
    pub(super) fn new(limit: usize) -> NifResult<Self> {
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(limit)
            .map_err(|_| error("output allocation failed"))?;
        let allocation = crate::diagnostics::Allocation::buffer(bytes.capacity());
        Ok(Self {
            bytes,
            limit,
            exceeded: false,
            _allocation: allocation,
        })
    }

    pub(super) fn write(&mut self, bytes: &[u8]) {
        if self.exceeded {
            return;
        }
        if bytes.len() > self.limit - self.bytes.len() {
            self.exceeded = true;
        } else {
            self.bytes.extend_from_slice(bytes);
        }
    }

    pub(super) fn drain<'a>(&mut self, env: Env<'a>) -> NifResult<(Atom, Binary<'a>)> {
        if self.exceeded {
            return Err(error("rewrite output limit exceeded"));
        }
        let result = encode_output(env, &self.bytes);
        self.bytes.clear();
        result
    }
}

fn error(reason: impl Into<String>) -> rustler::Error {
    rustler::Error::Term(Box::new(reason.into()))
}

pub fn stream_new_impl(
    rules: Vec<Rule>,
    encoding: String,
    max_memory: usize,
    max_input_bytes: usize,
    max_output_bytes: usize,
) -> NifResult<(Atom, ResourceArc<StreamSession>)> {
    if max_memory == 0 || max_input_bytes == 0 || max_output_bytes == 0 {
        return Err(error("rewrite stream limits must be positive"));
    }
    let output = Arc::new(Mutex::new(OutputBuffer::new(max_output_bytes)?));
    let sink_output = Arc::clone(&output);
    let sink: OutputSink = Box::new(move |bytes: &[u8]| {
        // No user code runs under this lock. Recovery also keeps destruction safe
        // should a native panic ever poison it.
        sink_output
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .write(bytes);
    });
    let rewriter = build_rewriter(rules, encoding, max_memory, sink).map_err(error)?;
    let session = StreamSession {
        active: Mutex::new(Some(ActiveSession {
            rewriter,
            output,
            max_input_bytes,
        })),
    };
    Ok((crate::atoms::ok(), ResourceArc::new(session)))
}

pub fn stream_write_impl<'a>(
    env: Env<'a>,
    session: ResourceArc<StreamSession>,
    input: Binary<'a>,
) -> NifResult<(Atom, Binary<'a>)> {
    let mut active = session.active.lock().map_err(|_| error("lock poisoned"))?;
    let result = match active.as_mut() {
        None => Err(error("rewrite session is closed")),
        Some(state) => write_chunk(env, state, input.as_slice()),
    };
    if result.is_err() {
        // Parse failures are terminal. Release parser and output allocation now,
        // rather than waiting for the BEAM resource to be garbage-collected.
        active.take();
    }
    result
}

fn write_chunk<'a>(
    env: Env<'a>,
    state: &mut ActiveSession,
    input: &[u8],
) -> NifResult<(Atom, Binary<'a>)> {
    if input.len() > state.max_input_bytes {
        return Err(error("rewrite input chunk limit exceeded"));
    }
    state
        .rewriter
        .write(input)
        .map_err(|e| error(e.to_string()))?;
    state
        .output
        .lock()
        .map_err(|_| error("lock poisoned"))?
        .drain(env)
}

pub fn stream_finish_impl<'a>(
    env: Env<'a>,
    session: ResourceArc<StreamSession>,
) -> NifResult<(Atom, Binary<'a>)> {
    let state = session
        .active
        .lock()
        .map_err(|_| error("lock poisoned"))?
        .take()
        .ok_or_else(|| error("rewrite session is closed"))?;
    // Take the state before ending: both success and failure close the session.
    state.rewriter.end().map_err(|e| error(e.to_string()))?;
    let result = state
        .output
        .lock()
        .map_err(|_| error("lock poisoned"))?
        .drain(env);
    result
}

pub fn stream_close_impl(session: ResourceArc<StreamSession>) -> Atom {
    // Idempotent cancellation deliberately does not flush an unfinished parser.
    session
        .active
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .take();
    crate::atoms::ok()
}
