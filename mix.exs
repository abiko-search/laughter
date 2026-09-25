defmodule Laughter.MixProject do
  use Mix.Project

  def project do
    [
      app: :laughter,
      version: "0.3.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r"^test/fixtures/", ~r"_helper\.exs$"],
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      name: "Laughter",
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/parsing.md",
          "guides/rewriting.md",
          "guides/sessions.md",
          "guides/development.md",
          "CHANGELOG.md",
          {"LICENSE", [title: "License"]},
          {"bench/README.md", [filename: "benchmarks", title: "Benchmarks"]}
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37", runtime: false},
      {:rustq, "~> 1.0.0-rc.9", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: ~w(dev test)a, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "A streaming HTML parser and rewriter for Elixir, powered by LOL HTML"
  end

  defp package do
    [
      name: :laughter,
      files:
        ~w(lib codegen bench guides rustq.exs native/laughter_nif/src native/laughter_nif/Cargo.toml native/laughter_nif/Cargo.lock mix.exs README* CHANGELOG* LICENSE* .formatter.exs),
      maintainers: ["Danila Poyarkov"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/abiko-search/laughter"}
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "cmd env MIX_ENV=test mix test",
        "cmd mix rustq.gen --check",
        "credo --strict --min-priority high",
        "dialyzer",
        "ex_dna"
      ]
    ]
  end
end
