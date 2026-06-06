defmodule ExML.MixProject do
  use Mix.Project

  def project do
    [
      app: :exml,
      version: "0.1.0",
      elixir: "~> 1.15",
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
      {:nimble_parsec, "~> 1.4"},
      {:mix_test_watch, "~> 1.2", only: [:dev, :test], runtime: false}
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
