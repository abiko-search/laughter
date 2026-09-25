Code.require_file("content.exs", __DIR__)

defmodule Laughter.Codegen.Rewrite do
  @moduledoc false

  use RustQ.Native,
    build: false,
    load: false,
    rust_sources: [
      "native/laughter_nif/src/plan.rs",
      "native/laughter_nif/src/plan_stream.rs",
      "native/laughter_nif/src/plan_dynamic.rs",
      "native/laughter_nif/src/diagnostics.rs"
    ],
    rust_packages: [{"lol_html", manifest_path: "native/laughter_nif/Cargo.toml"}]

  alias RustQ.Type, as: R

  # Internal diagnostics: live native workers, bounded output buffers, and their
  # reserved capacity. No per-element instrumentation or public Rewriter API.
  @spec rewrite_stats() :: {R.usize(), R.usize(), R.usize()}
  defnif(rewrite_stats(), do: rewrite_stats_impl())

  @type attribute :: %{required(:name) => String.t(), required(:value) => String.t()}
  require Laughter.Codegen.Content
  import Laughter.Codegen.Content, only: [dispatch: 2]
  Laughter.Codegen.Content.mutation_type()

  @type rule :: %{required(:selector) => String.t(), required(:mutation) => mutation()}

  # Keep the borrowed binary's lifetime in the function signature, not a
  # generated result enum. Native errors use Rustler's {:error, reason} encoding.
  @nif schedule: :dirty_cpu
  @spec rewrite_plan(binary(), [rule()], String.t(), R.usize()) ::
          R.nif_result({R.atom(), R.path(:Binary, R.lifetime(:a))})
  defnif rewrite_plan(input, rules, encoding, max_memory) do
    rewrite_plan_impl(nif_env(), input, rules, encoding, max_memory)
  end

  # Ownership and synchronization live in Rust; RustQ owns resource registration
  # and the ResourceArc boundary.
  @type session :: R.resource(R.raw(:StreamSession))

  @nif schedule: :dirty_cpu
  @spec rewrite_stream_new([rule()], String.t(), R.usize(), R.usize(), R.usize()) ::
          R.nif_result({R.atom(), session()})
  defnif rewrite_stream_new(rules, encoding, max_memory, max_input_bytes, max_output_bytes) do
    stream_new_impl(rules, encoding, max_memory, max_input_bytes, max_output_bytes)
  end

  @nif schedule: :dirty_cpu
  @spec rewrite_stream_write(session(), binary()) ::
          R.nif_result({R.atom(), R.path(:Binary, R.lifetime(:a))})
  defnif rewrite_stream_write(session, input) do
    stream_write_impl(nif_env(), session, input)
  end

  @nif schedule: :dirty_cpu
  @spec rewrite_stream_finish(session()) ::
          R.nif_result({R.atom(), R.path(:Binary, R.lifetime(:a))})
  defnif rewrite_stream_finish(session) do
    stream_finish_impl(nif_env(), session)
  end

  @nif schedule: :dirty_cpu
  @spec rewrite_stream_close(session()) :: R.atom()
  defnif(rewrite_stream_close(session), do: stream_close_impl(session))

  @type worker_options :: %{
          required(:encoding) => String.t(),
          required(:max_memory) => R.usize(),
          required(:chunk_size) => R.usize(),
          required(:max_output_bytes) => R.usize(),
          required(:reply_timeout) => R.usize()
        }
  @type dynamic_handle :: R.resource(R.raw(:DynamicSession))

  @nif schedule: :dirty_cpu
  @spec rewrite_dynamic_new([rule()], String.t(), worker_options(), R.raw(:LocalPid), term()) ::
          R.nif_result({R.atom(), dynamic_handle()})
  defnif rewrite_dynamic_new(rules, selector, options, pid, token) do
    dynamic_new_impl(rules, selector, options, pid, token)
  end

  @nif schedule: :dirty_cpu
  @spec rewrite_dynamic_write(dynamic_handle(), R.u64(), binary()) :: R.nif_result(R.atom())
  defnif(rewrite_dynamic_write(session, id, input), do: dynamic_write_impl(session, id, input))

  @nif schedule: :dirty_cpu
  @spec rewrite_dynamic_finish(dynamic_handle(), R.u64()) :: R.nif_result(R.atom())
  defnif(rewrite_dynamic_finish(session, id), do: dynamic_finish_impl(session, id))

  @nif schedule: :dirty_cpu
  @spec rewrite_dynamic_reply(dynamic_handle(), R.u64(), [mutation()]) :: R.nif_result(R.atom())
  defnif(rewrite_dynamic_reply(session, id, mutations),
    do: dynamic_reply_impl(session, id, mutations)
  )

  @nif schedule: :dirty_cpu
  @spec rewrite_dynamic_close(dynamic_handle()) :: R.atom()
  defnif(rewrite_dynamic_close(session), do: dynamic_close_impl(session))

  @spec apply_content_mutation(R.mut_ref(LolHtml.Send.Element.t()), R.ref(mutation())) :: R.unit()
  defrustp apply_content_mutation(element, mutation) do
    dispatch(element, mutation)
  end

  def items do
    Enum.map(RustQ.Native.items(__MODULE__), fn
      # R.enum describes the domain enum; its BEAM representation is our policy.
      %RustQ.Rust.AST.Enum{name: :Mutation} = item ->
        %{item | derive: item.derive ++ ["rustler::NifTaggedEnum"]}

      # RustQ rc.9 also marks the &mut receiver binding mutable. The binding
      # itself is never reassigned, so remove that redundant qualifier.
      %RustQ.Rust.AST.Function{name: :apply_content_mutation, args: [element | rest]} = item ->
        %{item | args: [%{element | mutable: false} | rest]}

      item ->
        item
    end)
  end
end
