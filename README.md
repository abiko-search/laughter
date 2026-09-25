# Laughter

[![CI](https://github.com/abiko-search/laughter/actions/workflows/elixir.yml/badge.svg)](https://github.com/abiko-search/laughter/actions/workflows/elixir.yml)

A **streaming HTML parser and rewriter** for Elixir built on top of CloudFlare's [LOL HTML](https://github.com/cloudflare/lol-html).

## Why Laughter?

Unlike traditional DOM-based parsers (like Floki), Laughter processes HTML **as it streams in**, making it ideal for:

- **Crawlers** - Extract links as the page downloads, not after
- **Large documents** - Process incrementally without building a DOM tree
- **Real-time processing** - Get results before the full document arrives

## Features

- 🚀 **Streaming** - Process HTML chunk by chunk
- 🎯 **CSS Selectors** - Filter elements with familiar CSS syntax
- 💾 **Memory bounded** - Configurable memory limits
- 🔒 **Thread-safe** - Safe for concurrent use
- ⚡ **Fast** - Built on Rust's lol-html (used by Cloudflare Workers)

## Installation

```elixir
def deps do
  [
    {:laughter, "~> 0.3.0", github: "abiko-search/laughter", submodules: true}
  ]
end
```

**Requirements:**
- Elixir ~> 1.15
- Rust (for compilation)

## Upgrading from 0.2

- `Laughter.filter/4` with `true` or `text: true` now skips raw-text content such
  as scripts and styles. To retain the previous all-text behavior, use
  `Laughter.filter(builder, self(), selector, text: true, raw_text: true)`.
  Text in `<title>` and `<textarea>` is still included by default.
- `Laughter.Rewriter.new/1` returns an opaque immutable plan, not a native
  reference. Recreate configurations after upgrading; remove `is_reference/1`
  checks or reference-specific storage assumptions. Pass plans through the public
  API rather than inspecting their representation or calling NIFs directly.
- Existing `new` → `on_element`/`on_text` → `rewrite` callback usage still works
  when registration and execution happen in the same process. It cannot be mixed
  with declarative rules or used by the new streaming/session APIs.
- Rewriter options now reject unknown keys and nonpositive memory limits.
  Declarative execution rejects unsupported encodings instead of silently
  falling back to UTF-8.

See [CHANGELOG.md](CHANGELOG.md) for the complete release scope.

## Usage

### Basic Example

```elixir
# Create a parser builder
builder = Laughter.build()

# Register CSS selectors - matched elements are sent as messages
link_ref = Laughter.filter(builder, self(), "a[href]")

# Create the parser
parser = Laughter.create(builder)

# Stream HTML in chunks (simulating network data)
parser
|> Laughter.parse("<html><body>")
|> Laughter.parse("<a href='/page1'>Link 1</a>")
|> Laughter.parse("<a href='/page2'>Link 2</a>")
|> Laughter.parse("</body></html>")
|> Laughter.done()

# Receive matched elements
receive do
  {:element, ^link_ref, {"a", [{"href", "/page1"}]}} -> :ok
end

receive do
  {:element, ^link_ref, {"a", [{"href", "/page2"}]}} -> :ok
end
```

### Extract Text Content

```elixir
builder = Laughter.build()

# Pass `true` as 4th argument to receive text content
title_ref = Laughter.filter(builder, self(), "title", true)

builder
|> Laughter.create()
|> Laughter.parse("<html><head><title>My Page</title></head></html>")
|> Laughter.done()

receive do
  {:element, ^title_ref, {"title", []}} -> :ok
end

receive do
  {:text, ^title_ref, "My Page"} -> :ok
end
```

### Document Text and End Tags

```elixir
# Every document text chunk once, even when <body> is omitted.
text_ref = Laughter.document_text(builder, self())
# Explicit end tags only; implicitly closed and void elements do not emit them.
paragraph_ref = Laughter.filter(builder, self(), "p", text: true, end_tag: true)
```

Document text arrives as `{:text, text_ref, content}` and finishes with
`{:end, text_ref}`. Explicit end tags arrive as
`{:end_tag, paragraph_ref, "p"}`. Both text APIs skip raw-text elements unless
`raw_text: true`; this is not CSS visibility filtering or sanitization.

### Multiple Selectors

```elixir
builder = Laughter.build()

links = Laughter.filter(builder, self(), "a")
images = Laughter.filter(builder, self(), "img")
meta = Laughter.filter(builder, self(), "meta[name='description']")

# All selectors work on the same stream
builder
|> Laughter.create()
|> Laughter.parse(html)
|> Laughter.done()
```

### Declarative Rewriting

Build an immutable plan with pipes, then execute every rule in one native pass:

```elixir
alias Laughter.Rewriter

plan =
  Rewriter.new()
  |> Rewriter.remove("script")
  |> Rewriter.set_attribute("a[href]", "rel", "nofollow")
  |> Rewriter.remove_attribute("img", "onclick")

{:ok, output} = Rewriter.rewrite(plan, html)
```

Building a plan does not call native code. Plans are reusable across processes;
execution decodes the rules once and runs on a dirty CPU scheduler, without
per-element messages or callbacks. Output is a binary. Rules run in registration
order, the last attribute write wins, and removal includes an element's content.
Selectors match the original input, not attributes changed by earlier rules.

`rewrite/2` accepts a complete document (binary or iodata). Invalid selectors,
unsupported encodings, and native rewriting failures return `{:error, reason}`.
This is not an HTML sanitizer.

Content operations also compose with pipes and work with both `rewrite/2` and
`stream/3`:

```elixir
plan =
  Rewriter.new()
  |> Rewriter.prepend_html("body", "<header>Notice</header>")
  |> Rewriter.set_inner_text(".title", ["Hello, ", "world!"])
  |> Rewriter.after_html("article", "<hr>")
  |> Rewriter.replace_text(".redacted", "[removed]")
```

Available pairs: `prepend_text/html`, `append_text/html`, `before_text/html`,
`after_text/html`, `replace_text/html`, and `set_inner_text/html`. The `_text`
functions escape `&`, `<`, and `>`; `_html` inserts markup verbatim. Content must
be UTF-8 iodata regardless of the document encoding. Inserted HTML is **not**
matched by later rules, so these operations are not a sanitizer.

Ordering is explicit:

- Repeated `before`/`append` insertions preserve order; `prepend`/`after` reverse it.
- The last `remove` or `replace` wins; surrounding insertions survive.
- Inner operations cannot resurrect removed/replaced elements and are ignored on
  void elements such as `<img>`.
- `set_inner` clears earlier inner insertions; later prepend/append operations remain.

The existing `on_element/3` and `on_text/3` callback API is retained for compatibility.
Callbacks must be registered and executed in the same process. Mixing callback
registrations with declarative rules returns `{:error, :mixed_rewrite_modes}`.

### Streaming Rewriting

The same declarative plan can rewrite an enumerable of chunks lazily:

```elixir
File.stream!("input.html", [], 65_536)
|> Rewriter.stream(plan)
|> Stream.into(File.stream!("output.html"))
|> Stream.run()
```

Each enumeration opens one native session. Output is emitted incrementally as
binary chunks, with pending bytes flushed at EOF. Early halt, source errors, and
consumer errors close the session without flushing. No GenServer, worker thread,
or per-element BEAM messages are required. Legacy callback plans are not supported.

`Rewriter.stream/3` accepts two limits:

- `chunk_size: 65_536` — maximum bytes per native write; larger upstream chunks
  are split lazily.
- `max_output_bytes: 1_048_576` — maximum buffered output per write or EOF flush.
  Excessive expansion raises `Laughter.Rewriter.Error` instead of growing the
  output buffer without bound. Decrease `chunk_size` or increase this limit
  when a plan expands output significantly.

Native errors raise `Laughter.Rewriter.Error` during enumeration; output already
written cannot be rolled back. Source and consumer exceptions propagate unchanged.
Use bounded upstream chunks and a streaming sink for bounded end-to-end memory:
these limits do not cover the plan, upstream allocations, or retained results.
Iodata chunks are converted to binaries before splitting. Output boundaries are
arbitrary and may split characters; concatenate before decoding text.

### Message-driven Rewriting

For decisions that require Elixir, start an optional OTP session with one dynamic
CSS selector. Native rules still execute first in the same pass:

```elixir
{:ok, session} = Rewriter.start_link(plan, selector: "a[href]")
:ok = Rewriter.demand(session)
{:ok, chunk_ref} = Rewriter.write(session, ~s(<a href="/old">link</a>))

receive do
  {:laughter, ^session, request_ref, {:element, "a", _attrs}} ->
    :ok = Rewriter.reply(session, request_ref, [{:set_attribute, "href", "/new"}])
end

receive do
  {:laughter, ^session, {:output, ^chunk_ref, bytes}} -> IO.binwrite(bytes)
end

:ok = Rewriter.demand(session)
{:ok, eof_ref} = Rewriter.finish(session)

receive do
  {:laughter, ^session, {:output, ^eof_ref, tail}} -> IO.binwrite(tail)
end

receive do
  {:laughter, ^session, :done} -> :ok
end
```

For general documents, handle every element request until the chunk's output
arrives, and handle `{:laughter, session, {:error, reason}}` as a terminal failure.
An empty mutation list keeps an element unchanged. Native removals/replacements
skip dynamic requests; snapshots include native attribute changes.

- `write/2` acknowledges **acceptance**, not completion. It never waits for a reply.
- One output credit permits one write or EOF flush; one chunk can be in flight.
  Output may be empty, but still acknowledges completion and consumes the credit.
- Only the owner may issue commands. Wrong/stale replies are rejected.
- Owner death, cancellation, timeout, and native errors terminate the session.
- `chunk_size`, `max_output_bytes`, `max_reply_bytes`, and `reply_timeout` set limits.
  A reply contains at most 128 mutations. Oversized writes are rejected, not split.
- This mode uses one native worker thread per session. No BEAM scheduler waits for
  replies; there is no polling or process-dictionary callback registration.

Sessions can be supervised as temporary children:

```elixir
{Laughter.Rewriter.Session, {plan, owner: owner_pid, selector: "a[href]"}}
```

They are not restarted automatically: restarting cannot reconstruct consumed input.
See `Laughter.Rewriter.Session` for the full protocol. Prefer `rewrite/2` or
`stream/3` when native rules suffice; neither pays for the OTP/dynamic path.

### Memory Limits

```elixir
# Limit memory usage (bytes)
parser = Laughter.create(builder, max_memory: 16_384)

# Raises if limit exceeded
Laughter.parse(parser, very_large_html)
```

### Encoding

```elixir
# Specify character encoding
parser = Laughter.create(builder, encoding: "utf-8")
```

## Message Format

Matched elements are sent as messages to the registered process:

```elixir
# Element matched
{:element, reference, {tag_name, attributes}}

# Text content (when send_content: true)
{:text, reference, binary}

# Document end
{:end, reference}
```

## CSS Selector Support

Laughter supports standard CSS selectors:

- Tag: `div`, `a`, `span`
- Class: `.content`, `div.main`
- ID: `#header`
- Attribute: `[href]`, `[rel="nofollow"]`
- Combinators: `div > a`, `ul li`, `h1 + p`
- Pseudo-classes: `:nth-child(2)`, `:first-child`

## Performance

Laughter processes HTML in a single pass without building a DOM tree. The
`:max_memory` option bounds LOL HTML's internal buffers, not input/output binaries,
event queues, or receiving-process mailboxes.

Run the declarative-versus-callback rewriting comparison locally:

```sh
mix run bench/rewrite.exs
```

For concurrent-session throughput, timer responsiveness, sampled mailbox pressure,
and memory/lifecycle diagnostics:

```sh
JOBS=2000 ROUNDS=3 ELEMENTS=100 CONCURRENCY=1,8,32 mix run bench/load.exs
```

See [`bench/README.md`](bench/README.md) for methodology and a local baseline.
The internal `Laughter.Nif.rewrite_stats/0` reports live dynamic worker lifetimes,
bounded output buffers, and their reserved capacity. These counters exclude
legacy workers, parser/input/BEAM memory, and whole-document output allocations;
concurrent snapshots are eventually consistent, not an atomic memory profile.
Lifecycle tests wait for all three counters to return to zero.

## Development

The toolchain in `.tool-versions` supports RustQ code generation (Elixir 1.19+ and
Rust 1.91+). RustQ is a development/test-only dependency; generated Rust is checked
in, so production builds do not run the generator.

The boundary is generated from these sources:

| Source | Owns |
| --- | --- |
| `codegen/rewrite.exs` | Typed NIF declarations, codecs, and resource registration |
| `lib/laughter/rewriter/content.ex` + `codegen/content.exs` | Shared content-operation list, builders, and native dispatch |
| `codegen/events.exs` | Typed worker-event and envelope encoders, preserving binary output |
| `codegen/nif.exs` | Elixir stubs derived from generated NIF declarations and legacy Rust signatures |

Do not edit `native/laughter_nif/src/generated_*.rs` or
`lib/laughter/nif/generated_stubs.ex` by hand. Legacy export policy lists names,
not arities; RustQ reads signatures and excludes Rustler's injected `Env` argument.
Worker ownership, channel synchronization, buffering, and cancellation remain
explicit handwritten Rust. `mix rustq.gen --check` verifies all generated targets.

```sh
mix deps.get
mix rustq.gen
mix test
mix rustq.gen --check
cargo clippy --manifest-path native/laughter_nif/Cargo.toml -- -D warnings
```

Before a release, verify the actual Hex archive in a fresh consumer project:

```sh
mix hex.build --output /tmp/laughter.tar
scripts/check-package.sh /tmp/laughter.tar
```

The check extracts the archive, resolves only consumer dependencies, compiles from
scratch, and exercises parsing, legacy callbacks, native plans, streams, and OTP
sessions without RustQ. CI runs the same artifact on Elixir 1.15/OTP 26 and
Elixir 1.19/OTP 27. The consumer fixture lives in `test/fixtures/package_consumer/`
and is not part of the ordinary test suite or published package.

## License

[Apache 2.0](LICENSE) © [Danila Poyarkov](http://dannote.net)

## Credits

- [lol-html](https://github.com/cloudflare/lol-html) - CloudFlare's streaming HTML rewriter
