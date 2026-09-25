defmodule Laughter.Rewriter.LifecycleTest do
  # Counters are VM-global; run after async tests and wait for native destruction.
  use ExUnit.Case, async: false
  alias Laughter.{Nif, Rewriter}

  setup do
    quiescent!()
    :ok
  end

  test "forced termination releases both idle workers and workers awaiting replies" do
    for waiting <- [false, true], _ <- 1..20 do
      session = session()
      monitor = Process.monitor(session)
      if waiting, do: request(session)
      assert {1, 1, capacity} = Nif.rewrite_stats()
      assert capacity >= 8_192
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^session, :killed}, 1_000
      quiescent!()
    end
  end

  test "owner death while parsing releases the native worker without retaining its handle" do
    parent = self()

    for _ <- 1..20 do
      {owner, owner_monitor} =
        spawn_monitor(fn ->
          {:ok, session} =
            Rewriter.start_link(Rewriter.new(), selector: "p", reply_timeout: 30_000)

          Process.unlink(session)
          :ok = Rewriter.demand(session)
          {:ok, _} = Rewriter.write(session, "<p>x</p>")

          receive do
            {:laughter, ^session, _, {:element, _, _}} -> send(parent, {:waiting, session})
          end

          receive do: (:stop -> :ok)
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      assert_receive {:waiting, session}, 1_000
      monitor = Process.monitor(session)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
      quiescent!()
    end
  end

  test "queued reply/cancel races discard output and emit only one terminal event" do
    for cancel_first <- [true, false], _ <- 1..15 do
      session = session()
      monitor = Process.monitor(session)
      ref = request(session)
      :ok = :sys.suspend(session)
      cancel = if cancel_first, do: queued_call(session, :cancel)
      reply = queued_call(session, {:reply, ref, []})
      cancel = cancel || queued_call(session, :cancel)
      :ok = :sys.resume(session)
      unless cancel_first, do: assert_receive({^reply, :ok}, 1_000)
      assert_receive {^cancel, :ok}, 1_000
      assert_receive {:laughter, ^session, {:error, :cancelled}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
      if cancel_first, do: refute_received({^reply, _})
      refute_received {:laughter, ^session, _}
      refute_received {:laughter, ^session, _, _}
      quiescent!()
    end
  end

  test "both delivered-timeout/reply orderings are safe, including stale timer delivery" do
    for timeout_first <- [true, false], _ <- 1..20 do
      session = session()
      monitor = Process.monitor(session)
      ref = request(session)
      :ok = :sys.suspend(session)
      if timeout_first, do: send(session, {:reply_timeout, ref})
      reply = queued_call(session, {:reply, ref, []})
      unless timeout_first, do: send(session, {:reply_timeout, ref})
      :ok = :sys.resume(session)

      if timeout_first do
        assert_receive {:laughter, ^session, {:error, :reply_timeout}}, 1_000
        assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
        refute_received {^reply, _}
      else
        assert_receive {^reply, :ok}, 1_000
        assert_receive {:laughter, ^session, {:output, _, "<p>x</p>"}}, 1_000
        assert :ok = Rewriter.cancel(session)
        assert_receive {:laughter, ^session, {:error, :cancelled}}, 1_000
        assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
      end

      refute_received {:laughter, ^session, _}
      quiescent!()
    end
  end

  test "a cancelled timer from the previous request cannot expire a later request" do
    session = session()
    monitor = Process.monitor(session)
    :ok = Rewriter.demand(session)
    {:ok, chunk} = Rewriter.write(session, "<p>1</p><p>2</p>")
    assert_receive {:laughter, ^session, first, {:element, _, _}}, 1_000
    :ok = Rewriter.reply(session, first, [])
    assert_receive {:laughter, ^session, second, {:element, _, _}}, 1_000
    assert first != second
    send(session, {:reply_timeout, first})
    assert :ok = Rewriter.reply(session, second, [])
    assert_receive {:laughter, ^session, {:output, ^chunk, "<p>1</p><p>2</p>"}}, 1_000
    assert :ok = Rewriter.cancel(session)
    assert_receive {:laughter, ^session, {:error, :cancelled}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
    quiescent!()
  end

  test "real native watchdog races with replies without stranding a worker" do
    for delay <- [0, 1, 5], _ <- 1..20 do
      session = session(reply_timeout: 2)
      monitor = Process.monitor(session)
      ref = request(session)
      Process.sleep(delay)
      result = safely(fn -> Rewriter.reply(session, ref, []) end)
      assert result == :ok or match?({:error, _}, result) or result == :exited
      safely(fn -> Rewriter.cancel(session) end)
      events = until_down(session, monitor, [])
      assert Enum.count(events, &match?({:error, _}, &1)) == 1
      assert match?({:error, _}, List.last(events))
      quiescent!()
    end
  end

  test "EOF, cancellation, startup failure, and overflow return native allocations to zero" do
    for _ <- 1..50 do
      session = session()
      monitor = Process.monitor(session)
      :ok = Rewriter.demand(session)
      {:ok, ref} = Rewriter.finish(session)
      assert_receive {:laughter, ^session, {:output, ^ref, ""}}, 1_000
      assert_receive {:laughter, ^session, :done}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000

      # Keep these resource terms alive: terminal operations must release buffers
      # immediately rather than relying on garbage collection of the handle.
      {:ok, stream} = Nif.rewrite_stream_new([], "utf-8", 1_048_576, 16, 32)

      assert {:error, "rewrite input chunk limit exceeded"} =
               Nif.rewrite_stream_write(stream, String.duplicate("x", 17))

      assert {:error, _} = Nif.rewrite_stream_new([], "invalid", 1_048_576, 16, 32)

      options = %{
        encoding: "invalid",
        max_memory: 1_048_576,
        chunk_size: 16,
        max_output_bytes: 32,
        reply_timeout: 30_000
      }

      assert {:error, _} = Nif.rewrite_dynamic_new([], "p", options, self(), make_ref())
      {:ok, overflow} = Nif.rewrite_stream_new([], "utf-8", 1_048_576, 16, 1)
      assert {:error, "rewrite output limit exceeded"} = Nif.rewrite_stream_write(overflow, "xx")
      quiescent!()
      assert :ok = Nif.rewrite_stream_close(stream)
      assert :ok = Nif.rewrite_stream_close(overflow)
    end
  end

  test "resource destruction closes an abandoned synchronous stream" do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, handle} = Nif.rewrite_stream_new([], "utf-8", 1_048_576, 16, 8_192)
        send(parent, :allocated)
        receive do: (:use -> Nif.rewrite_stream_write(handle, "x"))
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :allocated, 1_000
    assert {0, 1, capacity} = Nif.rewrite_stats()
    assert capacity >= 8_192
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
    quiescent!()
  end

  defp session(opts \\ []) do
    opts = Keyword.merge([selector: "p", reply_timeout: 30_000, max_output_bytes: 8_192], opts)
    {:ok, session} = Rewriter.start_link(Rewriter.new(), opts)
    Process.unlink(session)
    on_exit(fn -> Process.exit(session, :kill) end)
    session
  end

  defp request(session) do
    :ok = Rewriter.demand(session)
    {:ok, _} = Rewriter.write(session, "<p>x</p>")
    assert_receive {:laughter, ^session, ref, {:element, "p", []}}, 1_000
    ref
  end

  # Queue real GenServer protocol calls from the authorized owner while suspended.
  # This deterministically covers orderings without timing-dependent sleeps.
  defp queued_call(session, command) do
    ref = make_ref()
    send(session, {:"$gen_call", {self(), ref}, command})
    ref
  end

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> :exited
  end

  defp until_down(session, monitor, events) do
    receive do
      {:laughter, ^session, event} -> until_down(session, monitor, [event | events])
      {:DOWN, ^monitor, :process, ^session, :normal} -> Enum.reverse(events)
    after
      1_000 -> flunk("session did not stop")
    end
  end

  defp quiescent!(attempts \\ 400) do
    case Nif.rewrite_stats() do
      {0, 0, 0} ->
        :ok

      stats when attempts == 0 ->
        flunk("native resources did not drain: #{inspect(stats)}")

      _ ->
        Process.sleep(5)
        quiescent!(attempts - 1)
    end
  end
end
