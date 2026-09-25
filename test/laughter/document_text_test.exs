defmodule Laughter.DocumentTextTest do
  use ExUnit.Case

  defp texts(html, opts \\ []) do
    builder = Laughter.build()
    ref = Laughter.document_text(builder, self(), opts)

    builder
    |> Laughter.create()
    |> Laughter.parse(html)
    |> Laughter.done()

    collect(ref, [])
  end

  defp collect(ref, acc) do
    receive do
      {:text, ^ref, t} -> collect(ref, [t | acc])
      {:end, ^ref} -> Enum.reverse(acc)
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "delivers text once even when elements nest" do
    assert texts("<div><p>one</p><p>two</p></div>") == ["one", "two"]
  end

  test "works without a body tag" do
    assert texts("<html><title>T</title>hello <b>world</b>") == ["T", "hello ", "world"]
  end

  test "skips script and style unless raw_text" do
    html = "<script>x()</script><style>a{}</style><p>seen</p>"
    assert texts(html) == ["seen"]
    assert texts(html, raw_text: true) == ["x()", "a{}", "seen"]
  end
end
