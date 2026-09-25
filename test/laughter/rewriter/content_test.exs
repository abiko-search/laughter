defmodule Laughter.Rewriter.ContentTest do
  use ExUnit.Case, async: true

  alias Laughter.Rewriter

  @html "<b>α & β</b>"
  @text "&lt;b&gt;α &amp; β&lt;/b&gt;"
  @cases [
    prepend_text: "<p>#{@text}old</p>",
    prepend_html: "<p>#{@html}old</p>",
    append_text: "<p>old#{@text}</p>",
    append_html: "<p>old#{@html}</p>",
    before_text: "#{@text}<p>old</p>",
    before_html: "#{@html}<p>old</p>",
    after_text: "<p>old</p>#{@text}",
    after_html: "<p>old</p>#{@html}",
    replace_text: @text,
    replace_html: @html,
    set_inner_text: "<p>#{@text}</p>",
    set_inner_html: "<p>#{@html}</p>"
  ]

  for {operation, expected} <- @cases do
    test "#{operation} accepts iodata and works across arbitrary stream boundaries" do
      plan =
        apply(Rewriter, unquote(operation), [Rewriter.new(), "p", ["<b>", ["α & β"], "</b>"]])

      assert_both(plan, "<p>old</p>", unquote(expected))
    end
  end

  test "all content operations share the public builder and native schema" do
    names = Enum.map(Laughter.Rewriter.Content.operations(), & &1.name)
    assert Enum.sort(names) == Enum.sort(Keyword.keys(@cases))
  end

  test "repeated prepend and after insertions reverse order; append and before preserve it" do
    plan =
      Rewriter.new()
      |> Rewriter.before_text("p", "before1")
      |> Rewriter.before_text("p", "before2")
      |> Rewriter.prepend_text("p", "prepend1")
      |> Rewriter.prepend_text("p", "prepend2")
      |> Rewriter.append_text("p", "append1")
      |> Rewriter.append_text("p", "append2")
      |> Rewriter.after_text("p", "after1")
      |> Rewriter.after_text("p", "after2")

    assert_both(
      plan,
      "<p>old</p>",
      "before1before2<p>prepend2prepend1oldappend1append2</p>after2after1"
    )
  end

  test "the last replacement wins, including overlapping selectors" do
    plan =
      Rewriter.new()
      |> Rewriter.replace_html("p", "<b>first</b>")
      |> Rewriter.replace_text("p.selected", "<last>")

    assert_both(plan, ~s(<p class="selected">old</p>), "&lt;last&gt;")
  end

  test "remove clears a previous replacement and a later replacement supersedes remove" do
    removed = Rewriter.new() |> Rewriter.replace_text("p", "replacement") |> Rewriter.remove("p")
    replaced = Rewriter.new() |> Rewriter.remove("p") |> Rewriter.replace_text("p", "replacement")

    assert_both(removed, "<p>old</p>", "")
    assert_both(replaced, "<p>old</p>", "replacement")
  end

  test "surrounding content survives both removal and replacement" do
    plan =
      Rewriter.new()
      |> Rewriter.before_html("p", "<b>before</b>")
      |> Rewriter.remove("p")
      |> Rewriter.after_text("p", "after")

    assert_both(plan, "<p>old</p>", "<b>before</b>after")
    assert_both(Rewriter.replace_text(plan, "p", "new"), "<p>old</p>", "<b>before</b>newafter")
  end

  test "inner operations cannot resurrect removed or replaced elements" do
    operations = [
      :prepend_text,
      :prepend_html,
      :append_text,
      :append_html,
      :set_inner_text,
      :set_inner_html
    ]

    for operation <- operations do
      removed = Rewriter.remove(Rewriter.new(), "p")
      replaced = Rewriter.replace_text(Rewriter.new(), "p", "replacement")

      assert_both(apply(Rewriter, operation, [removed, "p", "ignored"]), "<p>old</p>", "")

      assert_both(
        apply(Rewriter, operation, [replaced, "p", "ignored"]),
        "<p>old</p>",
        "replacement"
      )

      inner = apply(Rewriter, operation, [Rewriter.new(), "p", "discarded"])
      assert_both(Rewriter.remove(inner, "p"), "<p>old</p>", "")
      assert_both(Rewriter.replace_text(inner, "p", "new"), "<p>old</p>", "new")
    end
  end

  test "setting inner content clears earlier inner insertions; later ones are retained" do
    plan =
      Rewriter.new()
      |> Rewriter.prepend_text("p", "discarded")
      |> Rewriter.append_text("p", "discarded")
      |> Rewriter.set_inner_html("p", "<b>first</b>")
      |> Rewriter.set_inner_text("p", "last")
      |> Rewriter.prepend_text("p", "before")
      |> Rewriter.append_text("p", "after")

    assert_both(plan, "<p><span>old</span></p>", "<p>beforelastafter</p>")
  end

  test "ancestor replacement suppresses original descendant modifications" do
    plan =
      Rewriter.new()
      |> Rewriter.replace_text("div", "new")
      |> Rewriter.before_text("span", "hidden")
      |> Rewriter.after_text("span", "hidden")
      |> Rewriter.replace_text("span", "hidden")

    assert_both(plan, "<div><span>old</span></div>", "new")
  end

  test "inserted HTML is not matched by later rules" do
    plan =
      Rewriter.new()
      |> Rewriter.replace_html("p", "<script>inserted</script>")
      |> Rewriter.remove("script")

    assert_both(plan, "<p>old</p><script>original</script>", "<script>inserted</script>")
  end

  test "void elements ignore inner operations but support surrounding content and replacement" do
    plan =
      Rewriter.new()
      |> Rewriter.prepend_html("img", "ignored")
      |> Rewriter.append_text("img", "ignored")
      |> Rewriter.set_inner_html("img", "ignored")
      |> Rewriter.before_text("img", "before")
      |> Rewriter.after_text("img", "after")

    assert_both(plan, "<img>", "before<img>after")
    assert_both(Rewriter.replace_text(plan, "img", "new"), "<img>", "beforenewafter")
  end

  test "empty replacement and inner content have their documented effects" do
    assert_both(Rewriter.replace_text(Rewriter.new(), "p", []), "<p>old</p>", "")
    assert_both(Rewriter.set_inner_html(Rewriter.new(), "p", ""), "<p>old</p>", "<p></p>")
    assert_both(Rewriter.before_text(Rewriter.new(), "p", ""), "<p>old</p>", "<p>old</p>")
  end

  test "content is UTF-8 even when the document uses a different encoding" do
    plan = Rewriter.new(encoding: "windows-1251") |> Rewriter.set_inner_text("p", "Я")
    assert_both(plan, "<p>old</p>", <<"<p>", 0xDF, "</p>">>)
  end

  test "rejects invalid content without allocating a native session" do
    for operation <- Keyword.keys(@cases) do
      assert_raise ArgumentError, ~r/valid UTF-8/, fn ->
        apply(Rewriter, operation, [Rewriter.new(), "p", <<255>>])
      end

      assert_raise ArgumentError, fn ->
        apply(Rewriter, operation, [Rewriter.new(), "p", [999]])
      end
    end
  end

  test "all content operations respect streaming output limits" do
    for operation <- Keyword.keys(@cases) do
      plan = apply(Rewriter, operation, [Rewriter.new(), "p", String.duplicate("x", 100)])

      error =
        assert_raise Rewriter.Error, fn ->
          ["<p>old</p>"] |> Rewriter.stream(plan, max_output_bytes: 32) |> Stream.run()
        end

      assert error.reason == "rewrite output limit exceeded"
    end
  end

  test "the output limit counts escaped bytes, not unescaped content length" do
    value = String.duplicate("&", 12)
    text = Rewriter.replace_text(Rewriter.new(), "p", value)
    html = Rewriter.replace_html(Rewriter.new(), "p", value)

    assert_raise Rewriter.Error, fn ->
      ["<p>old</p>"] |> Rewriter.stream(text, max_output_bytes: 32) |> Stream.run()
    end

    assert [value] ==
             ["<p>old</p>"] |> Rewriter.stream(html, max_output_bytes: 32) |> Enum.to_list()
  end

  test "limits apply per write, not cumulatively across the document" do
    plan = Rewriter.set_inner_text(Rewriter.new(), "p", String.duplicate("x", 20))
    chunks = List.duplicate("<p>old</p>", 100)
    expected = String.duplicate("<p>#{String.duplicate("x", 20)}</p>", 100)

    output = chunks |> Rewriter.stream(plan, max_output_bytes: 32) |> Enum.to_list()
    assert Enum.all?(output, &(byte_size(&1) <= 32))
    assert IO.iodata_to_binary(output) == expected
  end

  defp assert_both(plan, html, expected) do
    assert {:ok, ^expected} = Rewriter.rewrite(plan, html)

    for split <- 0..byte_size(html) do
      <<head::binary-size(split), tail::binary>> = html
      actual = [head, tail] |> Rewriter.stream(plan, chunk_size: 3) |> Enum.to_list()
      assert IO.iodata_to_binary(actual) == expected
    end
  end
end
