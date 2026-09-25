defmodule Laughter.Rewriter.EquivalenceTest do
  use ExUnit.Case, async: true
  alias Laughter.Rewriter

  test "seeded mutations and byte boundaries agree across whole, streaming, and dynamic modes" do
    for seed <- 1..120 do
      :rand.seed(:exsss, {seed, 71, 903})
      mutations = for _ <- 1..:rand.uniform(8), do: mutation()
      base = Rewriter.new() |> Rewriter.set_attribute("p", "data-native", "yes")
      plan = Enum.reduce(mutations, base, &add/2)

      html =
        if rem(seed, 11) == 0 do
          ""
        else
          "<!doctype html><main><!-- 😀 -->" <>
            Enum.map_join(1..4, fn id ->
              ~s(<p title="#{id}&amp;">α😀漢字 &lt; #{id}<b>bold</b></p>)
            end) <> "</main><p"
        end

      chunks = chunks(html)
      assert {:ok, expected} = Rewriter.rewrite(plan, html)

      streamed =
        chunks |> Rewriter.stream(plan, chunk_size: 7) |> Enum.to_list() |> IO.iodata_to_binary()

      assert streamed == expected, "stream mismatch at seed #{seed}: #{inspect(mutations)}"

      assert dynamic(base, chunks, mutations) == expected,
             "dynamic mismatch at seed #{seed}: #{inspect(mutations)}"
    end
  end

  defp mutation do
    operations =
      [:remove, :set_attribute, :remove_attribute] ++
        Enum.map(Rewriter.Content.operations(), & &1.name)

    case Enum.random(operations) do
      :remove -> :remove
      :set_attribute -> {:set_attribute, "title", "<&😀\""}
      :remove_attribute -> {:remove_attribute, "title"}
      op -> {op, Enum.random(["", "A&B<😀>", ["α", ["<b>漢字</b>"]], "<i>x</i>"])}
    end
  end

  defp add(:remove, plan), do: Rewriter.remove(plan, "p")

  defp add({:set_attribute, name, value}, plan),
    do: Rewriter.set_attribute(plan, "p", name, value)

  defp add({:remove_attribute, name}, plan), do: Rewriter.remove_attribute(plan, "p", name)
  defp add({op, content}, plan), do: apply(Rewriter, op, [plan, "p", content])

  defp chunks(""), do: [""]

  defp chunks(binary) do
    size = min(byte_size(binary), :rand.uniform(23))
    <<chunk::binary-size(size), rest::binary>> = binary
    ["", chunk | chunks(rest)]
  end

  defp dynamic(plan, chunks, mutations) do
    {:ok, session} = Rewriter.start_link(plan, selector: "p")
    monitor = Process.monitor(session)

    try do
      output =
        Enum.map(chunks, fn chunk ->
          :ok = Rewriter.demand(session)
          {:ok, ref} = Rewriter.write(session, chunk)
          output(session, ref, mutations)
        end)

      :ok = Rewriter.demand(session)
      {:ok, ref} = Rewriter.finish(session)
      tail = output(session, ref, mutations)
      assert_receive {:laughter, ^session, :done}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
      IO.iodata_to_binary([output, tail])
    after
      if Process.alive?(session), do: Rewriter.cancel(session)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp output(session, ref, mutations) do
    receive do
      {:laughter, ^session, request, {:element, _, _}} ->
        assert :ok = Rewriter.reply(session, request, mutations)
        output(session, ref, mutations)

      {:laughter, ^session, {:output, ^ref, binary}} ->
        binary

      {:laughter, ^session, {:error, reason}} ->
        flunk("dynamic rewrite failed: #{inspect(reason)}")
    after
      2_000 -> flunk("dynamic rewrite stalled")
    end
  end
end
