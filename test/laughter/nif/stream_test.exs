defmodule Laughter.Nif.StreamTest do
  use ExUnit.Case, async: true

  alias Laughter.Nif

  test "finish flushes and closes; close is idempotent" do
    {:ok, session} = new_session()
    assert {:ok, ""} = Nif.rewrite_stream_write(session, "<a")
    assert {:ok, "<a"} = Nif.rewrite_stream_finish(session)
    assert_closed(session)
    assert :ok = Nif.rewrite_stream_close(session)
    assert :ok = Nif.rewrite_stream_close(session)
  end

  test "cancel discards pending bytes without flushing" do
    {:ok, session} = new_session()
    assert {:ok, ""} = Nif.rewrite_stream_write(session, "<a")
    assert :ok = Nif.rewrite_stream_close(session)
    assert_closed(session)
  end

  test "an oversized native input invalidates the session" do
    {:ok, session} = new_session(4, 100)

    assert {:error, "rewrite input chunk limit exceeded"} =
             Nif.rewrite_stream_write(session, "12345")

    assert_closed(session)
  end

  test "output overflow on write invalidates the session" do
    {:ok, session} = new_session(100, 4)
    assert {:error, "rewrite output limit exceeded"} = Nif.rewrite_stream_write(session, "12345")
    assert_closed(session)
  end

  test "output overflow at EOF invalidates the session" do
    {:ok, session} = new_session(4, 4)

    for input <- ["<a ", "href", "='x"] do
      assert {:ok, ""} = Nif.rewrite_stream_write(session, input)
    end

    assert {:error, "rewrite output limit exceeded"} = Nif.rewrite_stream_finish(session)
    assert_closed(session)
  end

  test "parser errors invalidate the session" do
    rules = [%{selector: "p", mutation: {:set_attribute, %{name: "bad name", value: "x"}}}]
    {:ok, session} = Nif.rewrite_stream_new(rules, "utf-8", 1024, 100, 100)
    assert {:error, _} = Nif.rewrite_stream_write(session, "<p>x</p>")
    assert_closed(session)
  end

  test "native boundary rejects zero limits" do
    for {memory, input, output} <- [{0, 100, 100}, {100, 0, 100}, {100, 100, 0}] do
      assert {:error, "rewrite stream limits must be positive"} =
               Nif.rewrite_stream_new([], "utf-8", memory, input, output)
    end
  end

  defp new_session(max_input \\ 100, max_output \\ 100) do
    Nif.rewrite_stream_new(
      [%{selector: "a", mutation: :remove}],
      "utf-8",
      16_384,
      max_input,
      max_output
    )
  end

  defp assert_closed(session) do
    assert {:error, "rewrite session is closed"} = Nif.rewrite_stream_write(session, "x")
    assert {:error, "rewrite session is closed"} = Nif.rewrite_stream_finish(session)
  end
end
