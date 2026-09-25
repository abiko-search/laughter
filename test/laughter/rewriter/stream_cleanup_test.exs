defmodule Laughter.Rewriter.StreamCleanupTest do
  # Call tracing is used only to observe the real close NIF, without mocks or a
  # test-only hook in the production stream. The trace pattern is VM-global.
  use ExUnit.Case, async: false

  alias Laughter.{Nif, Rewriter}

  test "closes native state and upstream resources on early halt" do
    owner = self()

    source =
      Stream.resource(
        fn -> 0 end,
        fn i -> {["hello"], i + 1} end,
        fn _ -> send(owner, :source_closed) end
      )

    assert_closes(fn ->
      assert ["hello"] = source |> Rewriter.stream(Rewriter.new()) |> Enum.take(1)
      assert_received :source_closed
    end)
  end

  test "closes on normal exhaustion" do
    assert_closes(fn ->
      assert ["hello"] = ["hello"] |> Rewriter.stream(Rewriter.new()) |> Enum.to_list()
    end)
  end

  test "closes when the source raises" do
    source =
      Stream.map(["hello", :fail], fn
        :fail -> raise "source failed"
        chunk -> chunk
      end)

    assert_closes(fn ->
      assert_raise RuntimeError, "source failed", fn ->
        source |> Rewriter.stream(Rewriter.new()) |> Stream.run()
      end
    end)
  end

  test "closes when converting invalid source iodata" do
    assert_closes(fn ->
      assert_raise ArgumentError, fn ->
        [[999]] |> Rewriter.stream(Rewriter.new()) |> Stream.run()
      end
    end)
  end

  test "closes when the consumer raises" do
    assert_closes(fn ->
      assert_raise RuntimeError, "consumer failed", fn ->
        ["hello"]
        |> Rewriter.stream(Rewriter.new())
        |> Enum.each(fn _ -> raise "consumer failed" end)
      end
    end)
  end

  test "closes when the consumer throws" do
    assert_closes(fn ->
      assert catch_throw(
               ["hello"]
               |> Rewriter.stream(Rewriter.new())
               |> Enum.each(fn _ -> throw(:stop) end)
             ) == :stop
    end)
  end

  test "closes after a native failure" do
    assert_closes(fn ->
      assert_raise Rewriter.Error, fn ->
        ["hello"] |> Rewriter.stream(Rewriter.new(), max_output_bytes: 1) |> Stream.run()
      end
    end)
  end

  defp assert_closes(fun) do
    owner = self()
    tracer = spawn_link(fn -> forward_trace(owner) end)
    mfa = {Nif, :rewrite_stream_close, 1}
    :erlang.trace_pattern(mfa, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
      assert_receive {:native_close, session}, 1_000
      assert {:error, "rewrite session is closed"} = Nif.rewrite_stream_write(session, "x")
      refute_received {:native_close, _}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern(mfa, false, [])
      send(tracer, :stop)
    end
  end

  defp forward_trace(owner) do
    receive do
      {:trace, _, :call, {Nif, :rewrite_stream_close, [session]}} ->
        send(owner, {:native_close, session})
        forward_trace(owner)

      :stop ->
        :ok
    end
  end
end
