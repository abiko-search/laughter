defmodule Laughter.Rewriter.Session do
  @moduledoc """
  Temporary OTP session for one dynamic element selector plus native rules.

  Supervise with `{Laughter.Rewriter.Session, {plan, owner: owner, selector: "a"}}`.
  The explicit owner is monitored; a session is not restarted because consumed
  input cannot be replayed. `Laughter.Rewriter.start_link/2` defaults the owner
  to the caller. All commands must come from that owner.

  Grant one output credit with `demand/1`, then `write/2` or `finish/1`. A write
  acknowledges acceptance immediately and does not wait for element replies.
  Only one chunk may be in flight. Output (including an empty binary) acknowledges
  its completion. Grant another credit before the next write or final flush.

  Messages sent to the owner:

    * `{:laughter, session, request_ref, {:element, tag, attrs}}`
    * `{:laughter, session, {:output, chunk_ref, binary}}`
    * `{:laughter, session, :done}` — after the final output
    * `{:laughter, session, {:error, reason}}` — terminal failure/cancellation

  Reply with `reply/3` and a list of mutation tuples, e.g.
  `[{:set_attribute, "href", "/new"}, {:append_text, "!"}]`, or `[]` to keep it.
  Native rules run first; removed/replaced elements do not generate requests.
  The snapshot includes native attribute changes. Inserted HTML is not reparsed.

  Options: required `:owner` and `:selector`; `:chunk_size` (65,536 bytes),
  `:max_output_bytes` (1,048,576 bytes), `:reply_timeout` (5,000 milliseconds),
  and `:max_reply_bytes` (1,048,576 external-term bytes, at most 128 mutations).
  The plan supplies the encoding and parser memory limit. Oversized writes are
  rejected rather than split. Previously emitted output cannot be rolled back.

  This opt-in mode uses one native worker thread per session. No BEAM scheduler
  waits for replies and there is no polling. Use native `stream/3` when decisions
  do not need Elixir. Limits bound native buffers and in-flight work, not data
  retained in the owner's mailbox; only request output you can consume.
  """

  use GenServer, restart: :temporary

  alias Laughter.{Nif, Rewriter}
  @content_ops Enum.map(Laughter.Rewriter.Content.operations(), & &1.name)

  @spec start_link({Rewriter.t(), keyword()}) :: GenServer.on_start()
  def start_link({plan, opts}) do
    opts =
      Keyword.validate!(opts, [
        :owner,
        :selector,
        chunk_size: 65_536,
        max_output_bytes: 1_048_576,
        reply_timeout: 5_000,
        max_reply_bytes: 1_048_576
      ])

    owner = Keyword.fetch!(opts, :owner)
    selector = Keyword.fetch!(opts, :selector)

    unless is_pid(owner) and node(owner) == node() and is_binary(selector) and
             String.valid?(selector) do
      raise ArgumentError, "expected a local owner PID and a UTF-8 selector"
    end

    for key <- [:chunk_size, :max_output_bytes, :reply_timeout, :max_reply_bytes] do
      unless is_integer(opts[key]) and opts[key] > 0 do
        raise ArgumentError, "expected positive integer #{key}"
      end
    end

    if opts[:reply_timeout] > 4_294_967_295 do
      raise ArgumentError, "reply_timeout exceeds the supported timer range"
    end

    {rules, plan_options} = Rewriter.native_config(plan)
    GenServer.start_link(__MODULE__, {rules, plan_options, Map.new(opts)})
  end

  @doc "Grants one output credit. Does not accumulate credits."
  @spec demand(pid()) :: :ok | {:error, term()}
  def demand(session), do: GenServer.call(session, :demand)

  @doc "Accepts one bounded chunk, returning its output reference without waiting for parsing."
  @spec write(pid(), iodata()) :: {:ok, reference()} | {:error, term()}
  def write(session, chunk), do: GenServer.call(session, {:write, IO.iodata_to_binary(chunk)})

  @doc "Accepts EOF; requires output demand for the final flush."
  @spec finish(pid()) :: {:ok, reference()} | {:error, term()}
  def finish(session), do: GenServer.call(session, :finish)

  @doc "Replies to the current element request. Invalid replies may be corrected before timeout."
  @spec reply(pid(), reference(), [Rewriter.reply_mutation()]) :: :ok | {:error, term()}
  def reply(session, ref, mutations), do: GenServer.call(session, {:reply, ref, mutations})

  @doc "Cancels the session, discarding pending output."
  @spec cancel(pid()) :: :ok | {:error, term()}
  def cancel(session), do: GenServer.call(session, :cancel)

  @impl true
  def init({rules, plan_options, opts}) do
    Process.flag(:trap_exit, true)
    token = make_ref()

    native_opts =
      Map.take(opts, [:chunk_size, :max_output_bytes, :reply_timeout])
      |> Map.merge(plan_options)

    case Nif.rewrite_dynamic_new(
           rules,
           opts.selector,
           native_opts,
           self(),
           token
         ) do
      {:ok, native} ->
        {:ok,
         %{
           native: native,
           token: token,
           owner: opts.owner,
           monitor: Process.monitor(opts.owner),
           opts: opts,
           credit: false,
           active: nil,
           pending: nil,
           next_id: 1
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(_, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, :not_owner}, state}

  def handle_call(:cancel, _, state) do
    notify(state, {:error, :cancelled})
    {:stop, :normal, :ok, state}
  end

  def handle_call(:demand, _, %{active: active} = state) when not is_nil(active),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:demand, _, %{credit: true} = state),
    do: {:reply, {:error, :already_demanded}, state}

  def handle_call(:demand, _, state), do: {:reply, :ok, %{state | credit: true}}

  def handle_call({:reply, ref, mutations}, _, %{pending: %{ref: ref} = pending} = state) do
    with {:ok, mutations} <- normalize_mutations(mutations, state.opts.max_reply_bytes),
         :ok <- Nif.rewrite_dynamic_reply(state.native, pending.id, mutations) do
      Process.cancel_timer(pending.timer)
      {:reply, :ok, %{state | pending: nil}}
    else
      {:error, :invalid_mutations} = error ->
        {:reply, error, state}

      {:error, reason} ->
        notify(state, {:error, reason})
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:reply, _, _}, _, state), do: {:reply, {:error, :stale_request}, state}
  def handle_call({:write, input}, _, state), do: accept(state, {:write, input})
  def handle_call(:finish, _, state), do: accept(state, :finish)
  def handle_call(_, _, state), do: {:reply, {:error, :invalid_request}, state}

  defp accept(%{active: active} = state, _) when not is_nil(active),
    do: {:reply, {:error, :busy}, state}

  defp accept(%{credit: false} = state, _), do: {:reply, {:error, :no_demand}, state}

  defp accept(state, {:write, input}) when byte_size(input) > state.opts.chunk_size,
    do: {:reply, {:error, :input_limit}, state}

  defp accept(state, command) do
    id = state.next_id

    result =
      case command do
        {:write, input} -> Nif.rewrite_dynamic_write(state.native, id, input)
        :finish -> Nif.rewrite_dynamic_finish(state.native, id)
      end

    case result do
      :ok ->
        ref = make_ref()
        active = %{id: id, ref: ref, finishing: command == :finish}
        {:reply, {:ok, ref}, %{state | active: active, credit: false, next_id: id + 1}}

      {:error, reason} ->
        notify(state, {:error, reason})
        {:stop, :normal, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:laughter_native, token, {:element, id, tag, attrs}},
        %{token: token, active: active, pending: nil} = state
      )
      when not is_nil(active) do
    ref = make_ref()
    timer = Process.send_after(self(), {:reply_timeout, ref}, state.opts.reply_timeout)
    send(state.owner, {:laughter, self(), ref, {:element, tag, attrs}})
    {:noreply, %{state | pending: %{ref: ref, id: id, timer: timer}}}
  end

  def handle_info(
        {:laughter_native, token, {:output, id, binary, finished}},
        %{token: token, active: %{id: id, ref: ref, finishing: finished}, pending: nil} = state
      ) do
    notify(state, {:output, ref, binary})

    if finished do
      notify(state, :done)
      {:stop, :normal, %{state | active: nil}}
    else
      {:noreply, %{state | active: nil}}
    end
  end

  def handle_info({:laughter_native, token, {:error, reason}}, %{token: token} = state) do
    reason = if reason == "reply timeout", do: :reply_timeout, else: reason
    notify(state, {:error, reason})
    {:stop, :normal, state}
  end

  def handle_info({:reply_timeout, ref}, %{pending: %{ref: ref}} = state) do
    notify(state, {:error, :reply_timeout})
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _},
        %{monitor: monitor, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.pending, do: Process.cancel_timer(state.pending.timer)
    Nif.rewrite_dynamic_close(state.native)
  end

  defp notify(state, message), do: send(state.owner, {:laughter, self(), message})

  defp normalize_mutations(mutations, limit) do
    with true <- is_list(mutations),
         {_, []} <- Enum.split(mutations, 128),
         true <- :erlang.external_size(mutations) <= limit do
      {:ok, Enum.map(mutations, &normalize_mutation/1)}
    else
      _ -> {:error, :invalid_mutations}
    end
  rescue
    ArgumentError -> {:error, :invalid_mutations}
    FunctionClauseError -> {:error, :invalid_mutations}
  end

  defp normalize_mutation(:remove), do: :remove

  defp normalize_mutation({:set_attribute, name, value}),
    do: {:set_attribute, %{name: utf8!(name), value: utf8!(value)}}

  defp normalize_mutation({:remove_attribute, name}), do: {:remove_attribute, utf8!(name)}

  defp normalize_mutation({name, content}) when name in @content_ops,
    do: {name, content |> IO.iodata_to_binary() |> utf8!()}

  defp normalize_mutation(_), do: raise(ArgumentError, "invalid mutation")

  defp utf8!(value) when is_binary(value) do
    if String.valid?(value), do: value, else: raise(ArgumentError, "invalid UTF-8")
  end
end
