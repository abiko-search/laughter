use lol_html::html_content::ContentType;
use lol_html::send::{HtmlRewriter, Settings};
use lol_html::{AsciiCompatibleEncoding, MemorySettings};
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

use crate::atoms;

static HANDLER_COUNTER: AtomicU64 = AtomicU64::new(1_000_000);

pub enum Request {
    Element {
        handler_id: u64,
        tag: String,
        attrs: Vec<(String, String)>,
    },
    Text {
        handler_id: u64,
        content: String,
        last_in_text_node: bool,
    },
}

pub enum Mutation {
    SetAttribute(String, String),
    RemoveAttribute(String),
    Prepend(String, bool),
    Append(String, bool),
    Before(String, bool),
    After(String, bool),
    SetInnerContent(String, bool),
    Replace(String, bool),
    Remove,
    NoOp,
}

enum WriteResult {
    Ok(Vec<u8>),
    Err(String),
}

pub struct RewriterHandle {
    request_rx: Mutex<mpsc::Receiver<Request>>,
    response_tx: Mutex<mpsc::Sender<Vec<Mutation>>>,
    result_rx: Mutex<mpsc::Receiver<WriteResult>>,
    output: Mutex<Vec<u8>>,
}

pub struct RewriterConfig {
    handlers: Mutex<Vec<HandlerConfig>>,
    encoding: Mutex<Option<AsciiCompatibleEncoding>>,
    max_memory: Mutex<usize>,
}

struct HandlerConfig {
    handler_id: u64,
    selector: String,
    handler_type: HandlerType,
}

enum HandlerType {
    Element,
    Text,
}

#[rustler::resource_impl]
impl rustler::Resource for RewriterHandle {}

#[rustler::resource_impl]
impl rustler::Resource for RewriterConfig {}

#[rustler::nif]
pub fn rewriter_new(encoding: &str, max_memory: usize) -> ResourceArc<RewriterConfig> {
    let enc = encoding_rs::Encoding::for_label(encoding.as_bytes())
        .and_then(AsciiCompatibleEncoding::new)
        .unwrap_or_else(AsciiCompatibleEncoding::utf_8);

    ResourceArc::new(RewriterConfig {
        handlers: Mutex::new(Vec::new()),
        encoding: Mutex::new(Some(enc)),
        max_memory: Mutex::new(max_memory),
    })
}

#[rustler::nif]
pub fn rewriter_on_element(config: ResourceArc<RewriterConfig>, selector: String) -> u64 {
    let handler_id = HANDLER_COUNTER.fetch_add(1, Ordering::SeqCst);
    config.handlers.lock().unwrap().push(HandlerConfig {
        handler_id,
        selector,
        handler_type: HandlerType::Element,
    });
    handler_id
}

#[rustler::nif]
pub fn rewriter_on_text(config: ResourceArc<RewriterConfig>, selector: String) -> u64 {
    let handler_id = HANDLER_COUNTER.fetch_add(1, Ordering::SeqCst);
    config.handlers.lock().unwrap().push(HandlerConfig {
        handler_id,
        selector,
        handler_type: HandlerType::Text,
    });
    handler_id
}

