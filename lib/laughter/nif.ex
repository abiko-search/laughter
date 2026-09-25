defmodule Laughter.Nif do
  @moduledoc false
  use Rustler, otp_app: :laughter, crate: :laughter_nif
  use Laughter.Nif.GeneratedStubs
end
