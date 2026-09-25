# Changelog

## Unreleased

## 0.3.0 - 2026-09-25

### Breaking changes

- Parser text handlers now skip raw-text content such as scripts and styles by default, including calls to `Laughter.filter/4` with `true`. Use `text: true, raw_text: true` to preserve the previous all-text behavior. Title and textarea text remain included by default.
- `Laughter.Rewriter.new/1` now returns an opaque immutable plan rather than a native reference. Recreate configurations after upgrading and remove reference-specific guards or assumptions. Existing callback registration and rewriting remain available in the same process.
- Rewriter options reject unknown keys and nonpositive memory limits. Declarative rewrites reject unsupported encodings instead of silently using UTF-8.

### Added

- Immutable, pipeable rewrite plans for removing elements, setting/removing attributes, and inserting or replacing text and HTML in a single native pass.
- Lazy `Laughter.Rewriter.stream/3` rewriting with bounded native output buffering, EOF flushing, and cleanup on early halt or failure.
- Optional message-driven rewrite sessions with demand-based backpressure, correlated element replies, timeouts, cancellation, and temporary supervision.
- `Laughter.document_text/3` for receiving each document text chunk once, including documents without a body element.
- Parser `:end_tag` and `:raw_text` options for explicit end-tag events and opt-in raw-text extraction.