/// Start rewriting: spawns a thread that runs LOL HTML,
/// blocks on channel for each handler callback.
#[rustler::nif]
pub fn rewriter_write(
    config: ResourceArc<RewriterConfig>,
    data: rustler::Binary,
) -> NifResult<ResourceArc<RewriterHandle>> {
    let (request_tx, request_rx) = mpsc::channel::<Request>();
    let (response_tx, response_rx) = mpsc::channel::<Vec<Mutation>>();
    let (result_tx, result_rx) = mpsc::channel::<WriteResult>();

    let handlers = config.handlers.lock().unwrap();
    let encoding = config
        .encoding
        .lock()
        .unwrap()
        .take()
        .unwrap_or_else(AsciiCompatibleEncoding::utf_8);
    let max_memory = *config.max_memory.lock().unwrap();

    // LOL HTML is single-threaded — handlers called sequentially.
    // All handlers share one response channel.
    let shared_response_rx = Arc::new(Mutex::new(response_rx));

    let mut el_handlers = Vec::new();
    for h in handlers.iter() {
        let req_tx = request_tx.clone();
        let shared_rx = Arc::clone(&shared_response_rx);

        match h.handler_type {
            HandlerType::Element => {
                let handler_id = h.handler_id;
                let selector = h.selector.clone();

                el_handlers.push(lol_html::element!(selector, move |el| {
                    let tag = el.tag_name();
                    let attrs: Vec<(String, String)> = el
                        .attributes()
                        .iter()
                        .map(|a| (a.name(), a.value()))
                        .collect();

                    req_tx
                        .send(Request::Element { handler_id, tag, attrs })
                        .map_err(|e| format!("request send failed: {e}"))?;

                    let mutations = shared_rx
                        .lock()
                        .unwrap()
                        .recv()
                        .map_err(|e| format!("response recv failed: {e}"))?;

                    for m in mutations {
                        apply_element_mutation(el, m);
                    }
                    Ok(())
                }));
            }
            HandlerType::Text => {
                let handler_id = h.handler_id;
                let selector = h.selector.clone();

                el_handlers.push(lol_html::text!(selector, move |chunk| {
                    let content = chunk.as_str().to_string();
                    let last = chunk.last_in_text_node();

                    if content.is_empty() && !last {
                        return Ok(());
                    }

                    req_tx
                        .send(Request::Text { handler_id, content, last_in_text_node: last })
                        .map_err(|e| format!("request send failed: {e}"))?;

                    let mutations = shared_rx
                        .lock()
                        .unwrap()
                        .recv()
                        .map_err(|e| format!("response recv failed: {e}"))?;

                    for m in mutations {
                        apply_text_mutation(chunk, m);
                    }
                    Ok(())
                }));
            }
        }
    }
    drop(handlers);

    let output = Arc::new(Mutex::new(Vec::new()));
    let output_clone = Arc::clone(&output);

    let settings = Settings {
        element_content_handlers: el_handlers,
        memory_settings: MemorySettings {
            max_allowed_memory_usage: max_memory,
            ..Default::default()
        },
        encoding,
        ..Settings::new_for_handler_types()
    };

    let sink: Box<dyn FnMut(&[u8]) + Send> = Box::new(move |bytes: &[u8]| {
        output_clone.lock().unwrap().extend_from_slice(bytes);
    });

    let mut rewriter = HtmlRewriter::new(settings, sink);
    let input = data.as_slice().to_vec();

    thread::spawn(move || {
        if let Err(e) = rewriter.write(&input) {
            let _ = result_tx.send(WriteResult::Err(e.to_string()));
            return;
        }
        match rewriter.end() {
            Ok(()) => {
                let out = output.lock().unwrap().clone();
                let _ = result_tx.send(WriteResult::Ok(out));
            }
            Err(e) => {
                let _ = result_tx.send(WriteResult::Err(e.to_string()));
            }
        }
    });

    Ok(ResourceArc::new(RewriterHandle {
        request_rx: Mutex::new(request_rx),
        response_tx: Mutex::new(response_tx),
        result_rx: Mutex::new(result_rx),
        output: Mutex::new(Vec::new()),
    }))
}

/// Poll for the next handler request, or check if rewriting is done.
/// Returns:
///   {:element, handler_id, tag, attrs}
///   {:text, handler_id, content, last_in_text_node}
///   :done
///   {:error, reason}
///   :pending
#[rustler::nif]
pub fn rewriter_poll<'a>(env: Env<'a>, handle: ResourceArc<RewriterHandle>) -> Term<'a> {
    let recv_result = handle.request_rx.lock().unwrap().try_recv();

    match recv_result {
        Ok(Request::Element { handler_id, tag, attrs }) => {
            let attrs_terms: Vec<Term> = attrs
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()).encode(env))
                .collect();

            (atoms::element(), handler_id, tag.encode(env), attrs_terms.encode(env)).encode(env)
        }
        Ok(Request::Text { handler_id, content, last_in_text_node }) => {
            (atoms::text(), handler_id, content, last_in_text_node).encode(env)
        }
        Err(mpsc::TryRecvError::Empty) | Err(mpsc::TryRecvError::Disconnected) => {
            check_result(env, handle)
        }
    }
}

