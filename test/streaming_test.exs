defmodule StreamingTest do
  use ExUnit.Case

  describe "streaming parsing" do
    test "parses HTML in chunks" do
      builder = Laughter.build()
      link_ref = Laughter.filter(builder, self(), "a")

      parser = Laughter.create(builder)

      # Send HTML in multiple chunks
      parser
      |> Laughter.parse("<html><body>")
      |> Laughter.parse("<a href='/page1'>")
      |> Laughter.parse("Page 1</a>")
      |> Laughter.parse("<a href='/page2'>Page 2</a>")
      |> Laughter.parse("</body></html>")
      |> Laughter.done()

      assert_received {:element, ^link_ref, {"a", [{"href", "/page1"}]}}
      assert_received {:element, ^link_ref, {"a", [{"href", "/page2"}]}}
    end

    test "handles incomplete tags across chunks" do
      builder = Laughter.build()
      link_ref = Laughter.filter(builder, self(), "a")

      parser = Laughter.create(builder)

      # Split a tag across chunks
      parser
      |> Laughter.parse("<a hre")
      |> Laughter.parse("f='/test'>Link</a>")
      |> Laughter.done()

      assert_received {:element, ^link_ref, {"a", [{"href", "/test"}]}}
    end

    test "handles byte-by-byte streaming" do
      builder = Laughter.build()
      link_ref = Laughter.filter(builder, self(), "a")

      html = "<a href='/x'>X</a>"

      parser =
        html
        |> String.graphemes()
        |> Enum.reduce(Laughter.create(builder), fn char, parser ->
          Laughter.parse(parser, char)
        end)

      Laughter.done(parser)

      assert_received {:element, ^link_ref, {"a", [{"href", "/x"}]}}
    end
  end

  describe "multiple selectors" do
    test "handles multiple selectors on same builder" do
      builder = Laughter.build()

      link_ref = Laughter.filter(builder, self(), "a")
      title_ref = Laughter.filter(builder, self(), "title")
      meta_ref = Laughter.filter(builder, self(), "meta[name='description']")

      html = """
      <html>
        <head>
          <title>Test Page</title>
          <meta name="description" content="A test page">
        </head>
        <body>
          <a href="/link1">Link 1</a>
          <a href="/link2">Link 2</a>
        </body>
      </html>
      """

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      assert_received {:element, ^title_ref, {"title", []}}
      assert_received {:element, ^meta_ref, {"meta", attrs}}
      assert {"name", "description"} in attrs
      assert {"content", "A test page"} in attrs

      assert_received {:element, ^link_ref, {"a", [{"href", "/link1"}]}}
      assert_received {:element, ^link_ref, {"a", [{"href", "/link2"}]}}
    end

    test "handles complex CSS selectors" do
      builder = Laughter.build()

      ref = Laughter.filter(builder, self(), "div.content > a.external[rel='nofollow']")

      html = """
      <div class="content">
        <a href="/internal">Internal</a>
        <a href="http://external.com" class="external" rel="nofollow">External</a>
        <span><a href="/nested" class="external" rel="nofollow">Nested</a></span>
      </div>
      """

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      # Only the direct child with class external and rel=nofollow should match
      assert_received {:element, ^ref, {"a", attrs}}
      assert {"href", "http://external.com"} in attrs

      # The nested one should not match (not direct child)
      refute_received {:element, ^ref, {"a", [{"href", "/nested"} | _]}}
    end
  end

  describe "text content extraction" do
    test "extracts text content with send_content: true" do
      builder = Laughter.build()

      ref = Laughter.filter(builder, self(), "title", true)

      html = "<html><head><title>My Title</title></head></html>"

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      assert_received {:element, ^ref, {"title", []}}
      assert_received {:text, ^ref, "My Title"}
    end

    test "extracts text from multiple elements" do
      builder = Laughter.build()

      ref = Laughter.filter(builder, self(), "p", true)

      html = "<p>First</p><p>Second</p>"

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      assert_received {:element, ^ref, {"p", []}}
      assert_received {:text, ^ref, "First"}
      assert_received {:element, ^ref, {"p", []}}
      assert_received {:text, ^ref, "Second"}
    end
  end

  describe "malformed HTML" do
    test "handles unclosed tags" do
      builder = Laughter.build()
      ref = Laughter.filter(builder, self(), "a")

      html = "<a href='/link'>Link<a href='/other'>Other"

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      assert_received {:element, ^ref, {"a", [{"href", "/link"}]}}
      assert_received {:element, ^ref, {"a", [{"href", "/other"}]}}
    end

    test "handles mismatched tags" do
      builder = Laughter.build()
      ref = Laughter.filter(builder, self(), "div")

      html = "<div><span></div></span>"

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      assert_received {:element, ^ref, {"div", []}}
    end

    test "handles invalid attribute syntax" do
      builder = Laughter.build()
      ref = Laughter.filter(builder, self(), "a")

      html = ~s(<a href=/noquotes class="with quotes">Link</a>)

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      assert_received {:element, ^ref, {"a", attrs}}
      assert {"href", "/noquotes"} in attrs
    end
  end

  describe "encoding" do
    test "handles UTF-8 content" do
      builder = Laughter.build()
      ref = Laughter.filter(builder, self(), "a", true)

      html = "<a href='/кириллица'>Привет мир</a>"

      builder
      |> Laughter.create(encoding: "utf-8")
      |> Laughter.parse(html)
      |> Laughter.done()

      assert_received {:element, ^ref, {"a", [{"href", "/кириллица"}]}}
      assert_received {:text, ^ref, "Привет мир"}
    end
  end

  describe "large documents" do
    test "handles large documents without memory issues" do
      builder = Laughter.build()
      ref = Laughter.filter(builder, self(), "a")

      # Generate HTML with many links
      links =
        1..1000
        |> Enum.map(fn i -> ~s(<a href="/page#{i}">Link #{i}</a>) end)
        |> Enum.join("\n")

      html = "<html><body>#{links}</body></html>"

      builder
      |> Laughter.create()
      |> Laughter.parse(html)
      |> Laughter.done()

      # Count received messages
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

      assert count == 1000
    end
  end
end
