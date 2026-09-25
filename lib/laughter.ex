defmodule Laughter do
  @moduledoc """
  A streaming HTML parser for Elixir built on top of the CloudFlare's
  😂 [LOL HTML](https://github.com/cloudflare/lol-html).
  """

  @type builder_ref :: reference
  @type parser_ref :: reference
  @type filter_ref :: non_neg_integer

  @doc """
  Creates a parser builder.
  """
  @spec build() :: builder_ref
  defdelegate build(), to: Laughter.Nif

  @doc """
  Selects which elements to stream and where to send them.

  Returns a filter reference that will be included in messages.

  The fourth argument is either the legacy `send_content` boolean or a
  keyword list:

    * `:text` - also send the text inside matched elements as
      `{:text, ref, content}`. Defaults to `false`.
    * `:end_tag` - send `{:end_tag, ref, tag}` when a matched element's
      explicit end tag is seen. Elements closed implicitly (an unclosed
      `<p>` followed by another `<p>`) never produce one. Defaults to `false`.
    * `:raw_text` - with `:text`, also deliver the contents of `<script>`,
      `<style>`, and similar raw-text elements. Defaults to `false`, so only
      visible text and the contents of `<title>` and `<textarea>` are sent.

  ## Examples

      ref = Laughter.filter(builder, self(), ".content > a")
      # Messages will be: {:element, ref, {tag, attrs}}

      ref = Laughter.filter(builder, self(), "p", text: true, end_tag: true)
      # Messages: {:element, ref, {"p", attrs}}, {:text, ref, "..."}, {:end_tag, ref, "p"}
  """
  @spec filter(builder_ref, pid, binary, boolean | keyword) :: filter_ref
  def filter(builder, pid, selector, opts \\ false)

  def filter(builder, pid, selector, send_content) when is_boolean(send_content) do
    filter(builder, pid, selector, text: send_content)
  end

  def filter(builder, pid, selector, opts) when is_list(opts) do
    Laughter.Nif.filter(
      builder,
      pid,
      selector,
      Keyword.get(opts, :text, false),
      Keyword.get(opts, :end_tag, false),
      Keyword.get(opts, :raw_text, false)
    )
  end

  @doc """
  Streams every text chunk in the document, whatever element it is in.

  Returns a filter reference; messages are `{:text, ref, content}` and, at
  the end, `{:end, ref}`. Unlike `filter/4` with `text: true` on `body`, this
  fires exactly once per chunk and works on documents that omit `<body>`.
  Contents of `<script>`, `<style>`, and other raw-text elements are skipped
  unless `raw_text: true`; `<title>` and `<textarea>` text is included.

  ## Examples

      ref = Laughter.document_text(builder, self())
  """
  @spec document_text(builder_ref, pid, keyword) :: filter_ref
  def document_text(builder, pid, opts \\ []) do
    Laughter.Nif.document_text(builder, pid, Keyword.get(opts, :raw_text, false))
  end

  @doc """
  Creates a parser from a parser builder.

  ## Options

    * `:encoding` - the charset of the file, such as `"utf-8"`.
      Defaults to `"utf-8"`.
    * `:max_memory` - maximum allowed size of buffer.
      Defaults to `16_384`.
  """
  @spec create(builder_ref, Keyword.t()) :: parser_ref
  def create(builder, opts \\ []) do
    encoding = Keyword.get(opts, :encoding, "utf-8")
    max_memory = Keyword.get(opts, :max_memory, 16_384)

    Laughter.Nif.create(builder, encoding, max_memory)
  end

  @doc """
  Parses a chunk of HTML. Returns the parser for pipelining.
  """
  @spec parse(parser_ref, iodata) :: parser_ref
  def parse(parser, chunk) when is_binary(chunk) do
    Laughter.Nif.parse(parser, chunk)
  end

  def parse(parser, chunk) when is_list(chunk) do
    Laughter.Nif.parse(parser, IO.iodata_to_binary(chunk))
  end

  @doc """
  Must be called once you are done parsing.
  """
  @spec done(parser_ref) :: :ok
  def done(parser) do
    Laughter.Nif.done(parser)
  end
end
