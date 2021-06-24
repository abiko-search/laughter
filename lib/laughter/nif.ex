defmodule Laughter.Nif do
  @moduledoc false

  @on_load :__on_load__

  def __on_load__ do
    :laughter
    |> Application.app_dir(~w(priv laughter_nif))
    |> to_charlist()
    |> :erlang.load_nif(0)
  end

  def build(), do: :erlang.nif_error(:undef)

  def filter(_builder, _pid, _selector, _send_content), do: :erlang.nif_error(:undef)

  def create(_builder, _encoding, _max_memory), do: :erlang.nif_error(:undef)

  def parse(_parser, _binary), do: :erlang.nif_error(:undef)

  def done(_parser), do: :erlang.nif_error(:undef)
end
