defmodule Laughter.Rewriter do
  @moduledoc """
  Builds immutable HTML rewrite plans and executes them in one native pass.

      alias Laughter.Rewriter

      plan =
        Rewriter.new()
        |> Rewriter.remove("script")
        |> Rewriter.set_attribute("a[href]", "rel", "nofollow")
        |> Rewriter.remove_attribute("img", "onclick")

      {:ok, output} = Rewriter.rewrite(plan, html)

  Builder functions do not call native code. Plans can be reused and passed
  between processes. Rules run in registration order for each matching element;
  the last attribute write wins. Removing an element removes its content too.
  Selectors match the input HTML, not the output of earlier mutations.
  Inserted HTML is emitted as-is, not parsed again or matched by later rules.

  ## Content operations

  `prepend_text/3`, `append_text/3`, `before_text/3`, `after_text/3`,
  `replace_text/3`, and `set_inner_text/3` escape `&`, `<`, and `>`.
  Their `_html` counterparts insert trusted markup verbatim. Content accepts
  UTF-8 iodata, even when the input document uses a different encoding. These
  operations are not a sanitizer or a JavaScript/CSS escaping API.

  ## Ordering and conflicts in declarative plans

    * Repeated `before` and `append` insertions preserve registration order;
      repeated `prepend` and `after` insertions appear in reverse order.
    * The last `replace` or `remove` wins for an element. Attribute changes
      cannot resurrect it. Surrounding `before`/`after` insertions survive.
    * Inner operations are ignored on removed, replaced, or void elements.
    * `set_inner` replaces original content and discards earlier inner
      insertions. Later `prepend`/`append` operations are retained.
    * Replacing or removing an ancestor suppresses output from its original
      descendants, including their mutations.

  Use `rewrite/2` for complete documents or `stream/3` for lazy chunked input
  and output. The parser's memory limit does not bound total input or output
  size; streaming has a separate per-write output limit.

  The legacy `on_element/3` and `on_text/3` callback API remains available, but
  registrations are process-local and cannot be mixed with declarative rules.
  """

  alias Laughter.Rewriter.Legacy

  defstruct rules: [], encoding: "utf-8", max_memory: 1_048_576, legacy_key: nil

  @type mutation ::
          :remove
          | {:set_attribute, %{name: String.t(), value: String.t()}}
          | {:remove_attribute, String.t()}
          | {content_operation(), String.t()}
  @type rule :: %{selector: String.t(), mutation: mutation()}
  @type reply_mutation ::
          :remove
          | {:set_attribute, String.t(), String.t()}
          | {:remove_attribute, String.t()}
          | {content_operation(), iodata()}
  @opaque t :: %__MODULE__{
            rules: [rule()],
            encoding: String.t(),
            max_memory: pos_integer(),
            legacy_key: reference()
          }
  @type config :: t()
  @type handler_id :: non_neg_integer()
  @type element_handler :: Legacy.element_handler()
  @type text_handler :: Legacy.text_handler()
  @type element_mutation :: Legacy.element_mutation()
  @type text_mutation :: Legacy.text_mutation()

  @doc """
  Creates an empty plan without allocating native resources.

  Options are `:encoding` (default `"utf-8"`) and `:max_memory` (default
  `1_048_576` bytes, for LOL HTML's internal buffers only). Unknown options and
  invalid option types raise `ArgumentError`; unsupported encodings and invalid
  CSS selectors return errors when the plan is executed.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, encoding: "utf-8", max_memory: 1_048_576)
    encoding = Keyword.fetch!(opts, :encoding)
    max_memory = Keyword.fetch!(opts, :max_memory)

    unless is_binary(encoding) and is_integer(max_memory) and max_memory > 0 do
      raise ArgumentError, "expected a binary encoding and positive integer max_memory"
    end

    %__MODULE__{encoding: encoding, max_memory: max_memory, legacy_key: make_ref()}
  end

  @doc "Removes matched elements, including their content."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = plan, selector) when is_binary(selector) do
    add_rule(plan, selector, :remove)
  end

  @doc "Sets an attribute on matched elements. Values are escaped by LOL HTML."
  @spec set_attribute(t(), String.t(), String.t(), String.t()) :: t()
  def set_attribute(%__MODULE__{} = plan, selector, name, value)
      when is_binary(selector) and is_binary(name) and is_binary(value) do
    add_rule(plan, selector, {:set_attribute, %{name: name, value: value}})
  end

  @doc "Removes an attribute from matched elements. Missing attributes are ignored."
  @spec remove_attribute(t(), String.t(), String.t()) :: t()
  def remove_attribute(%__MODULE__{} = plan, selector, name)
      when is_binary(selector) and is_binary(name) do
    add_rule(plan, selector, {:remove_attribute, name})
  end

  require Laughter.Rewriter.Content
  Laughter.Rewriter.Content.builders()

  @doc """
  Rewrites a complete document in one native pass, returning a binary.

  Declarative plans execute on a dirty CPU scheduler, without worker threads,
  per-element messages, or Elixir callbacks. Rules are decoded once per call.
  """
  @spec rewrite(t(), iodata()) :: {:ok, binary()} | {:error, term()}
  def rewrite(%__MODULE__{} = plan, html) do
    case {plan.rules, Process.get(legacy_key(plan))} do
      {[], config} when not is_nil(config) ->
        Legacy.rewrite(config, html)

      {[_ | _], config} when not is_nil(config) ->
        {:error, :mixed_rewrite_modes}

      {rules, nil} ->
        Laughter.Nif.rewrite_plan(
          IO.iodata_to_binary(html),
          Enum.reverse(rules),
          plan.encoding,
          plan.max_memory
        )
    end
  end

  @doc """
  Lazily rewrites an enumerable of binary or iodata chunks into binary chunks.

      File.stream!("input.html", [], 65_536)
      |> Laughter.Rewriter.stream(plan)
      |> Stream.into(File.stream!("output.html"))
      |> Stream.run()

  Each enumeration opens a fresh native session and decodes the plan once.
  Output is emitted as it becomes available; chunk boundaries need not match
  the input and may split encoded characters. EOF flushes any pending bytes.
  Early halt or an exception closes
  the session without flushing. Legacy callbacks are not supported.

  ## Options and bounds

    * `:chunk_size` — maximum bytes per native write (default `65_536`).
      Larger source chunks are split lazily.
    * `:max_output_bytes` — maximum buffered output from one native write or
      EOF flush (default `1_048_576`). Expansion beyond this limit fails the
      session instead of accumulating unbounded output.

  Limits must be positive integers. Together with the plan's `:max_memory`,
  these bound native parser/output buffering independently of document length.
  They do not bound the plan's size, upstream chunk allocations, or output
  retained by the consumer. Each iodata source chunk is converted to a binary
  before splitting; use bounded upstream chunks for bounded end-to-end memory.

  Native errors raise `Laughter.Rewriter.Error` during enumeration. Previously
  emitted output cannot be rolled back. Exceptions from the source or consumer
  propagate unchanged, with session cleanup still performed.
  """
  @spec stream(Enumerable.t(), t(), keyword()) :: Enumerable.t()
  def stream(chunks, %__MODULE__{} = plan, opts \\ []) do
    opts = Keyword.validate!(opts, chunk_size: 65_536, max_output_bytes: 1_048_576)
    chunk_size = Keyword.fetch!(opts, :chunk_size)
    max_output_bytes = Keyword.fetch!(opts, :max_output_bytes)

    unless is_integer(chunk_size) and chunk_size > 0 and
             is_integer(max_output_bytes) and max_output_bytes > 0 do
      raise ArgumentError, "expected positive integer chunk_size and max_output_bytes"
    end

    ensure_streamable!(plan)

    chunks
    |> Stream.flat_map(&split_chunk(&1, chunk_size))
    |> Stream.transform(
      fn ->
        ensure_streamable!(plan)

        Laughter.Nif.rewrite_stream_new(
          Enum.reverse(plan.rules),
          plan.encoding,
          plan.max_memory,
          chunk_size,
          max_output_bytes
        )
        |> stream_result!()
      end,
      fn chunk, session ->
        {stream_output!(Laughter.Nif.rewrite_stream_write(session, chunk)), session}
      end,
      fn session ->
        {stream_output!(Laughter.Nif.rewrite_stream_finish(session)), session}
      end,
      &Laughter.Nif.rewrite_stream_close/1
    )
  end

  defp split_chunk(chunk, chunk_size) do
    chunk
    |> IO.iodata_to_binary()
    |> Stream.unfold(fn
      "" ->
        nil

      remaining ->
        size = min(byte_size(remaining), chunk_size)
        <<head::binary-size(size), tail::binary>> = remaining
        {head, tail}
    end)
  end

  defp ensure_streamable!(plan) do
    if Process.get(legacy_key(plan)) do
      raise ArgumentError, "rewrite streams do not support legacy callbacks"
    end
  end

  defp stream_output!(result) do
    case stream_result!(result) do
      "" -> []
      output -> [output]
    end
  end

  defp stream_result!({:ok, value}), do: value
  defp stream_result!({:error, reason}), do: raise(Laughter.Rewriter.Error, reason: reason)

  @doc false
  @spec native_config(t()) :: {[rule()], %{encoding: String.t(), max_memory: pos_integer()}}
  def native_config(%__MODULE__{} = plan) do
    {Enum.reverse(plan.rules), %{encoding: plan.encoding, max_memory: plan.max_memory}}
  end

  @doc """
  Starts an optional message-driven rewrite session linked to the caller.

  Requires `selector: "..."`. The owner defaults to the caller. See
  `Laughter.Rewriter.Session` for the demand/reply protocol, limits, and supervision.
  """
  @spec start_link(t(), keyword()) :: GenServer.on_start()
  def start_link(%__MODULE__{} = plan, opts) do
    ensure_streamable!(plan)
    Laughter.Rewriter.Session.start_link({plan, Keyword.put_new(opts, :owner, self())})
  end

  @doc "Grants one output credit to a message-driven session."
  @spec demand(pid()) :: :ok | {:error, term()}
  defdelegate demand(session), to: Laughter.Rewriter.Session
  @doc "Accepts one bounded input chunk without waiting for handler replies."
  @spec write(pid(), iodata()) :: {:ok, reference()} | {:error, term()}
  defdelegate write(session, chunk), to: Laughter.Rewriter.Session
  @doc "Accepts EOF for a message-driven session; requires output credit."
  @spec finish(pid()) :: {:ok, reference()} | {:error, term()}
  defdelegate finish(session), to: Laughter.Rewriter.Session
  @doc "Replies to a dynamic element request with a list of mutations."
  @spec reply(pid(), reference(), [reply_mutation()]) :: :ok | {:error, term()}
  defdelegate reply(session, request_ref, mutations), to: Laughter.Rewriter.Session
  @doc "Cancels a message-driven session and discards pending output."
  @spec cancel(pid()) :: :ok | {:error, term()}
  defdelegate cancel(session), to: Laughter.Rewriter.Session

  @doc """
  Registers a legacy element callback in the calling process.

  Use the declarative builders for native execution. Callback registration and
  rewriting must happen in the same process, as in the original API.
  """
  @spec on_element(t(), String.t(), element_handler()) :: handler_id()
  def on_element(%__MODULE__{} = plan, selector, handler) when is_function(handler, 2) do
    Legacy.on_element(legacy_config(plan), selector, handler)
  end

  @doc "Registers a legacy text callback in the calling process."
  @spec on_text(t(), String.t(), text_handler()) :: handler_id()
  def on_text(%__MODULE__{} = plan, selector, handler) when is_function(handler, 2) do
    Legacy.on_text(legacy_config(plan), selector, handler)
  end

  defp add_rule(plan, selector, mutation) do
    %{plan | rules: [%{selector: selector, mutation: mutation} | plan.rules]}
  end

  defp legacy_key(plan), do: {__MODULE__, :legacy, plan.legacy_key}

  defp legacy_config(plan) do
    key = legacy_key(plan)

    case Process.get(key) do
      nil ->
        config = Legacy.new(encoding: plan.encoding, max_memory: plan.max_memory)
        Process.put(key, config)
        config

      config ->
        config
    end
  end
end
