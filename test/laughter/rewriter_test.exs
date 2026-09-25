defmodule Laughter.RewriterTest do
  use ExUnit.Case, async: true

  alias Laughter.Rewriter

  test "combines all three operations in one plan and returns a binary" do
    plan =
      Rewriter.new()
      |> Rewriter.remove("script")
      |> Rewriter.set_attribute("a[href]", "rel", "nofollow")
      |> Rewriter.remove_attribute("img", "onclick")

    html = ~s|<script>alert(1)</script><a href="/">link</a><img onclick="bad()" src="x">|

    assert {:ok, output} = Rewriter.rewrite(plan, html)
    assert is_binary(output)
    assert output == ~s(<a href="/" rel="nofollow">link</a><img src="x">)
  end

  test "builders are immutable and plans are reusable" do
    base = Rewriter.new()
    remove = Rewriter.remove(base, "p")
    set = Rewriter.set_attribute(base, "p", "id", "new")

    for _ <- 1..2 do
      assert {:ok, "<p>hello</p>"} = Rewriter.rewrite(base, "<p>hello</p>")
      assert {:ok, ""} = Rewriter.rewrite(remove, "<p>hello</p>")
      assert {:ok, ~s(<p id="new">hello</p>)} = Rewriter.rewrite(set, "<p>hello</p>")
    end
  end

  test "one plan can execute concurrently in other processes" do
    plan = Rewriter.new() |> Rewriter.remove("script")

    results =
      1..12
      |> Task.async_stream(fn _ -> Rewriter.rewrite(plan, "<script>x</script><p>ok</p>") end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {:ok, "<p>ok</p>"}}))
  end

  test "matching rules execute in registration order" do
    plan =
      Rewriter.new()
      |> Rewriter.set_attribute("a", "rel", "first")
      |> Rewriter.set_attribute("a[href]", "rel", "last")

    assert {:ok, ~s(<a href="/" rel="last">x</a>)} =
             Rewriter.rewrite(plan, ~s(<a href="/">x</a>))

    assert {:ok, ~s(<a href="/">x</a>)} =
             plan
             |> Rewriter.remove_attribute("a", "rel")
             |> Rewriter.rewrite(~s(<a href="/">x</a>))
  end

  test "selectors match original attributes rather than earlier mutations" do
    plan =
      Rewriter.new()
      |> Rewriter.set_attribute("a", "class", "new")
      |> Rewriter.remove("a.new")

    assert {:ok, ~s(<a class="new">x</a>)} = Rewriter.rewrite(plan, "<a>x</a>")
  end

  test "removal wins over attribute changes and includes descendants" do
    plan =
      Rewriter.new()
      |> Rewriter.remove("div")
      |> Rewriter.set_attribute("div", "id", "gone")
      |> Rewriter.set_attribute("span", "id", "also-gone")

    assert {:ok, "<p>keep</p>"} =
             Rewriter.rewrite(plan, "<div><span>gone</span></div><p>keep</p>")
  end

  test "handles UTF-8, iodata, and attribute quote escaping" do
    plan = Rewriter.new() |> Rewriter.set_attribute("p", "title", ~s(Привет "мир"))

    assert {:ok, ~s(<p title="Привет &quot;мир&quot;">текст</p>)} =
             Rewriter.rewrite(plan, ["<p>", ["текст"], "</p>"])
  end

  test "handles empty documents, absent attributes, and malformed HTML" do
    plan = Rewriter.new() |> Rewriter.remove_attribute("p", "absent")
    assert {:ok, ""} = Rewriter.rewrite(plan, "")
    assert {:ok, "<p>one<p>two"} = Rewriter.rewrite(plan, "<p>one<p>two")
  end

  test "invalid selectors return errors rather than panicking" do
    for selector <- ["", " ", "[", "#", ".", "a >"] do
      assert {:error, reason} =
               Rewriter.new() |> Rewriter.remove(selector) |> Rewriter.rewrite("<p>x</p>")

      assert is_binary(reason)
    end
  end

  test "invalid attribute names propagate errors" do
    plan = Rewriter.new() |> Rewriter.set_attribute("p", "bad name", "x")
    assert {:error, reason} = Rewriter.rewrite(plan, "<p>x</p>")
    assert is_binary(reason)
  end

  test "rejects unknown encodings rather than silently falling back" do
    assert {:error, "unsupported encoding: unknown-charset"} =
             Rewriter.new(encoding: "unknown-charset") |> Rewriter.rewrite("<p>x</p>")
  end

  test "can reuse a non-UTF-8 plan without consuming its encoding" do
    plan = Rewriter.new(encoding: "windows-1251") |> Rewriter.remove("script")
    html = <<"<p>", 0xCF, 0xF0, "</p>">>

    assert {:ok, ^html} = Rewriter.rewrite(plan, html)
    assert {:ok, ^html} = Rewriter.rewrite(plan, html)
  end

  test "validates builder options" do
    for opts <- [[unknown: true], [max_memory: 0], [max_memory: -1], [encoding: :utf8]] do
      assert_raise ArgumentError, fn -> Rewriter.new(opts) end
    end
  end

  test "reports parser memory-limit failures" do
    plan = Rewriter.new(max_memory: 1) |> Rewriter.remove("div p")
    assert {:error, reason} = Rewriter.rewrite(plan, "<div><p>text</p></div>")
    assert is_binary(reason)
  end

  test "explicitly rejects mixing callback registrations and native rules" do
    plan = Rewriter.new()
    Rewriter.on_element(plan, "p", fn _, _ -> [] end)

    assert {:error, :mixed_rewrite_modes} =
             plan |> Rewriter.remove("script") |> Rewriter.rewrite("<p>x</p>")
  end
end
