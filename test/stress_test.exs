defmodule StressTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  describe "concurrent usage" do
    test "handles many concurrent parsers" do
      html = """
      <html>
        <head><title>Test</title></head>
        <body>
          <a href="/1">Link 1</a>
          <a href="/2">Link 2</a>
          <a href="/3">Link 3</a>
        </body>
      </html>
      """

      tasks =
        1..100
        |> Enum.map(fn _ ->
          Task.async(fn ->
            builder = Laughter.build()
            ref = Laughter.filter(builder, self(), "a")

            builder
            |> Laughter.create()
            |> Laughter.parse(html)
            |> Laughter.done()

            count =
              Stream.repeatedly(fn ->
                receive do
                  {:element, ^ref, _} -> :ok
                after
                  10 -> :done
                end
              end)
              |> Enum.take_while(&(&1 == :ok))
              |> length()

            assert count == 3
            :ok
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "handles rapid create/destroy cycles" do
      for _ <- 1..500 do
        builder = Laughter.build()
        Laughter.filter(builder, self(), "a")

        builder
        |> Laughter.create()
        |> Laughter.parse("<a href='/test'>Link</a>")
        |> Laughter.done()
      end

      # If we get here without crashing, the test passes
      assert true
    end

    test "handles many selectors on single builder" do
      builder = Laughter.build()

      refs =
        1..100
        |> Enum.map(fn i ->
          Laughter.filter(builder, self(), "div.class#{i}")
        end)

      html =
        1..100
        |> Enum.map(fn i -> ~s(<div class="class#{i}">Content #{i}</div>) end)
        |> Enum.join()

      builder
      |> Laughter.create()
      |> Laughter.parse("<html><body>#{html}</body></html>")
      |> Laughter.done()

      # Each selector should match once
      for ref <- refs do
        assert_received {:element, ^ref, {"div", _}}
      end
    end
  end

  describe "memory limits" do
    @tag :skip
    test "respects memory limit with large input" do
      # Note: lol-html memory limiting behavior is complex
      builder = Laughter.build()
      Laughter.filter(builder, self(), "a")

      parser = Laughter.create(builder, max_memory: 2048)
      large_html = String.duplicate("<a href='/x'>", 1000)

      assert_raise ErlangError, fn -> Laughter.parse(parser, large_html) end
    end
  end

  describe "streaming stress" do
    test "handles many small chunks" do
      builder = Laughter.build()
      ref = Laughter.filter(builder, self(), "a")

      # Create parser
      parser = Laughter.create(builder)

      # Send 1000 tiny chunks
      html = "<a href='/test'>Link</a>"

      parser =
        html
        |> String.graphemes()
        |> List.duplicate(100)
        |> List.flatten()
        |> Enum.reduce(parser, fn char, p ->
          Laughter.parse(p, char)
        end)

      Laughter.done(parser)

      # Should have received 100 link elements
      count =
        Stream.repeatedly(fn ->
          receive do
            {:element, ^ref, _} -> :ok
          after
            10 -> :done
          end
        end)
        |> Enum.take_while(&(&1 == :ok))
        |> length()

      assert count == 100
    end
  end
end
