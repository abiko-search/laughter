//! Laughter NIF - Streaming HTML parser using lol-html

use lol_html::html_content::{EndTag, TextType};
use lol_html::send::{HtmlRewriter, Settings};
use lol_html::{AsciiCompatibleEncoding, MemorySettings};
use rustler::{Binary, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

mod rewriter;
mod plan;
mod plan_stream;
mod plan_dynamic;
mod diagnostics;

pub mod atoms {
    rustler::atoms! {
        ok,
        error,
        element,
        text,
        end_tag,
        end,
        done,
        pending,
        laughter_native,
        output,
    }
}

static FILTER_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
enum Message {
    Element {
        filter_id: u64,
        tag: String,
        attrs: Vec<(String, String)>,
    },
    Text {
        filter_id: u64,
        content: String,
    },
    EndTag {
        filter_id: u64,
        tag: String,
    },
}

struct RewriterBuilder {
    selectors: Mutex<Vec<SelectorConfig>>,
}

struct SelectorConfig {
    filter_id: u64,
    selector: String,
    pid: LocalPid,
    send_text: bool,
    end_tag: bool,
    raw_text: bool,
    document: bool,
}

type OutputSink = Box<dyn FnMut(&[u8]) + Send>;
type SendableRewriter = HtmlRewriter<'static, OutputSink>;

struct Rewriter {
    inner: Mutex<Option<SendableRewriter>>,
    messages: Arc<Mutex<Vec<(LocalPid, Message)>>>,
    filters: Vec<(u64, LocalPid)>,
}

#[rustler::resource_impl]
impl rustler::Resource for RewriterBuilder {}

#[rustler::resource_impl]
impl rustler::Resource for Rewriter {}

#[rustler::nif]
fn build() -> ResourceArc<RewriterBuilder> {
    ResourceArc::new(RewriterBuilder {
        selectors: Mutex::new(Vec::new()),
    })
}

#[rustler::nif]
fn filter(
    builder: ResourceArc<RewriterBuilder>,
    pid: LocalPid,
    selector: String,
    send_text: bool,
    end_tag: bool,
    raw_text: bool,
) -> NifResult<u64> {
    // Check for empty selector (lol-html panics on empty selectors)
    if selector.is_empty() || selector.trim().is_empty() {
        return Err(rustler::Error::RaiseTerm(Box::new("The selector is empty.")));
    }

    // Check for obviously invalid selectors
    if selector == "#" || selector == "." || selector == "[" {
        return Err(rustler::Error::RaiseTerm(Box::new("The selector is empty.")));
    }

    let filter_id = FILTER_COUNTER.fetch_add(1, Ordering::SeqCst);

    let mut selectors = builder
        .selectors
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    selectors.push(SelectorConfig {
        filter_id,
        selector,
        pid,
        send_text,
        end_tag,
        raw_text,
        document: false,
    });

    Ok(filter_id)
}

/// Register a handler for every text chunk in the document, whatever
/// element it is in. Unlike a selector's text handler it fires once per
/// chunk, and it works on documents that omit `<body>`.
#[rustler::nif]
fn document_text(
    builder: ResourceArc<RewriterBuilder>,
    pid: LocalPid,
    raw_text: bool,
) -> NifResult<u64> {
    let filter_id = FILTER_COUNTER.fetch_add(1, Ordering::SeqCst);

    let mut selectors = builder
        .selectors
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    selectors.push(SelectorConfig {
        filter_id,
        selector: String::new(),
        pid,
        send_text: true,
        end_tag: false,
        raw_text,
        document: true,
    });

    Ok(filter_id)
}

#[rustler::nif]
fn create(
    builder: ResourceArc<RewriterBuilder>,
    encoding: Binary,
    max_memory: usize,
) -> NifResult<ResourceArc<Rewriter>> {
    let encoding_str = std::str::from_utf8(encoding.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    let encoding = encoding_rs::Encoding::for_label(encoding_str.as_bytes())
        .and_then(AsciiCompatibleEncoding::new)
        .unwrap_or_else(AsciiCompatibleEncoding::utf_8);

    let selectors = builder
        .selectors
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    let filters: Vec<(u64, LocalPid)> = selectors.iter().map(|c| (c.filter_id, c.pid)).collect();
    let messages: Arc<Mutex<Vec<(LocalPid, Message)>>> = Arc::new(Mutex::new(Vec::new()));

    let mut element_handlers = Vec::new();
    let mut document_handlers = Vec::new();

    for config in selectors.iter().filter(|c| c.document) {
        let filter_id = config.filter_id;
        let pid = config.pid;
        let raw_text = config.raw_text;
        let doc_msgs = Arc::clone(&messages);

        document_handlers.push(lol_html::doc_text!(move |text_chunk| {
            let visible = matches!(text_chunk.text_type(), TextType::Data | TextType::RCData);
            if !raw_text && !visible {
                return Ok(());
            }

            let content = text_chunk.as_str().to_string();
            if !content.is_empty() {
                doc_msgs
                    .lock()
                    .unwrap()
                    .push((pid, Message::Text { filter_id, content }));
            }
            Ok(())
        }));
    }

    for config in selectors.iter().filter(|c| !c.document) {
        let filter_id = config.filter_id;
        let pid = config.pid;
        let send_text = config.send_text;
        let end_tag = config.end_tag;
        let raw_text = config.raw_text;
        let selector = config.selector.clone();
        let msgs = Arc::clone(&messages);

        element_handlers.push(lol_html::element!(selector.clone(), move |el| {
            let tag = el.tag_name();
            let attrs: Vec<(String, String)> = el
                .attributes()
                .iter()
                .map(|a| (a.name(), a.value()))
                .collect();

            msgs.lock().unwrap().push((
                pid,
                Message::Element {
                    filter_id,
                    tag,
                    attrs,
                },
            ));

            // Opt-in: report the explicit end tag of this element. lol-html
            // does not run these for implicitly closed elements.
            if end_tag {
                if let Some(handlers) = el.end_tag_handlers() {
                    let end_msgs = Arc::clone(&msgs);
                    let handler: lol_html::send::EndTagHandler<'static> =
                        Box::new(move |end: &mut EndTag<'_>| -> lol_html::HandlerResult {
                            end_msgs.lock().unwrap().push((
                                pid,
                                Message::EndTag {
                                    filter_id,
                                    tag: end.name(),
                                },
                            ));
                            Ok(())
                        });
                    handlers.push(handler);
                }
            }
            Ok(())
        }));

        if send_text {
            let text_msgs = Arc::clone(&messages);
            element_handlers.push(lol_html::text!(selector, move |text_chunk| {
                // Visible text only unless raw_text: script, style, and CDATA
                // contents are not content.
                let visible = matches!(text_chunk.text_type(), TextType::Data | TextType::RCData);
                if !raw_text && !visible {
                    return Ok(());
                }

                let content = text_chunk.as_str().to_string();
                if !content.is_empty() {
                    text_msgs
                        .lock()
                        .unwrap()
                        .push((pid, Message::Text { filter_id, content }));
                }
                Ok(())
            }));
        }
    }

    let settings = Settings {
        element_content_handlers: element_handlers,
        document_content_handlers: document_handlers,
        memory_settings: MemorySettings {
            max_allowed_memory_usage: max_memory,
            ..Default::default()
        },
        encoding,
        ..Settings::new_for_handler_types()
    };

    let output_sink: OutputSink = Box::new(|_| {});
    let rewriter = HtmlRewriter::new(settings, output_sink);

    Ok(ResourceArc::new(Rewriter {
        inner: Mutex::new(Some(rewriter)),
        messages,
        filters,
    }))
}

fn send_messages(env: Env, rewriter: &Rewriter) -> NifResult<()> {
    let mut messages = rewriter
        .messages
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    for (pid, msg) in messages.drain(..) {
        let term: Term = match msg {
            Message::Element {
                filter_id,
                tag,
                attrs,
            } => {
                let tag_term = tag.encode(env);
                let attrs_term: Vec<Term> = attrs
                    .iter()
                    .map(|(k, v)| (k.as_str(), v.as_str()).encode(env))
                    .collect();
                (
                    atoms::element(),
                    filter_id,
                    (tag_term, attrs_term.encode(env)),
                )
                    .encode(env)
            }
            Message::Text { filter_id, content } => {
                (atoms::text(), filter_id, content).encode(env)
            }
            Message::EndTag { filter_id, tag } => {
                (atoms::end_tag(), filter_id, tag).encode(env)
            }
        };

        let _ = env.send(&pid, term);
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn parse(
    env: Env,
    rewriter: ResourceArc<Rewriter>,
    data: Binary,
) -> NifResult<ResourceArc<Rewriter>> {
    {
        let mut guard = rewriter
            .inner
            .lock()
            .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

        let rw = guard
            .as_mut()
            .ok_or_else(|| rustler::Error::Term(Box::new("rewriter already consumed")))?;

        rw.write(data.as_slice())
            .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    }

    send_messages(env, &rewriter)?;
    Ok(rewriter)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn done(env: Env, rewriter: ResourceArc<Rewriter>) -> NifResult<()> {
    {
        let mut guard = rewriter
            .inner
            .lock()
            .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

        let rw = guard
            .take()
            .ok_or_else(|| rustler::Error::Term(Box::new("rewriter already consumed")))?;

        rw.end()
            .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    }

    send_messages(env, &rewriter)?;

    // Send end notification to each filter
    for (filter_id, pid) in &rewriter.filters {
        let _ = env.send(pid, (atoms::end(), *filter_id).encode(env));
    }

    Ok(())
}

rustler::init!("Elixir.Laughter.Nif");
