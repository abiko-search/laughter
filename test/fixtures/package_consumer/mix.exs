defmodule Laughter.PackageConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :laughter_package_consumer,
      version: "0.0.0",
      elixir: "~> 1.15",
      deps: [{:laughter, path: System.fetch_env!("LAUGHTER_PACKAGE_PATH")}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
