# A small end-to-end comparison, not a statistical benchmark suite.
# Run with: mix run bench/rewrite.exs
alias Laughter.Rewriter

html =
  String.duplicate(
    ~s|<script>bad()</script><a href="/">link</a><img src="x" onclick="bad()">|,
    1_000
  )

native =
  Rewriter.new()
  |> Rewriter.remove("script")
  |> Rewriter.set_attribute("a[href]", "rel", "nofollow")
  |> Rewriter.remove_attribute("img", "onclick")

callbacks = Rewriter.new()
Rewriter.on_element(callbacks, "script", fn _, _ -> [:remove] end)
Rewriter.on_element(callbacks, "a[href]", fn _, _ -> [{:set_attribute, "rel", "nofollow"}] end)
Rewriter.on_element(callbacks, "img", fn _, _ -> [{:remove_attribute, "onclick"}] end)

{:ok, expected} = Rewriter.rewrite(native, html)
{:ok, ^expected} = Rewriter.rewrite(callbacks, html)

IO.puts("#{byte_size(html)} input bytes, 3,000 matched elements, median of 5 runs")

cases = [
  {"native rules", fn -> Rewriter.rewrite(native, html) end},
  {"streamed native rules",
   fn ->
     output = [html] |> Rewriter.stream(native) |> Enum.to_list() |> IO.iodata_to_binary()
     {:ok, output}
   end},
  {"Elixir callbacks", fn -> Rewriter.rewrite(callbacks, html) end}
]

for {name, run} <- cases do
  samples =
    for _ <- 1..5 do
      :erlang.garbage_collect()
      {microseconds, {:ok, ^expected}} = :timer.tc(run)
      microseconds
    end

  median = samples |> Enum.sort() |> Enum.at(2)
  IO.puts("#{name}: #{Float.round(median / 1_000, 2)} ms")
end
