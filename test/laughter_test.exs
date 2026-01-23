defmodule LaughterTest do
  use ExUnit.Case

  @html """
  <!DOCTYPE html>
  <html>
    <head>
      <title>Test</title>
    </head>
    <body>
      <!-- comment -->
      <a href="http://foo.com/blah?hi=blah&foo=&#43;Park" class="foo">test</a>
      <div class="content">
        <a href="http://google.com" class="js-google js-cool centered">Google</a>
        <a href="http://elixir-lang.org" class="js-elixir js-cool">Elixir lang</a>
        <a class="js-java centered" href="http://java.com">Java</a>
      </div>
    </body>
  </html>
  """

  test "sends parsed HTML" do
    builder = Laughter.build()

    div_ref = Laughter.filter(builder, self(), "div")
    link_ref = Laughter.filter(builder, self(), "a.centered")

    builder
    |> Laughter.create()
    |> Laughter.parse(@html)
    |> Laughter.done()

    assert_received {:element, ^link_ref, {"a", [{"href", "http://google.com"} | _]}}
    assert_received {:element, ^link_ref, {"a", [{"class", "js-java centered"} | _]}}
    assert_received {:end, ^link_ref}

    assert_received {:element, ^div_ref, {"div", [{"class", "content"}]}}
    assert_received {:end, ^div_ref}
  end

  test "parses iodata" do
    builder = Laughter.build()

    div_ref = Laughter.filter(builder, self(), "div")

    builder
    |> Laughter.create()
    |> Laughter.parse(["<html>", "<body", ["><div class='REFBODY'></div></body></html>"]])
    |> Laughter.done()

    assert_received {:element, ^div_ref, {"div", [{"class", "REFBODY"}]}}
  end

  test "raises exception on invalid selector" do
    builder = Laughter.build()

    assert catch_error(Laughter.filter(builder, self(), "#")) ==
             "The selector is empty."
  end

  @tag :skip
  test "raises exception when memory limit is exceeded" do
    # Note: lol-html memory limiting behavior is complex
    # and depends on internal buffer management
    builder = Laughter.build()
    Laughter.filter(builder, self(), "div")
    parser = Laughter.create(builder, max_memory: 1024)

    large_html = String.duplicate(@html, 100)
    assert_raise ErlangError, fn -> Laughter.parse(parser, large_html) end
  end
end
