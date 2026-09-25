defmodule Laughter.Codegen.Events do
  @moduledoc false

  use RustQ.Meta
  alias RustQ.Type, as: R

  # Encode borrowed binaries and terms directly, without an owned byte vector
  # (which Rustler would encode as a list) or a lifetime-bearing result enum.
  @spec worker_envelope(R.path(:Env, R.lifetime(:a)), R.term(), R.term()) :: R.term()
  defrustp worker_envelope(env, token, event) do
    {Atoms.laughter_native(), token, event}.encode(env)
  end

  @spec worker_element(R.path(:Env, R.lifetime(:a)), R.u64(), String.t(), [
          {String.t(), String.t()}
        ]) ::
          R.term()
  defrustp worker_element(env, id, tag, attributes) do
    {Atoms.element(), id, tag, attributes}.encode(env)
  end

  @spec worker_output(
          R.path(:Env, R.lifetime(:a)),
          R.u64(),
          R.path(:Binary, R.lifetime(:a)),
          boolean()
        ) ::
          R.term()
  defrustp worker_output(env, id, binary, finished) do
    {Atoms.output(), id, binary, finished}.encode(env)
  end

  @spec worker_error(R.path(:Env, R.lifetime(:a)), R.term()) :: R.term()
  defrustp worker_error(env, reason) do
    {Atoms.error(), reason}.encode(env)
  end

  def items, do: RustQ.Meta.AST.functions(__MODULE__)
end
