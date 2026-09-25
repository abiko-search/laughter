Code.require_file("../../codegen/events.exs", __DIR__)

defmodule Laughter.Codegen.EventsTest do
  use RustQ.Test, async: true

  alias Laughter.Codegen.Events

  test "worker output encoding retains borrowed binary and term types" do
    output = rust_source!(Events, :worker_output)
    assert output =~ "binary: Binary<'a>"
    assert output =~ "(atoms::output(), id, binary, finished).encode(env)"
    refute output =~ "Vec<u8>"

    envelope = rust_source!(Events, :worker_envelope)
    assert envelope =~ "token: Term<'a>"
    assert envelope =~ "event: Term<'a>"
    assert envelope =~ "(atoms::laughter_native(), token, event).encode(env)"
  end
end
