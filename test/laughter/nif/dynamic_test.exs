defmodule Laughter.Nif.DynamicTest do
  use ExUnit.Case, async: true

  alias Laughter.Nif

  test "closing the handle wakes a worker blocked waiting for a reply" do
    token = make_ref()
    {:ok, handle} = Nif.rewrite_dynamic_new([], "p", options(), self(), token)
    assert :ok = Nif.rewrite_dynamic_write(handle, 1, "<p>x</p>")
    assert_receive {:laughter_native, ^token, {:element, 1, "p", []}}, 1_000
    assert :ok = Nif.rewrite_dynamic_close(handle)
    assert :ok = Nif.rewrite_dynamic_close(handle)
    assert_receive {:laughter_native, ^token, {:error, "session cancelled"}}, 1_000
    assert {:error, "session closed"} = Nif.rewrite_dynamic_write(handle, 2, "x")
  end

  test "native response correlation rejects an incorrect request id" do
    token = make_ref()
    {:ok, handle} = Nif.rewrite_dynamic_new([], "p", options(), self(), token)
    :ok = Nif.rewrite_dynamic_write(handle, 1, "<p>x</p>")
    assert_receive {:laughter_native, ^token, {:element, 1, "p", []}}, 1_000
    :ok = Nif.rewrite_dynamic_reply(handle, 999, [])
    assert_receive {:laughter_native, ^token, {:error, "unexpected native reply"}}, 1_000
    :ok = Nif.rewrite_dynamic_close(handle)
  end

  test "native watchdog times out even without an OTP coordinator" do
    token = make_ref()

    {:ok, handle} =
      Nif.rewrite_dynamic_new([], "p", %{options() | reply_timeout: 50}, self(), token)

    :ok = Nif.rewrite_dynamic_write(handle, 1, "<p>x</p>")
    assert_receive {:laughter_native, ^token, {:element, 1, "p", []}}, 1_000
    assert_receive {:laughter_native, ^token, {:error, "reply timeout"}}, 1_000
    :ok = Nif.rewrite_dynamic_close(handle)
  end

  test "generated event codecs preserve correlation, attributes, raw binary output, and EOF" do
    token = make_ref()

    {:ok, handle} =
      Nif.rewrite_dynamic_new([], "p", %{options() | encoding: "windows-1251"}, self(), token)

    html = <<"<p title='", 0xCF, 0xF0, "'>", 0xCF, 0xF0, "</p>">>

    assert :ok = Nif.rewrite_dynamic_write(handle, 77, html)
    assert_receive {:laughter_native, ^token, {:element, 1, "p", [{"title", "Пр"}]}}, 1_000
    assert :ok = Nif.rewrite_dynamic_reply(handle, 1, [])
    assert_receive {:laughter_native, ^token, {:output, 77, ^html, false}}, 1_000

    assert :ok = Nif.rewrite_dynamic_finish(handle, 78)
    assert_receive {:laughter_native, ^token, {:output, 78, "", true}}, 1_000
    assert :ok = Nif.rewrite_dynamic_close(handle)
  end

  defp options do
    %{
      encoding: "utf-8",
      max_memory: 16_384,
      chunk_size: 1024,
      max_output_bytes: 1024,
      reply_timeout: 5_000
    }
  end
end
