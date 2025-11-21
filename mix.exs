defmodule Freyja.MixProject do
  use Mix.Project

  def project do
    [
      app: :freyja,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/mccraigmccraig/freyja",
      homepage_url: "https://github.com/mccraigmccraig/freyja",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mix_test_watch, "~> 1.4.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:uuid, "~> 1.1"},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    """
    Algebraic effects and handlers for Elixir using the Hefty Algebras architecture.
    Enables writing programs as pure functions with effects as data structures,
    providing clean separation between effect description and interpretation.
    """
  end

  defp package do
    [
      name: "freyja",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/freyja"
      }
    ]
  end
end
