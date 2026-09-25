# Message-driven rewrite sessions

[Back to the README](../README.md)

Use a session when an element needs a decision from Elixir. One dynamic CSS
selector runs alongside native rules. Each session uses a GenServer and one native
worker thread; native-only `rewrite/2` and `stream/3` avoid this coordination.

## A complete receive loop

This example classifies links using Elixir code. It handles any number of element
requests per chunk, output acknowledgements, EOF, and terminal errors. It collects
the output for convenience; send chunks to a sink instead for streaming output.
The classification is illustrative, not URL validation or sanitization.

```elixir
defmodule LinkClassifier do
  alias Laughter.Rewriter

  def rewrite(chunks) do
    plan = Rewriter.new() |> Rewriter.remove("script")
    {:ok, session} = Rewriter.start_link(plan, selector: "a[href]")

    try do
      output = Enum.map(chunks, fn chunk ->
        :ok = Rewriter.demand(session)
        {:ok, ref} = Rewriter.write(session, chunk)
        await_output(session, ref)
      end)

      :ok = Rewriter.demand(session)
      {:ok, ref} = Rewriter.finish(session)
      tail = await_output(session, ref)

      receive do
        {:laughter, ^session, :done} -> IO.iodata_to_binary([output, tail])
        {:laughter, ^session, {:error, reason}} -> raise "rewrite failed: #{inspect(reason)}"
      end
    after
      # Normal EOF already stops the session. Also close on owner-side failures.
      try do
        Rewriter.cancel(session)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp await_output(session, ref) do
    receive do
      {:laughter, ^session, request, {:element, "a", attrs}} ->
        {"href", href} = List.keyfind(attrs, "href", 0)
        kind = if String.starts_with?(href, "https://"), do: "https", else: "other"
        :ok = Rewriter.reply(session, request, [{:set_attribute, "data-kind", kind}])
        await_output(session, ref)

      {:laughter, ^session, {:output, ^ref, bytes}} ->
        bytes

      {:laughter, ^session, {:error, reason}} ->
        raise "rewrite failed: #{inspect(reason)}"
    end
  end
end

LinkClassifier.rewrite([~s(<a href="https://example.com">One</a><a href="/two">Two</a>)])
```

Native rules execute first. Removed/replaced elements do not produce dynamic
requests; attribute snapshots include native changes. An empty mutation list
keeps an element unchanged. Replies accept removal, attribute mutations, and the
[content operations](rewriting.md#content-operations).

## Demand and replies

- Only the owner may issue commands. It defaults to the `start_link/2` caller.
- `demand/1` grants one credit; credits do not accumulate.
- One credit authorizes one `write/2` or `finish/1`, with one chunk in flight.
- `write/2` returns `{:ok, chunk_ref}` after acceptance, not parsing completion.
  It does not wait for element replies.
- Output acknowledges completion and consumes the credit, even when empty.
- Every element request has a separate reference. Wrong or stale replies are
  rejected; invalid mutations can be corrected before the request times out.
- Handle all requests until output arrives, including any requests during EOF.
- `{:laughter, session, :done}` indicates successful EOF. An error message is
  terminal. Previously emitted output cannot be rolled back.

## Limits and cleanup

| Option | Default |
| --- | ---: |
| `:chunk_size` | 65,536 input bytes per write |
| `:max_output_bytes` | 1,048,576 output bytes per write or EOF flush |
| `:max_reply_bytes` | 1,048,576 external-term bytes per mutation reply |
| `:reply_timeout` | 5,000 milliseconds per element request |

Replies contain at most 128 mutations. Oversized writes are rejected rather than
split. The example's input chunks must fit `chunk_size`. The plan also controls
parser memory and document encoding. These limits do not bound upstream
allocations, mailboxes, or retained output.

Owner death, cancellation, reply timeout, and native errors terminate the session.
BEAM schedulers do not block waiting for replies; the native worker pauses instead.
For the complete command/error contract, see `Laughter.Rewriter.Session`.

## Supervision

Use a temporary child specification:

```elixir
plan = Laughter.Rewriter.new()
owner_pid = self()
child = {Laughter.Rewriter.Session, {plan, owner: owner_pid, selector: "a[href]"}}
{:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)
```

Temporary sessions are not restarted automatically: consumed input cannot be
reconstructed by restarting a process. The owner still drives the demand/reply
protocol. Cancel the session or stop the supervisor when finished.
