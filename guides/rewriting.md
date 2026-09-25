# Rewriting HTML

[Back to the README](../README.md)

Declarative plans are immutable, reusable across processes, and built without
native allocations. Execution decodes rules once and runs on a dirty CPU scheduler
without per-element callbacks or messages.

## Content operations

```elixir
alias Laughter.Rewriter

plan =
  Rewriter.new()
  |> Rewriter.prepend_html("body", "<header>Notice</header>")
  |> Rewriter.set_inner_text(".title", ["Hello, ", "world!"])
  |> Rewriter.after_html("article", "<hr>")
  |> Rewriter.replace_text(".redacted", "[removed]")

html = ~s(<body><h1 class="title">Old</h1><article>News</article></body>)
{:ok, output} = Rewriter.rewrite(plan, html)
```

Available pairs: `prepend_text/html`, `append_text/html`, `before_text/html`,
`after_text/html`, `replace_text/html`, and `set_inner_text/html`.

- Text operations escape `&`, `<`, and `>`.
- HTML operations insert trusted markup verbatim.
- Content accepts UTF-8 iodata, even when the document uses a different encoding.
- Inserted HTML is not reparsed or matched by later rules.

These operations are not an HTML sanitizer or a JavaScript/CSS escaping API.

## Matching, ordering, and conflicts

Selectors match the original input, not attributes changed by earlier rules.
Rules run in registration order for each matching element.

- The last attribute write wins.
- Repeated `before` and `append` insertions preserve order; `prepend` and `after`
  insertions appear in reverse order.
- The last `remove` or `replace` wins. Attribute changes cannot resurrect the
  element. Surrounding `before`/`after` insertions survive.
- Inner operations are ignored on removed, replaced, or void elements.
- `set_inner` discards original content and earlier inner insertions. Later
  `prepend`/`append` operations remain.
- Removing or replacing an ancestor suppresses output from its original
  descendants, including their mutations.

## Streaming and bounds

```elixir
alias Laughter.Rewriter

plan = Rewriter.new(max_memory: 1_048_576) |> Rewriter.remove("script")

["<scr", "ipt>bad()</script><p>hello</p>"]
|> Rewriter.stream(plan, chunk_size: 65_536, max_output_bytes: 1_048_576)
|> Enum.each(&IO.binwrite/1)
```

Each enumeration opens a fresh native session. Output consists of binary chunks;
EOF flushes pending bytes. Early halt or failure closes the session without
flushing. No GenServer or worker thread is needed for this mode.

| Option | Bounds | Default |
| --- | --- | ---: |
| Plan `:max_memory` | LOL HTML's internal parser buffers | 1,048,576 bytes |
| Stream `:chunk_size` | Bytes submitted per native write | 65,536 bytes |
| Stream `:max_output_bytes` | Buffered output per write or EOF flush | 1,048,576 bytes |

Limits must be positive integers. Larger source chunks are split lazily, but each
iodata source chunk is converted to a binary first. Limits do not cover the plan,
upstream allocations, or output retained by consumers. For bounded end-to-end
memory, use bounded source chunks and consume output incrementally.

Output boundaries may split encoded characters. Concatenate before decoding a
complete result, or use an incremental decoder for streamed text.

Excessive output expansion fails the session. Decrease `chunk_size` or increase
`max_output_bytes` if a transformation legitimately needs more output space.
Native errors raise `Laughter.Rewriter.Error`; source/consumer exceptions propagate
unchanged. Already-emitted output cannot be rolled back.

Whole-document `rewrite/2` instead returns `{:ok, binary}` or `{:error, reason}`
for native failures and has no streaming output cap. Its parser memory limit does
not bound the returned output binary.

## Legacy callbacks

```elixir
alias Laughter.Rewriter

plan = Rewriter.new()
Rewriter.on_element(plan, "a", fn _tag, _attrs -> [{:set_attribute, "rel", "nofollow"}] end)
{:ok, output} = Rewriter.rewrite(plan, ~s(<a href="/">Home</a>))
```

`on_element/3` and `on_text/3` remain available for compatibility. Registration and
execution must happen in the same process. Mixing callbacks with declarative rules
returns `{:error, :mixed_rewrite_modes}`; the new stream/session APIs do not support
legacy callbacks. For new Elixir-driven transformations, see
[Message-driven sessions](sessions.md).
