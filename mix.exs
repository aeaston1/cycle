defmodule Cycle.MixProject do
  use Mix.Project

  @version System.get_env("CYCLE_VERSION", "0.1.0-dev") |> String.trim_leading("v")

  def project do
    [
      app: :cycle,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Cycle.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.9"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.11"}
    ]
  end

  defp escript do
    [
      main_module: Cycle.CLI,
      name: "cycle"
    ]
  end
end
