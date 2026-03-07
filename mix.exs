defmodule Laughter.MixProject do
  use Mix.Project

  def project do
    [
      app: :laughter,
      version: "0.2.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      name: "Laughter"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.36"},
      {:credo, "~> 1.7", only: ~w(dev test)a, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "A streaming HTML parser for Elixir built on top of CloudFlare's LOL HTML"
  end

  defp package do
    [
      name: :laughter,
      files: ~w(lib native/laughter_nif/src native/laughter_nif/Cargo.toml native/laughter_nif/Cargo.lock mix.exs README* LICENSE* .formatter.exs),
      maintainers: ["Danila Poyarkov"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/abiko-search/laughter"}
    ]
  end

  defp aliases do
    [ci: [
      "compile --warnings-as-errors",
      "cmd MIX_ENV=test mix test",
      "credo --strict --min-priority high",
      "dialyzer",
      "ex_dna"
    ]]
  end
end
