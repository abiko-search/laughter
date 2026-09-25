# Diagnostic load benchmark, not a statistical microbenchmark. Run:
# JOBS=2000 ROUNDS=3 ELEMENTS=100 CONCURRENCY=1,8,32 mix run bench/load.exs
# Native counters exclude parser/input/BEAM memory. RSS includes allocator caches.
# Peaks are sampled every 10ms; short bursts can be missed. Sampling adds overhead.
defmodule LaughterLoadBench do
  alias Laughter.{Nif, Rewriter}

  def run do
    jobs = positive_env("JOBS", 2_000)
    rounds = positive_env("ROUNDS", 3)
    elements = positive_env("ELEMENTS", 100)
    chunk_bytes = positive_env("CHUNK_BYTES", 4_096)

    concurrency =
      String.split(System.get_env("CONCURRENCY", "1,8,32"), ",") |> Enum.map(&positive!/1)

    html = Enum.map_join(1..elements, &~s(<p id="#{&1}">α😀 text &amp; more</p>))

    chunks =
      Stream.unfold(html, fn
        "" ->
          nil

        rest ->
          size = min(byte_size(rest), chunk_bytes)
          <<chunk::binary-size(size), tail::binary>> = rest
          {chunk, tail}
      end)
      |> Enum.to_list()

    plan = Rewriter.new() |> Rewriter.set_attribute("p", "data-rewritten", "yes")
    {:ok, expected} = Rewriter.rewrite(plan, html)
    expected = digest({0, 0}, expected)
    config = %{html: html, chunks: chunks, plan: plan, chunk_bytes: chunk_bytes}
    modes = [:native, :stream, :dynamic_no_matches, :dynamic]

    # Load code and exercise every path before measuring memory or throughput.
    for mode <- modes, _ <- 1..5, do: ^expected = rewrite(mode, config, nil)
    idle!()

    IO.puts(
      "#{jobs} documents/case; #{elements} elements/document; #{byte_size(html)} input bytes/document"
    )

    IO.puts(
      "OTP #{System.otp_release()}, Elixir #{System.version()}, #{:erlang.system_info(:schedulers_online)} schedulers"
    )

    IO.puts(
      "round,mode,concurrency,docs/s,p95_doc_ms,samples,heartbeat_max_ms,mailbox_peak,workers_peak,buffer_peak_MiB,beam_peak_delta_MiB,rss_delta_MiB,rss_after_MiB"
    )

    for iteration <- 1..rounds, mode <- modes, count <- concurrency do
      :erlang.garbage_collect()
      beam_before = :erlang.memory(:total)
      rss_before = rss()
      sampler = spawn_link(fn -> sample(%{}, metrics(), now() + 10) end)

      {elapsed, times} =
        :timer.tc(fn ->
          1..jobs
          |> Task.async_stream(
            fn _ ->
              send(sampler, {:watch, self()})
              {duration, actual} = :timer.tc(fn -> rewrite(mode, config, sampler) end)
              if actual != expected, do: raise("output mismatch in #{mode}")
              duration
            end,
            max_concurrency: count,
            ordered: false,
            timeout: 60_000
          )
          |> Enum.map(fn {:ok, time} -> time end)
        end)

      send(sampler, {:stop, self()})
      peaks = receive do: ({:peaks, peaks} -> peaks)
      idle!()
      :erlang.garbage_collect()
      times = Enum.sort(times)
      p95 = Enum.at(times, ceil(length(times) * 0.95) - 1) / 1_000

      rss_after = rss()

      rss_delta =
        case {rss_before, rss_after} do
          {a, b} when is_integer(a) and is_integer(b) -> mib(b - a)
          _ -> "n/a"
        end

      IO.puts(
        Enum.join(
          [
            iteration,
            mode,
            count,
            round(jobs * 1_000_000 / elapsed),
            round2(p95),
            peaks.samples,
            sampled(peaks, peaks.lag),
            sampled(peaks, peaks.mailbox),
            sampled(peaks, peaks.workers),
            sampled(peaks, mib(peaks.capacity)),
            sampled(peaks, mib(max(0, peaks.beam - beam_before))),
            rss_delta,
            if(rss_after, do: mib(rss_after), else: "n/a")
          ],
          ","
        )
      )
    end

    IO.puts("Final native counters (workers, buffers, capacity): #{inspect(Nif.rewrite_stats())}")
  end

  defp rewrite(:native, config, _) do
    {:ok, output} = Rewriter.rewrite(config.plan, config.html)
    digest({0, 0}, output)
  end

  defp rewrite(:stream, config, _) do
    config.chunks
    |> Rewriter.stream(config.plan, chunk_size: config.chunk_bytes)
    |> Enum.reduce({0, 0}, &digest(&2, &1))
  end

  defp rewrite(mode, config, sampler) do
    {plan, selector} =
      if mode == :dynamic, do: {Rewriter.new(), "p"}, else: {config.plan, ".never"}

    {:ok, session} = Rewriter.start_link(plan, selector: selector, chunk_size: config.chunk_bytes)
    if sampler, do: send(sampler, {:watch, session})
    monitor = Process.monitor(session)

    try do
      result =
        Enum.reduce(config.chunks, {0, 0}, fn chunk, acc ->
          :ok = Rewriter.demand(session)
          {:ok, ref} = Rewriter.write(session, chunk)
          digest(acc, output(session, ref))
        end)

      :ok = Rewriter.demand(session)
      {:ok, ref} = Rewriter.finish(session)
      result = digest(result, output(session, ref))

      receive do
        {:laughter, ^session, :done} -> :ok
      after
        10_000 -> raise "missing EOF acknowledgement"
      end

      receive do
        {:DOWN, ^monitor, :process, ^session, :normal} -> result
      after
        10_000 -> raise "session did not terminate"
      end
    after
      Process.demonitor(monitor, [:flush])
      if Process.alive?(session), do: Rewriter.cancel(session)
    end
  end

  defp output(session, ref) do
    receive do
      {:laughter, ^session, request, {:element, _, _}} ->
        :ok = Rewriter.reply(session, request, [{:set_attribute, "data-rewritten", "yes"}])
        output(session, ref)

      {:laughter, ^session, {:output, ^ref, binary}} ->
        binary

      {:laughter, ^session, {:error, reason}} ->
        raise "rewrite failed: #{inspect(reason)}"
    after
      10_000 -> raise "stalled rewrite"
    end
  end

  defp digest({bytes, crc}, binary), do: {bytes + byte_size(binary), :erlang.crc32(crc, binary)}

  defp metrics,
    do: %{samples: 0, lag: 0, mailbox: 0, workers: 0, capacity: 0, beam: :erlang.memory(:total)}

  defp sampled(%{samples: 0}, _), do: "n/a"
  defp sampled(_, value), do: value

  defp sample(pids, peaks, due) do
    # Check the deadline before receiving: registration traffic cannot starve sampling.
    if now() >= due do
      {workers, _, capacity} = Nif.rewrite_stats()

      mailbox =
        Enum.reduce(pids, 0, fn {_, pid}, peak ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, size} -> max(size, peak)
            nil -> peak
          end
        end)

      peaks = %{
        samples: peaks.samples + 1,
        lag: max(peaks.lag, now() - due),
        mailbox: max(peaks.mailbox, mailbox),
        workers: max(peaks.workers, workers),
        capacity: max(peaks.capacity, capacity),
        beam: max(peaks.beam, :erlang.memory(:total))
      }

      sample(pids, peaks, now() + 10)
    else
      receive do
        {:watch, pid} -> sample(Map.put(pids, Process.monitor(pid), pid), peaks, due)
        {:DOWN, ref, :process, _, _} -> sample(Map.delete(pids, ref), peaks, due)
        {:stop, parent} -> send(parent, {:peaks, peaks})
      after
        max(0, due - now()) -> sample(pids, peaks, due)
      end
    end
  end

  defp idle!(attempts \\ 1_000) do
    case Nif.rewrite_stats() do
      {0, 0, 0} ->
        :ok

      stats when attempts == 0 ->
        raise "native resources still live: #{inspect(stats)}"

      _ ->
        Process.sleep(5)
        idle!(attempts - 1)
    end
  end

  defp rss do
    case System.find_executable("ps") do
      nil ->
        nil

      ps ->
        case System.cmd(ps, ["-o", "rss=", "-p", System.pid()]) do
          {output, 0} -> String.trim(output) |> String.to_integer() |> Kernel.*(1_024)
          _ -> nil
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp mib(bytes), do: round2(bytes / 1_048_576)
  defp round2(number), do: Float.round(number * 1.0, 2)
  defp positive_env(name, default), do: positive!(System.get_env(name, to_string(default)))

  defp positive!(value) do
    number = String.to_integer(value)
    if number <= 0, do: raise(ArgumentError, "expected a positive integer, got #{value}")
    number
  end
end

LaughterLoadBench.run()
