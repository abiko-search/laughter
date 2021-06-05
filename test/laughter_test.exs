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

    div_ref = Laughter.stream_elements(builder, self(), "div")
    link_ref = Laughter.stream_elements(builder, self(), "a.centered")

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

  test "raises exception on invalid selector" do
    builder = Laughter.build()

    assert catch_error(Laughter.stream_elements(builder, self(), "#")) ==
             "The selector is empty."
  end

  test "raises exception when memory limit is exceeded" do
    builder = Laughter.build()
    Laughter.stream_elements(builder, self(), "div")
    parser = Laughter.create(builder, max_memory: 5)

    assert catch_error(Laughter.parse(parser, @html)) == "The memory limit has been exceeded."
  end
end
