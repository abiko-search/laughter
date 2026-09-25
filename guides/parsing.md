# Parsing HTML

[Back to the README](../README.md)

Register selectors on a builder, create a parser, feed ordered chunks, and finish
with `Laughter.done/1`. The parser sends messages to the PID registered for each
filter. References in these messages identify registrations.

## Extract text

```elixir
builder = Laughter.build()
ref = Laughter.filter(builder, self(), "title", text: true)

builder
|> Laughter.create()
|> Laughter.parse("<title>My Page</title>")
|> Laughter.done()

receive do
  {:element, ^ref, {"title", []}} -> :ok
end

receive do
  {:text, ^ref, text} -> IO.puts(text)
end
```

For arbitrary streaming input, text can arrive in multiple chunks. Consume all
matching messages until `{:end, ref}` rather than assuming one text message per
element. Text handlers on overlapping/nested selectors can observe the same
text; use `document_text/3` when you want each document text chunk once.

## Document text and explicit end tags

```elixir
builder = Laughter.build()
text_ref = Laughter.document_text(builder, self())
paragraph_ref = Laughter.filter(builder, self(), "p", end_tag: true)

builder
|> Laughter.create()
|> Laughter.parse("<p>Hello</p>")
|> Laughter.done()

receive do
  {:text, ^text_ref, text} -> IO.puts(text)
end

receive do
  {:end_tag, ^paragraph_ref, "p"} -> :ok
end
```

Document text works without a `<body>` element. Both text APIs skip raw-text
content, including scripts and styles, unless `raw_text: true`. Title and textarea
text are included by default. This does not evaluate CSS visibility or sanitize HTML.

End-tag events require an explicit end tag in the input. Implicitly closed elements
(such as a `<p>` followed by another `<p>`) and void elements do not emit one.

## Multiple selectors

```elixir
builder = Laughter.build()
links = Laughter.filter(builder, self(), "a[href]")
images = Laughter.filter(builder, self(), "img[src]")
html = ~s(<a href="/">Home</a><img src="logo.png">)

builder |> Laughter.create() |> Laughter.parse(html) |> Laughter.done()

receive do
  {:element, ^links, {"a", attrs}} -> IO.inspect(attrs)
end

receive do
  {:element, ^images, {"img", attrs}} -> IO.inspect(attrs)
end
```

Selectors include tags, classes, IDs, attributes, combinators, and supported
pseudo-classes such as `:nth-child(2)` and `:first-child`. Examples:
`div.main`, `a[href]`, `div > a`, `ul li`, and `h1 + p`.

## Memory, encoding, and concurrency

```elixir
builder = Laughter.build()
parser = Laughter.create(builder, encoding: "utf-8", max_memory: 16_384)
parser |> Laughter.parse("<p>hello</p>") |> Laughter.done()
```

The memory limit covers LOL HTML's internal buffers, not input binaries, queued
parser events, or receiving-process mailboxes. Consume messages as input arrives
and keep upstream chunks bounded. Parser failures raise exceptions.

Mutex protection makes native access thread-safe, but does not impose an input
order on concurrent callers. Coordinate writes and completion through one owner
when parsing a single document; use separate parsers for independent documents.
