//! Single-pass declarative rewriting. No BEAM callbacks or worker threads.

use lol_html::html_content::ContentType;
use lol_html::send::{ElementContentHandlers, HtmlRewriter, Settings};
use lol_html::{AsciiCompatibleEncoding, MemorySettings};
use rustler::{Atom, Binary, Env, LocalPid, NifResult, OwnedBinary, ResourceArc, Term};

use crate::plan_stream::{
    stream_close_impl, stream_finish_impl, stream_new_impl, stream_write_impl, StreamSession,
};

use crate::plan_dynamic::{
    dynamic_close_impl, dynamic_finish_impl, dynamic_new_impl, dynamic_reply_impl,
    dynamic_write_impl, DynamicSession,
};

use crate::diagnostics::rewrite_stats_impl;

include!("generated_rewrite.rs");

fn rewrite_plan_impl<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    rules: Vec<Rule>,
    encoding: String,
    max_memory: usize,
) -> NifResult<(Atom, Binary<'a>)> {
    let output = rewrite_bytes(input, rules, encoding, max_memory)
        .map_err(|reason| rustler::Error::Term(Box::new(reason)))?;
    encode_output(env, &output)
}

pub(super) fn encode_output<'a>(env: Env<'a>, output: &[u8]) -> NifResult<(Atom, Binary<'a>)> {
    let mut binary = OwnedBinary::new(output.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("output allocation failed")))?;
    binary.as_mut_slice().copy_from_slice(output);
    Ok((crate::atoms::ok(), binary.release(env)))
}

fn rewrite_bytes(
    input: Binary<'_>,
    rules: Vec<Rule>,
    encoding: String,
    max_memory: usize,
) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(input.len());
    let mut rewriter = build_rewriter(rules, encoding, max_memory, |bytes: &[u8]| {
        output.extend_from_slice(bytes);
    })?;
    rewriter
        .write(input.as_slice())
        .map_err(|e| e.to_string())?;
    rewriter.end().map_err(|e| e.to_string())?;
    Ok(output)
}

pub(super) fn build_rewriter<O: lol_html::OutputSink>(
    rules: Vec<Rule>,
    encoding: String,
    max_memory: usize,
    output: O,
) -> Result<HtmlRewriter<'static, O>, String> {
    build_with_handlers(rule_handlers(rules)?, encoding, max_memory, output)
}

pub(super) type Handlers = Vec<(
    std::borrow::Cow<'static, lol_html::Selector>,
    ElementContentHandlers<'static>,
)>;

pub(super) fn rule_handlers(rules: Vec<Rule>) -> Result<Handlers, String> {
    let mut handlers = Vec::with_capacity(rules.len());
    for rule in rules {
        // Parse fallibly instead of using element!(), which unwraps selectors.
        let selector = rule
            .selector
            .parse::<lol_html::Selector>()
            .map_err(|e| format!("invalid selector: {e}"))?;
        let mutation = rule.mutation;
        handlers.push((
            std::borrow::Cow::Owned(selector),
            ElementContentHandlers::default().element(
                move |element: &mut lol_html::send::Element<'_, '_>| {
                    apply_mutation(element, &mutation)
                },
            ),
        ));
    }

    Ok(handlers)
}

pub(super) fn apply_mutation(
    element: &mut lol_html::send::Element<'_, '_>,
    mutation: &Mutation,
) -> lol_html::HandlerResult {
    match mutation {
        // Clear an earlier replacement too: remove() alone leaves it intact.
        Mutation::Remove => element.replace("", ContentType::Html),
        Mutation::SetAttribute(attribute) => {
            element.set_attribute(&attribute.name, &attribute.value)?;
        }
        Mutation::RemoveAttribute(name) => element.remove_attribute(name),
        _ => apply_content_mutation(element, mutation),
    }
    Ok(())
}

pub(super) fn build_with_handlers<O: lol_html::OutputSink>(
    handlers: Handlers,
    encoding: String,
    max_memory: usize,
    output: O,
) -> Result<HtmlRewriter<'static, O>, String> {
    let encoding = encoding_rs::Encoding::for_label(encoding.as_bytes())
        .and_then(AsciiCompatibleEncoding::new)
        .ok_or_else(|| format!("unsupported encoding: {encoding}"))?;
    let settings = Settings {
        element_content_handlers: handlers,
        encoding,
        memory_settings: MemorySettings {
            max_allowed_memory_usage: max_memory,
            preallocated_parsing_buffer_size: max_memory
                .min(MemorySettings::default().preallocated_parsing_buffer_size),
        },
        ..Settings::new_for_handler_types()
    };
    Ok(HtmlRewriter::new(settings, output))
}
