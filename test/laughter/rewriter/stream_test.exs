defmodule Laughter.Rewriter.StreamTest do
  use ExUnit.Case, async: true

  alias Laughter.Rewriter
  alias Laughter.Rewriter.Error

  test "matches whole-document rewriting at every split point, including UTF-8 bytes" do
    plan =
      Rewriter.new()
      |> Rewriter.remove("script")
      |> Rewriter.set_attribute("a[href]", "title", ~s|Привет "мир"|)
      |> Rewriter.remove_attribute("img", "onclick")

    html =
      ~s|<!doctype html><p>α &amp; β<a href="/">link</a><script>bad()</script><img onclick="x"><p>fin|

    assert {:ok, expected} = Rewriter.rewrite(plan, html)

    for offset <- 0..byte_size(html) do
      <<head::binary-size(offset), tail::binary>> = html
      assert collect([head, tail], plan, chunk_size: 7) == expected
    end

    bytes =
      for <<byte <- html>> do
        <<byte>>
      end

    assert collect(bytes, plan) == expected
  end

  test "flushes an incomplete token at EOF" do
    plan = Rewriter.set_attribute(Rewriter.new(), "a", "rel", "nofollow")
    assert collect(["<a", " href='unfinished"], plan) == "<a href='unfinished"
  end

  test "ignores empty input chunks and emits only nonempty binaries" do
    plan = Rewriter.remove(Rewriter.new(), "script")
    assert [] == Enum.to_list(Rewriter.stream([], plan))

    assert [] ==
             Enum.to_list(Rewriter.stream(["", [], [""], "<script>x</script>"], plan))

    chunks = Enum.to_list(Rewriter.stream(["", ["<p>", ["x"]], "</p>"], plan))
    assert Enum.all?(chunks, &(is_binary(&1) and byte_size(&1) > 0))
    assert IO.iodata_to_binary(chunks) == "<p>x</p>"
  end

  test "is lazy and supports a fresh session on every enumeration" do
    owner = self()

    source =
      Stream.map(["<p>x</p>"], fn chunk ->
        send(owner, :pulled)
        chunk
      end)

    stream = Rewriter.stream(source, Rewriter.new())
    refute_received :pulled

    for _ <- 1..2 do
      assert Enum.to_list(stream) == ["<p>x</p>"]
      assert_received :pulled
    end
  end

  test "splits large upstream chunks before native writes" do
    html = String.duplicate("x", 10_000)

    chunks =
      Rewriter.stream([html], Rewriter.new(),
        chunk_size: 16,
        max_output_bytes: 32
      )

    output = Enum.to_list(chunks)
    assert Enum.all?(output, &(byte_size(&1) <= 32))
    assert IO.iodata_to_binary(output) == html
  end

  test "does not pull another upstream chunk before the consumer requests it" do
    owner = self()

    source =
      Stream.map(1..10, fn i ->
        send(owner, {:pulled, i})
        "hello"
      end)

    assert ["hello"] = Enum.take(Rewriter.stream(source, Rewriter.new()), 1)
    assert_received {:pulled, 1}
    refute_received {:pulled, 2}
  end

  test "does not process the rest of a large source chunk after early halt" do
    plan = Rewriter.set_attribute(Rewriter.new(), "p", "bad name", "x")
    assert ["ok"] = Enum.take(Rewriter.stream(["ok<p>x</p>"], plan, chunk_size: 2), 1)
  end

  test "can enumerate the same declarative stream concurrently in different processes" do
    plan = Rewriter.remove(Rewriter.new(), "script")
    stream = Rewriter.stream(["<scr", "ipt>x</script><p>ok</p>"], plan)

    results =
      1..8
      |> Task.async_stream(fn _ -> stream |> Enum.to_list() |> IO.iodata_to_binary() end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, "<p>ok</p>"}))
  end

  test "preserves non-UTF-8 encoding across chunks and enumerations" do
    plan = Rewriter.remove(Rewriter.new(encoding: "windows-1251"), "script")
    html = <<"<p>", 0xCF, 0xF0, "</p>">>

    bytes =
      for <<byte <- html>> do
        <<byte>>
      end

    assert collect(bytes, plan) == html
    assert collect(bytes, plan) == html
  end

  test "native initialization errors are lazy and do not consume input" do
    owner = self()

    input =
      Stream.map(["html"], fn chunk ->
        send(owner, :pulled)
        chunk
      end)

    for plan <- [
          Rewriter.new(encoding: "invalid-charset"),
          Rewriter.remove(Rewriter.new(), "[")
        ] do
      stream = Rewriter.stream(input, plan)
      assert_raise Error, fn -> Enum.to_list(stream) end
      refute_received :pulled
    end
  end

  test "fails on bounded output expansion instead of accumulating it" do
    plan = Rewriter.new() |> Rewriter.set_attribute("p", "title", String.duplicate("x", 100))

    error =
      assert_raise Error, fn ->
        collect(["<p>x</p>"], plan, max_output_bytes: 32)
      end

    assert error.reason == "rewrite output limit exceeded"
  end

  test "reports parser memory failures during enumeration" do
    plan = Rewriter.remove(Rewriter.new(max_memory: 1), "div p")
    assert_raise Error, fn -> collect(["<div><p>x</p></div>"], plan) end
  end

  test "validates stream options" do
    for opts <- [
          [unknown: true],
          [chunk_size: 0],
          [chunk_size: -1],
          [max_output_bytes: 0],
          [max_output_bytes: 1.5]
        ] do
      assert_raise ArgumentError, fn ->
        Rewriter.stream([], Rewriter.new(), opts)
      end
    end
  end

  test "does not support legacy callbacks" do
    plan = Rewriter.new()
    Rewriter.on_element(plan, "p", fn _, _ -> [] end)
    assert_raise ArgumentError, ~r"legacy callbacks", fn -> Rewriter.stream([], plan) end
  end

  defp collect(chunks, plan, opts \\ []) do
    chunks |> Rewriter.stream(plan, opts) |> Enum.to_list() |> IO.iodata_to_binary()
  end
end
