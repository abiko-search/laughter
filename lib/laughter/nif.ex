defmodule Laughter.Nif do
  @moduledoc false

  use Rustler,
    otp_app: :laughter,
    crate: :laughter_nif

  def build(), do: :erlang.nif_error(:nif_not_loaded)
  def filter(_builder, _pid, _selector, _send_content), do: :erlang.nif_error(:nif_not_loaded)
  def create(_builder, _encoding, _max_memory), do: :erlang.nif_error(:nif_not_loaded)
  def parse(_parser, _binary), do: :erlang.nif_error(:nif_not_loaded)
  def done(_parser), do: :erlang.nif_error(:nif_not_loaded)
end
