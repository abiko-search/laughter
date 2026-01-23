# Laughter

[![CI](https://github.com/abiko-search/laughter/workflows/Elixir%20CI/badge.svg)](https://github.com/abiko-search/laughter/actions)

A **streaming HTML parser** for Elixir built on top of CloudFlare's [LOL HTML](https://github.com/cloudflare/lol-html).

## Why Laughter?

Unlike traditional DOM-based parsers (like Floki), Laughter processes HTML **as it streams in**, making it ideal for:

- **Crawlers** - Extract links as the page downloads, not after
- **Large documents** - Constant memory usage regardless of document size  
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
    {:laughter, "~> 0.2.0", github: "abiko-search/laughter", submodules: true}
  ]
end
```

**Requirements:**
- Elixir ~> 1.15
- Rust (for compilation)

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

Laughter processes HTML in a single pass without building a DOM tree:

| Parser | Memory (1MB HTML) | Time |
|--------|-------------------|------|
| Floki | ~10MB | ~50ms |
| Laughter | ~16KB (constant) | ~20ms |

## License

[Apache 2.0](LICENSE) © [Danila Poyarkov](http://dannote.net)

## Credits

- [lol-html](https://github.com/cloudflare/lol-html) - CloudFlare's streaming HTML rewriter
