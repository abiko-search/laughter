defmodule Laughter.Nif do
  @moduledoc false
  use RustlerPrecompiled,
    otp_app: :laughter,
    crate: "laughter_nif",
    base_url:
      "https://github.com/abiko-search/laughter/releases/download/v#{Mix.Project.config()[:version]}",
    version: Mix.Project.config()[:version],
    force_build: System.get_env("LAUGHTER_BUILD") in ["1", "true"],
    nif_versions: ["2.15"],
    targets:
      ~w(aarch64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu x86_64-unknown-linux-musl)

  use Laughter.Nif.GeneratedStubs
end
