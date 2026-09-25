Code.require_file("../../codegen/rewrite.exs", __DIR__)

defmodule Laughter.Codegen.RewriteTest do
  use RustQ.Test, async: true

  alias Laughter.Codegen.Rewrite

  test "generates dirty CPU NIFs with matching Elixir arities" do
    Code.ensure_loaded!(Laughter.Nif)

    for {name, arity} <- [
          rewrite_plan: 4,
          rewrite_stream_new: 5,
          rewrite_stream_write: 2,
          rewrite_stream_finish: 1,
          rewrite_stream_close: 1,
          rewrite_dynamic_new: 5,
          rewrite_dynamic_write: 3,
          rewrite_dynamic_finish: 2,
          rewrite_dynamic_reply: 3,
          rewrite_dynamic_close: 1
        ] do
      assert nif_exported?(Rewrite, name, arity)
      assert function_exported?(Laughter.Nif, name, arity)
      assert rust_source!(Rewrite, name) =~ ~s(schedule = "DirtyCpu")
    end

    for name <- [:rewrite_plan, :rewrite_stream_write, :rewrite_stream_finish] do
      assert rust_source!(Rewrite, name) =~ "NifResult<(Atom, Binary<'a>)>"
    end
  end

  test "generates typed rule and mutation codecs" do
    source = Enum.map_join(Rewrite.items(), "\n", &RustQ.Rust.render/1)
    assert RustQ.valid?(source, "generated_rewrite.rs")
    assert source =~ "rustler::NifTaggedEnum"
    assert source =~ "pub enum Mutation"
    assert source =~ "pub struct Rule"
    assert source =~ "impl rustler::Resource for StreamSession"
    assert source =~ "impl rustler::Resource for DynamicSession"
  end
end
