defmodule Laughter.MixProject do
  use Mix.Project

  def project do
    [
      app: :laughter,
      version: "0.1.0-dev",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      compilers: [:elixir_make] ++ Mix.compilers(),
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
      {:elixir_make, "~> 0.4", runtime: false},
      {:credo, "~> 1.5", only: ~w(dev test)a, runtime: false},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.24", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A streaming HTML parser for Elixir built on top of the CloudFlare's LOL HTML"
  end

  defp package do
    [
      name: :garlic,
      files: ~w(lib/laughter* c_src* priv mix.exs README* LICENSE*"),
      maintainers: ["Danila Poyarkov"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/abiko-search/garlic"}
    ]
  end
end
