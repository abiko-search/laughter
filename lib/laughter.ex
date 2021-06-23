defmodule Laughter do
  @moduledoc """
  A streaming HTML parser for Elixir built on top of the CloudFlare's
  😂 [LOL HTML](https://github.com/cloudflare/lol-html).
  """

  @type builder_ref :: reference
  @type parser_ref :: reference

  @doc """
  Creates a parser builder.
  """
  @spec build() :: builder_ref
  defdelegate build(), to: Laughter.Nif

  @doc """
  Selects which elements to stream and where to send them.

  ## Examples

      Laughter.stream_elements(builder, self(), ".content > a")
  """
  @spec stream_elements(builder_ref, pid, binary, boolean) :: reference
  defdelegate stream_elements(builder, pid, selector, send_content \\ false), to: Laughter.Nif

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
  Parses a chunk.
  """
  @spec parse(parser_ref, iodata) :: parser_ref
  defdelegate parse(parser, chunk), to: Laughter.Nif

  @doc """
  Must be called once you are done.
  """
  @spec done(parser_ref) :: parser_ref
  defdelegate done(parser), to: Laughter.Nif
end
