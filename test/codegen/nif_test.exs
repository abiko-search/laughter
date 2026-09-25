Code.require_file("../../codegen/rewrite.exs", __DIR__)
Code.require_file("../../codegen/nif.exs", __DIR__)

defmodule Laughter.Codegen.NifTest do
  use ExUnit.Case, async: true

  alias Laughter.Codegen.Nif

  defmodule StubFixture do
    use Laughter.Nif.GeneratedStubs
  end

  test "all generated stubs retain the native API and fail normally when unloaded" do
    Code.ensure_loaded!(Laughter.Nif)
    functions = StubFixture.__info__(:functions)
    assert length(functions) == length(Nif.functions())

    for {name, arity} <- functions do
      assert function_exported?(Laughter.Nif, name, arity)

      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        apply(StubFixture, name, List.duplicate(nil, arity))
      end
    end
  end

  test "source-derived legacy signatures exclude Rustler's injected Env" do
    functions = StubFixture.__info__(:functions)

    for mfa <- [
          build: 0,
          filter: 6,
          document_text: 3,
          create: 3,
          parse: 2,
          done: 1,
          rewriter_new: 2,
          rewriter_on_element: 2,
          rewriter_on_text: 2,
          rewriter_write: 2,
          rewriter_poll: 1,
          rewriter_respond: 2,
          rewriter_output: 1
        ] do
      assert mfa in functions
    end

    refute {:parse, 3} in functions
    refute {:rewriter_poll, 2} in functions

    refute Enum.any?(functions, fn {name, _} ->
             String.starts_with?(Atom.to_string(name), "worker_")
           end)
  end

  test "checked-in stubs are a deterministic projection of the boundary declarations" do
    assert Nif.stubs() == File.read!("lib/laughter/nif/generated_stubs.ex")
    assert Nif.stubs() == Nif.stubs()
  end
end
