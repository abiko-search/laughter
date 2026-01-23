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

  ## Examples

      ref = Laughter.filter(builder, self(), ".content > a")
      # Messages will be: {:element, ref, {tag, attrs}}
  """
  @spec filter(builder_ref, pid, binary, boolean) :: filter_ref
  def filter(builder, pid, selector, send_content \\ false) do
    Laughter.Nif.filter(builder, pid, selector, send_content)
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
