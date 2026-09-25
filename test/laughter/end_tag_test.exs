defmodule Laughter.EndTagTest do
  use ExUnit.Case

  defp run(html, selector, opts) do
    builder = Laughter.build()
    ref = Laughter.filter(builder, self(), selector, opts)

    builder
    |> Laughter.create()
    |> Laughter.parse(html)
    |> Laughter.done()

    ref
  end

  defp drain(ref, acc \\ []) do
    receive do
      {:element, ^ref, {tag, _}} -> drain(ref, [{:element, tag} | acc])
      {:text, ^ref, text} -> drain(ref, [{:text, text} | acc])
      {:end_tag, ^ref, tag} -> drain(ref, [{:end_tag, tag} | acc])
      {:end, ^ref} -> Enum.reverse(acc)
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "end_tag: true reports explicit end tags in document order" do
    ref = run("<div><p>one</p><p>two</p></div>", "p", text: true, end_tag: true)

    assert drain(ref) == [
             {:element, "p"},
             {:text, "one"},
             {:end_tag, "p"},
             {:element, "p"},
             {:text, "two"},
             {:end_tag, "p"}
           ]
  end

  test "implicitly closed elements produce no end tag" do
    ref = run("<p>one<p>two</p>", "p", end_tag: true)
    assert drain(ref) == [{:element, "p"}, {:element, "p"}, {:end_tag, "p"}]
  end

  test "the legacy boolean still means text" do
    ref = run("<p>hi</p>", "p", true)
    assert drain(ref) == [{:element, "p"}, {:text, "hi"}]
  end

  test "script and style contents are skipped by default" do
    html = "<body><script>var x = 1;</script><style>.a{}</style><p>seen</p></body>"
    ref = run(html, "body", text: true)
    texts = for {:text, t} <- drain(ref), do: t
    assert texts == ["seen"]
  end

  test "raw_text: true delivers script contents" do
    html = "<body><script>var x = 1;</script><p>seen</p></body>"
    ref = run(html, "body", text: true, raw_text: true)
    texts = for {:text, t} <- drain(ref), do: t
    assert texts == ["var x = 1;", "seen"]
  end

  test "title text is still delivered" do
    ref = run("<html><head><title>T</title></head></html>", "title", text: true)
    assert drain(ref) == [{:element, "title"}, {:text, "T"}]
  end
end
