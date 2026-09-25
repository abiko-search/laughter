ExUnit.start()

defmodule Laughter.PackageConsumer.SmokeTest do
  use ExUnit.Case, async: true

  alias Laughter.Rewriter

  test "the consumer has no RustQ dependency or runtime application" do
    refute Code.ensure_loaded?(RustQ)
    refute File.dir?("deps/rustq")
    refute :rustq in Application.spec(:laughter, :applications)
    refute :rustler in Application.spec(:laughter, :applications)
    assert {:ok, _} = Version.parse(to_string(Application.spec(:laughter, :vsn)))
  end

  test "native plans and lazy streams work from the extracted archive" do
    plan = Rewriter.new() |> Rewriter.remove("script") |> Rewriter.append_text("p", "&")
    html = "<script>x</script><p>α</p>"
    expected = "<p>α&amp;</p>"
    assert {:ok, ^expected} = Rewriter.rewrite(plan, html)

    assert [html]
           |> Rewriter.stream(plan, chunk_size: 1)
           |> Enum.to_list()
           |> IO.iodata_to_binary() == expected
  end

  test "the original callback sequence remains supported" do
    plan = Rewriter.new()
    Rewriter.on_element(plan, "p", fn _, _ -> [{:set_attribute, "id", "ok"}] end)

    Rewriter.on_text(plan, "p", fn text, _ ->
      [{:replace_text, String.replace(text, "old", "new")}]
    end)

    assert {:ok, ~s(<p id="ok">new</p>)} = Rewriter.rewrite(plan, "<p>old</p>")
  end

  test "raw_text opts into the previous parser text behavior" do
    for {opts, expected} <- [{true, ""}, {[text: true, raw_text: true], "code"}] do
      builder = Laughter.build()
      ref = Laughter.filter(builder, self(), "script", opts)
      builder |> Laughter.create() |> Laughter.parse("<script>code</script>") |> Laughter.done()
      assert_receive {:element, ^ref, {"script", []}}
      assert text(ref) == expected
    end
  end

  test "document text and explicit end tags are available" do
    builder = Laughter.build()
    ref = Laughter.document_text(builder, self())
    tag = Laughter.filter(builder, self(), "p", end_tag: true)
    builder |> Laughter.create() |> Laughter.parse("<p>text</p>") |> Laughter.done()
    assert text(ref) == "text"
    assert_receive {:element, ^tag, {"p", []}}
    assert_receive {:end_tag, ^tag, "p"}
    assert_receive {:end, ^tag}
  end

  test "message-driven sessions rewrite and shut down normally" do
    {:ok, session} = Rewriter.start_link(Rewriter.new(), selector: "p")
    monitor = Process.monitor(session)
    :ok = Rewriter.demand(session)
    {:ok, chunk} = Rewriter.write(session, "<p>old</p>")
    assert_receive {:laughter, ^session, ref, {:element, "p", []}}, 1_000
    :ok = Rewriter.reply(session, ref, [{:set_inner_text, "new"}])
    assert_receive {:laughter, ^session, {:output, ^chunk, "<p>new</p>"}}, 1_000
    :ok = Rewriter.demand(session)
    {:ok, eof} = Rewriter.finish(session)
    assert_receive {:laughter, ^session, {:output, ^eof, ""}}, 1_000
    assert_receive {:laughter, ^session, :done}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
  end

  defp text(ref, chunks \\ []) do
    receive do
      {:text, ^ref, chunk} -> text(ref, [chunk | chunks])
      {:end, ^ref} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    after
      1_000 -> flunk("parser did not finish")
    end
  end
end
