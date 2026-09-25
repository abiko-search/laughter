defmodule Laughter.Rewriter.SessionTest do
  use ExUnit.Case, async: true

  alias Laughter.{Nif, Rewriter}
  alias Laughter.Rewriter.Session

  test "native rules and dynamic mutations share one pass without blocking write acceptance" do
    plan = Rewriter.new() |> Rewriter.set_attribute("a", "rel", "nofollow")
    session = start_session(plan, selector: "a[href]")
    assert {:error, :no_demand} = Rewriter.write(session, "x")
    assert :ok = Rewriter.demand(session)
    assert {:error, :already_demanded} = Rewriter.demand(session)
    assert {:ok, chunk} = Rewriter.write(session, ~s(<a href="/old">link</a>))
    assert_receive {:laughter, ^session, request, {:element, "a", attrs}}, 1_000
    assert {"rel", "nofollow"} in attrs
    assert {:error, :busy} = Rewriter.write(session, "next")
    assert {:error, :busy} = Rewriter.demand(session)
    assert {:error, :busy} = Rewriter.finish(session)
    refute_received {:laughter, ^session, {:output, _, _}}

    assert :ok =
             Rewriter.reply(session, request, [
               {:set_attribute, "href", "/new"},
               {:append_text, ["<", "!"]}
             ])

    assert_receive {:laughter, ^session, {:output, ^chunk, output}}, 1_000
    assert output == ~s(<a href="/new" rel="nofollow">link&lt;!</a>)
    assert {:error, :no_demand} = Rewriter.finish(session)
    finish(session)
  end

  test "requests are unique and stale replies cannot satisfy a later request" do
    session = start_session()
    assert :ok = Rewriter.demand(session)
    {:ok, chunk} = Rewriter.write(session, "<p>one</p><p>two</p>")
    assert_receive {:laughter, ^session, first, {:element, "p", []}}, 1_000
    assert {:error, :stale_request} = Rewriter.reply(session, make_ref(), [])
    assert :ok = Rewriter.reply(session, first, [{:replace_text, "1"}])
    assert_receive {:laughter, ^session, second, {:element, "p", []}}, 1_000
    assert first != second
    assert {:error, :stale_request} = Rewriter.reply(session, first, [:remove])
    assert :ok = Rewriter.reply(session, second, [{:replace_text, "2"}])
    assert_receive {:laughter, ^session, {:output, ^chunk, "12"}}, 1_000
    finish(session)
  end

  test "partial tokens survive writes and EOF flushes pending bytes" do
    session = start_session()
    assert :ok = Rewriter.demand(session)
    {:ok, first} = Rewriter.write(session, "<p")
    assert_receive {:laughter, ^session, {:output, ^first, ""}}, 1_000
    assert :ok = Rewriter.demand(session)
    {:ok, second} = Rewriter.write(session, ">α</p><p")
    assert_receive {:laughter, ^session, request, {:element, "p", []}}, 1_000
    assert :ok = Rewriter.reply(session, request, [])
    assert_receive {:laughter, ^session, {:output, ^second, "<p>α</p>"}}, 1_000
    finish(session, "<p")
  end

  test "removed elements do not cause dynamic requests" do
    session = start_session(Rewriter.new() |> Rewriter.remove("p"))
    :ok = Rewriter.demand(session)
    {:ok, chunk} = Rewriter.write(session, "<p>gone</p>")
    assert_receive {:laughter, ^session, {:output, ^chunk, ""}}, 1_000
    refute_received {:laughter, ^session, _, {:element, _, _}}
    finish(session)
  end

  test "invalid or oversized mutation replies can be corrected" do
    session = start_session(Rewriter.new(), max_reply_bytes: 100)
    :ok = Rewriter.demand(session)
    {:ok, chunk} = Rewriter.write(session, "<p>old</p>")
    assert_receive {:laughter, ^session, request, {:element, "p", []}}, 1_000

    for mutations <- [
          [:unknown],
          [{:append_text, <<255>>}],
          [{:set_attribute, nil, "x"}],
          [{:replace_text, String.duplicate("x", 100)}],
          List.duplicate(:remove, 129)
        ] do
      assert {:error, :invalid_mutations} = Rewriter.reply(session, request, mutations)
    end

    assert :ok = Rewriter.reply(session, request, [{:set_inner_text, "new"}])
    assert_receive {:laughter, ^session, {:output, ^chunk, "<p>new</p>"}}, 1_000
    finish(session)
  end

  test "oversized writes retain credit and do not poison the session" do
    session = start_session(Rewriter.new(), chunk_size: 4)
    :ok = Rewriter.demand(session)
    assert {:error, :input_limit} = Rewriter.write(session, "12345")
    {:ok, chunk} = Rewriter.write(session, "1234")
    assert_receive {:laughter, ^session, {:output, ^chunk, "1234"}}, 1_000
    finish(session)
  end

  test "reply timeout is terminal and closes the native handle" do
    session = start_session(Rewriter.new(), reply_timeout: 50)
    native = :sys.get_state(session).native
    monitor = Process.monitor(session)
    :ok = Rewriter.demand(session)
    {:ok, _} = Rewriter.write(session, "<p>x</p>")
    assert_receive {:laughter, ^session, _, {:element, "p", []}}, 1_000
    assert_receive {:laughter, ^session, {:error, :reply_timeout}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
    assert {:error, "session closed"} = Nif.rewrite_dynamic_finish(native, 2)
  end

  test "cancel while waiting for a reply stays responsive and discards output" do
    session = start_session()
    monitor = Process.monitor(session)
    :ok = Rewriter.demand(session)
    {:ok, _} = Rewriter.write(session, "before<p>x</p>")
    assert_receive {:laughter, ^session, _, {:element, "p", []}}, 1_000
    assert :ok = Rewriter.cancel(session)
    assert_receive {:laughter, ^session, {:error, :cancelled}}
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
    refute_received {:laughter, ^session, {:output, _, _}}
  end

  test "owner death cancels a session blocked on a dynamic decision" do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:start, session} ->
            :ok = Rewriter.demand(session)
            {:ok, _} = Rewriter.write(session, "<p>x</p>")

            receive do
              {:laughter, ^session, _, {:element, _, _}} -> send(parent, :waiting)
            end

            receive do
              :never -> :ok
            end
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    session = start_session(Rewriter.new(), owner: owner)
    native = :sys.get_state(session).native
    monitor = Process.monitor(session)
    assert {:error, :not_owner} = Rewriter.demand(session)
    assert {:error, :not_owner} = Rewriter.cancel(session)
    send(owner, {:start, session})
    assert_receive :waiting, 1_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
    assert {:error, "session closed"} = Nif.rewrite_dynamic_finish(native, 2)
  end

  test "output overflow after a reply is terminal" do
    session = start_session(Rewriter.new(), max_output_bytes: 32)
    monitor = Process.monitor(session)
    :ok = Rewriter.demand(session)
    {:ok, _} = Rewriter.write(session, "<p>x</p>")
    assert_receive {:laughter, ^session, request, {:element, "p", []}}, 1_000
    :ok = Rewriter.reply(session, request, [{:replace_text, String.duplicate("&", 20)}])
    assert_receive {:laughter, ^session, {:error, "rewrite output limit exceeded"}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
  end

  test "mutation failures are terminal rather than silently ignored" do
    session = start_session()
    :ok = Rewriter.demand(session)
    {:ok, _} = Rewriter.write(session, "<p>x</p>")
    assert_receive {:laughter, ^session, request, {:element, "p", []}}, 1_000
    :ok = Rewriter.reply(session, request, [{:set_attribute, "bad name", "x"}])
    assert_receive {:laughter, ^session, {:error, reason}}, 1_000
    assert is_binary(reason)
  end

  test "worker messages and stale timers with wrong references are ignored" do
    session = start_session()
    send(session, {:laughter_native, make_ref(), {:error, "forged"}})
    send(session, {:reply_timeout, make_ref()})
    :ok = Rewriter.demand(session)
    {:ok, chunk} = Rewriter.write(session, "text")
    assert_receive {:laughter, ^session, {:output, ^chunk, "text"}}, 1_000
    refute_received {:laughter, ^session, {:error, _}}
    finish(session)
  end

  test "sessions are temporary supervisor children" do
    spec = Session.child_spec({Rewriter.new(), owner: self(), selector: "p"})
    assert spec.restart == :temporary
    session = start_supervised!(spec)
    monitor = Process.monitor(session)
    :ok = Rewriter.cancel(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    refute List.keymember?(Supervisor.which_children(supervisor), session, 1)
  end

  test "supervisor shutdown cancels a blocked native worker" do
    session = start_session()
    native = :sys.get_state(session).native
    :ok = Rewriter.demand(session)
    {:ok, _} = Rewriter.write(session, "<p>x</p>")
    assert_receive {:laughter, ^session, _, {:element, "p", []}}, 1_000
    assert :ok = stop_supervised(Session)
    assert {:error, "session closed"} = Nif.rewrite_dynamic_finish(native, 2)
  end

  test "validates limits before starting a session" do
    for opts <- [[chunk_size: 0], [reply_timeout: 4_294_967_296], [max_reply_bytes: -1]] do
      assert_raise ArgumentError, fn ->
        Rewriter.start_link(Rewriter.new(), Keyword.put(opts, :selector, "p"))
      end
    end
  end

  test "invalid selectors and encodings fail startup without starting work" do
    Process.flag(:trap_exit, true)
    assert {:error, _} = Rewriter.start_link(Rewriter.new(), selector: "[")
    assert {:error, _} = Rewriter.start_link(Rewriter.new(encoding: "invalid"), selector: "p")
  end

  test "linked convenience API defaults the owner to the caller" do
    {:ok, session} = Rewriter.start_link(Rewriter.new(), selector: "p")
    :ok = Rewriter.demand(session)
    finish_ref = Rewriter.finish(session)
    assert {:ok, ref} = finish_ref
    assert_receive {:laughter, ^session, {:output, ^ref, ""}}, 1_000
    assert_receive {:laughter, ^session, :done}, 1_000
  end

  defp start_session(plan \\ Rewriter.new(), opts \\ []) do
    opts = Keyword.merge([owner: self(), selector: "p"], opts)
    start_supervised!({Session, {plan, opts}})
  end

  defp finish(session, expected \\ "") do
    monitor = Process.monitor(session)
    assert :ok = Rewriter.demand(session)
    assert {:ok, ref} = Rewriter.finish(session)
    assert_receive {:laughter, ^session, {:output, ^ref, ^expected}}, 1_000
    assert_receive {:laughter, ^session, :done}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
  end
end
