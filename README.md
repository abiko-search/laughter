# Laughter

[![CI](https://github.com/abiko-search/laughter/actions/workflows/elixir.yml/badge.svg)](https://github.com/abiko-search/laughter/actions/workflows/elixir.yml)

A streaming HTML parser and rewriter for Elixir, powered by Cloudflare's
[LOL HTML](https://github.com/cloudflare/lol-html). Extract data or transform HTML
incrementally, without building a DOM tree.

## Choose an API

| Task | API |
| --- | --- |
| Extract elements or text as HTML arrives | `Laughter` parser and messages |
| Transform a complete document with native rules | `Laughter.Rewriter.rewrite/2` |
| Transform a stream of chunks with native rules | `Laughter.Rewriter.stream/3` |
| Make per-element decisions in Elixir | Message-driven rewrite sessions |

Prefer native rules when possible: they run in one pass without per-element
callbacks or messages. Plans are immutable and reusable across processes. Mutable
parser handles must receive ordered input; thread safety does not order concurrent
calls. Native buffer limits do not bound total application memory.

## Installation

**0.3.0 is prepared but not yet published.** To try these APIs now, use a local
checkout containing the 0.3.0 changes:

```elixir
def deps do
  [{:laughter, path: "../laughter"}]
end
```

A Git dependency can be used once the changes are available remotely; pin a
commit or tag for reproducibility. Git dependencies do not select a release from
a Hex version requirement. No Git submodules are needed by the current native
crate.

Consumers need Elixir 1.15+ (before 2.0) and Rust/Cargo for native compilation.
Contributing and regenerating the native boundary require a newer toolchain;
see [Development](guides/development.md). RustQ is not a consumer dependency.

## Quick start

### Extract links

```elixir
builder = Laughter.build()
link_ref = Laughter.filter(builder, self(), "a[href]")

builder
|> Laughter.create()
|> Laughter.parse("<a href='/about'>")
|> Laughter.parse("About us</a>")
|> Laughter.done()

receive do
  {:element, ^link_ref, {"a", attrs}} -> IO.inspect(attrs)
end
# [{"href", "/about"}]

receive do
  {:end, ^link_ref} -> :ok
end
```

Register all selectors before `create/2`. Feed chunks in order, then call `done/1`
to finish parsing. In a real streaming application, consume messages as input
arrives rather than allowing the receiver's mailbox to grow.

### Rewrite HTML

```elixir
alias Laughter.Rewriter

plan =
  Rewriter.new()
  |> Rewriter.remove("script")
  |> Rewriter.set_attribute("a[href]", "rel", "nofollow")

html = ~s|<script>bad()</script><a href="/about">About us</a>|
{:ok, output} = Rewriter.rewrite(plan, html)
# output: ~s(<a href="/about" rel="nofollow">About us</a>)
```

`rewrite/2` accepts binary or iodata input and returns `{:ok, binary}` or
`{:error, reason}` for native failures. Selectors match the original input;
inserted HTML is not reparsed or matched by later rules. Removing scripts alone
is **not** HTML sanitization.

### Rewrite a file incrementally

```elixir
alias Laughter.Rewriter

plan = Rewriter.new() |> Rewriter.remove("script")

File.stream!("input.html", [], 65_536)
|> Rewriter.stream(plan)
|> Stream.into(File.stream!("output.html"))
|> Stream.run()
```

Each enumeration opens a fresh native session. EOF flushes pending bytes; early
halt or failure closes the session. Native failures raise
`Laughter.Rewriter.Error`. Already-written output cannot be rolled back.

The defaults are 65,536 input bytes per native write and 1,048,576 buffered output
bytes per write or EOF flush. Larger source chunks are split, but the source's
allocation and output retained by the consumer are not covered by these limits.
See [Rewriting](guides/rewriting.md) for options, content operations, and ordering.

## Parser messages

`filter/4` accepts CSS selectors and options such as `text: true`, `end_tag: true`,
and `raw_text: true`. Use `document_text/3` to receive each document text chunk
once, even when the document has no `<body>`.

| Message | When sent |
| --- | --- |
| `{:element, ref, {tag, attrs}}` | A selected element starts |
| `{:text, ref, content}` | Text extraction is enabled |
| `{:end_tag, ref, tag}` | An explicit end tag is seen with `end_tag: true` |
| `{:end, ref}` | Document processing finishes |

Text excludes raw-text content such as scripts and styles unless `raw_text: true`.
Title and textarea text are included by default. This is not CSS visibility
filtering. Implicitly closed and void elements do not emit end-tag events.

See [Parsing](guides/parsing.md) for complete examples, encodings, and memory limits.

## Decisions in Elixir

For transformations that need Elixir code, use an optional OTP session with one
dynamic CSS selector. The owner grants demand, submits a chunk, handles element
requests, and receives output. Sessions support timeouts, cancellation, and
owner monitoring; each uses one native worker thread.

See [Message-driven sessions](guides/sessions.md) for a complete receive loop and
supervision. Native `rewrite/2` and `stream/3` do not pay for this process/thread
coordination.

## Upgrading from 0.2

- To preserve all-text extraction, replace the legacy `true` argument with
  `text: true, raw_text: true`.
- `Rewriter.new/1` now returns an opaque plan, not a native reference. Recreate
  configurations and remove reference-specific assumptions.
- Existing `on_element/3` and `on_text/3` callback usage still works in the same
  process. Do not mix callbacks with native rules or the new stream/session APIs.
- Rewriter options reject unknown keys and nonpositive memory limits; declarative
  rewrites reject unsupported encodings instead of silently using UTF-8.

See [CHANGELOG.md](CHANGELOG.md) for the full release scope.

## Further reading

- [Parsing](guides/parsing.md)
- [Rewriting and content semantics](guides/rewriting.md)
- [Message-driven sessions](guides/sessions.md)
- [Benchmarks and measurement limitations](bench/README.md)
- [Development and package checks](guides/development.md)

## License

[Apache 2.0](LICENSE) © [Danila Poyarkov](http://dannote.net)
