defmodule RewriterTest do
  use ExUnit.Case

  alias Laughter.Rewriter

  describe "element rewriting" do
    test "rewrites attribute values" do
      config = Rewriter.new()

      Rewriter.on_element(config, "a[href]", fn _tag, attrs ->
        case List.keyfind(attrs, "href", 0) do
          {"href", href} ->
            new_href = String.replace(href, ".onion", ".example.com")
            [{:set_attribute, "href", new_href}]
          _ ->
            []
        end
      end)

      html = ~s(<html><body><a href="http://abc.onion/page">Link</a></body></html>)
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ ~s(href="http://abc.example.com/page")
      assert output =~ ">Link</a>"
    end

    test "removes attributes" do
      config = Rewriter.new()

      Rewriter.on_element(config, "a", fn _tag, _attrs ->
        [{:remove_attribute, "target"}]
      end)

      html = ~s(<a href="/x" target="_blank">Link</a>)
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ ~s(href="/x")
      refute output =~ "target"
    end

    test "prepends HTML inside element" do
      config = Rewriter.new()

      Rewriter.on_element(config, "body", fn _tag, _attrs ->
        [{:prepend_html, "<div class='banner'>Notice</div>"}]
      end)

      html = "<html><body><p>Content</p></body></html>"
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ "<div class='banner'>Notice</div><p>Content</p>"
    end

    test "replaces entire element" do
      config = Rewriter.new()

      Rewriter.on_element(config, "script", fn _tag, _attrs ->
        [{:replace_html, "<!-- removed -->"}]
      end)

      html = "<html><body><script>alert(1)</script><p>OK</p></body></html>"
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ "<!-- removed -->"
      refute output =~ "alert"
    end

    test "multiple mutations on same element" do
      config = Rewriter.new()

      Rewriter.on_element(config, "a", fn _tag, attrs ->
        mutations = [{:set_attribute, "rel", "nofollow"}]

        case List.keyfind(attrs, "href", 0) do
          {"href", href} ->
            [{:set_attribute, "href", href <> "?proxy=1"} | mutations]
          _ ->
            mutations
        end
      end)

      html = ~s(<a href="/page">Link</a>)
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ ~s(href="/page?proxy=1")
      assert output =~ ~s(rel="nofollow")
    end

    test "multiple selectors" do
      config = Rewriter.new()

      Rewriter.on_element(config, "a[href]", fn _tag, attrs ->
        {"href", href} = List.keyfind(attrs, "href", 0)
        [{:set_attribute, "href", String.replace(href, ".onion", ".proxy")}]
      end)

      Rewriter.on_element(config, "img[src]", fn _tag, attrs ->
        {"src", src} = List.keyfind(attrs, "src", 0)
        [{:set_attribute, "src", String.replace(src, ".onion", ".proxy")}]
      end)

      html = ~s(<a href="http://a.onion/x">Link</a><img src="http://b.onion/img.png">)
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ "a.proxy/x"
      assert output =~ "b.proxy/img.png"
    end

    test "noop handler passes through" do
      config = Rewriter.new()

      Rewriter.on_element(config, "a", fn _tag, _attrs -> [] end)

      html = ~s(<a href="/x">Link</a>)
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ ~s(href="/x")
    end
  end

  describe "text rewriting" do
    test "replaces text content" do
      config = Rewriter.new()

      Rewriter.on_text(config, "p", fn text, _last ->
        replaced = String.replace(text, "secret", "███████")
        [{:replace_text, replaced}]
      end)

      html = "<p>This is a secret message</p>"
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ "███████"
      refute output =~ "secret"
    end

    test "removes text" do
      config = Rewriter.new()

      Rewriter.on_text(config, "span.redacted", fn _text, _last ->
        [:remove]
      end)

      html = ~s(<span class="redacted">hidden text</span>)
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ ~s(<span class="redacted"></span>)
    end

    test "inserts HTML before text" do
      config = Rewriter.new()

      Rewriter.on_text(config, "h1", fn text, _last ->
        if text != "", do: [{:before_html, "<b>→</b>"}], else: []
      end)

      html = "<h1>Title</h1>"
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ "<b>→</b>Title"
    end
  end

  describe "combined element + text" do
    test "rewrites URLs and redacts text simultaneously" do
      config = Rewriter.new()

      Rewriter.on_element(config, "a[href]", fn _tag, attrs ->
        {"href", href} = List.keyfind(attrs, "href", 0)
        [{:set_attribute, "href", String.replace(href, ".onion", ".proxy")}]
      end)

      Rewriter.on_text(config, "body", fn text, _last ->
        replaced = String.replace(text, "banned", "███████")
        [{:replace_text, replaced}]
      end)

      html = ~s(<body>Some banned text <a href="http://x.onion/p">link</a></body>)
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ "███████"
      assert output =~ "x.proxy/p"
      refute output =~ "banned"
      refute output =~ ".onion"
    end
  end

  describe "edge cases" do
    test "empty HTML" do
      config = Rewriter.new()
      {:ok, output} = Rewriter.rewrite(config, "")
      assert output == ""
    end

    test "no handlers" do
      config = Rewriter.new()
      html = "<html><body><p>Hello</p></body></html>"
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output == html
    end

    test "UTF-8 content" do
      config = Rewriter.new()

      Rewriter.on_text(config, "p", fn text, _last ->
        [{:replace_text, String.upcase(text)}]
      end)

      html = "<p>Привет мир</p>"
      {:ok, output} = Rewriter.rewrite(config, html)
      assert output =~ "ПРИВЕТ МИР"
    end

    test "large document" do
      config = Rewriter.new()

      Rewriter.on_element(config, "a[href]", fn _tag, attrs ->
        {"href", href} = List.keyfind(attrs, "href", 0)
        [{:set_attribute, "href", href <> "?rewritten=1"}]
      end)

      links = Enum.map_join(1..500, "\n", fn i -> ~s(<a href="/p#{i}">Link #{i}</a>) end)
      html = "<html><body>#{links}</body></html>"
      {:ok, output} = Rewriter.rewrite(config, html)

      assert output =~ "?rewritten=1"
      assert length(Regex.scan(~r/rewritten=1/, output)) == 500
    end
  end
end
