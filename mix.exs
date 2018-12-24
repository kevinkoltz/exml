defmodule ExML.MixProject do
  use Mix.Project

  def project do
    [
      app: :exml,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps()
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
      {:nimble_parsec, "~> 0.5.0"},
      {:mix_test_watch, "~> 0.5.0"}
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
    ]
  end

  defp package do
    [
      maintainers: ["Kevin Koltz"],
      files: ["lib", "priv", "mix.exs", "README*", "LICENSE*"],
      licenses: ["Apache 2.0"],
      links: %{github: "https://github.com/kevinkoltz/exml"}
    ]
  end
end