fn check_result<'a>(env: Env<'a>, handle: ResourceArc<RewriterHandle>) -> Term<'a> {
    let result_rx = handle.result_rx.lock().unwrap();
    match result_rx.try_recv() {
        Ok(WriteResult::Ok(output)) => {
            *handle.output.lock().unwrap() = output;
            atoms::done().encode(env)
        }
        Ok(WriteResult::Err(e)) => (atoms::error(), e).encode(env),
        Err(_) => atoms::pending().encode(env),
    }
}

/// Send mutation response back to the blocked handler thread.
/// Mutations are `[{"set_attribute", "href", "/new"}, {"remove", "", ""}]`
#[rustler::nif]
pub fn rewriter_respond(
    handle: ResourceArc<RewriterHandle>,
    mutations: Vec<(String, String, String)>,
) -> NifResult<()> {
    let parsed: Vec<Mutation> = mutations
        .into_iter()
        .map(|(op, arg1, arg2)| match op.as_str() {
            "set_attribute" => Mutation::SetAttribute(arg1, arg2),
            "remove_attribute" => Mutation::RemoveAttribute(arg1),
            "prepend_html" => Mutation::Prepend(arg1, true),
            "prepend_text" => Mutation::Prepend(arg1, false),
            "append_html" => Mutation::Append(arg1, true),
            "append_text" => Mutation::Append(arg1, false),
            "before_html" => Mutation::Before(arg1, true),
            "before_text" => Mutation::Before(arg1, false),
            "after_html" => Mutation::After(arg1, true),
            "after_text" => Mutation::After(arg1, false),
            "set_inner_html" => Mutation::SetInnerContent(arg1, true),
            "set_inner_text" => Mutation::SetInnerContent(arg1, false),
            "replace_html" => Mutation::Replace(arg1, true),
            "replace_text" => Mutation::Replace(arg1, false),
            "remove" => Mutation::Remove,
            _ => Mutation::NoOp,
        })
        .collect();

    handle
        .response_tx
        .lock()
        .unwrap()
        .send(parsed)
        .map_err(|_| rustler::Error::Term(Box::new("response channel closed")))?;

    Ok(())
}

/// Get the rewritten output bytes.
#[rustler::nif]
pub fn rewriter_output(handle: ResourceArc<RewriterHandle>) -> Vec<u8> {
    handle.output.lock().unwrap().clone()
}

fn apply_element_mutation(el: &mut lol_html::send::Element, mutation: Mutation) {
    match mutation {
        Mutation::SetAttribute(name, value) => {
            let _ = el.set_attribute(&name, &value);
        }
        Mutation::RemoveAttribute(name) => {
            el.remove_attribute(&name);
        }
        Mutation::Prepend(content, is_html) => {
            el.prepend(&content, content_type(is_html));
        }
        Mutation::Append(content, is_html) => {
            el.append(&content, content_type(is_html));
        }
        Mutation::Before(content, is_html) => {
            el.before(&content, content_type(is_html));
        }
        Mutation::After(content, is_html) => {
            el.after(&content, content_type(is_html));
        }
        Mutation::SetInnerContent(content, is_html) => {
            el.set_inner_content(&content, content_type(is_html));
        }
        Mutation::Replace(content, is_html) => {
            el.replace(&content, content_type(is_html));
        }
        Mutation::Remove => {
            el.remove();
        }
        Mutation::NoOp => {}
    }
}

fn apply_text_mutation(chunk: &mut lol_html::html_content::TextChunk, mutation: Mutation) {
    match mutation {
        Mutation::Replace(content, is_html) => {
            chunk.replace(&content, content_type(is_html));
        }
        Mutation::Before(content, is_html) => {
            chunk.before(&content, content_type(is_html));
        }
        Mutation::After(content, is_html) => {
            chunk.after(&content, content_type(is_html));
        }
        Mutation::Remove => {
            chunk.remove();
        }
        _ => {}
    }
}

fn content_type(is_html: bool) -> ContentType {
    if is_html {
        ContentType::Html
    } else {
        ContentType::Text
    }
}
