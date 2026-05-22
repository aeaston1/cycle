defmodule Cycle.Config.Paths do
  @moduledoc """
  Path defaults and normalization helpers for Cycle-owned config and state.
  """

  defstruct [:config_dir, :config_file, :state_dir, :logs_dir, :engines_dir]

  def cycle_home(env \\ System.get_env(), home \\ System.user_home!()) do
    env
    |> Map.get("CYCLE_HOME", Path.join(home, ".local/share/cycle"))
    |> expand_home(home)
    |> normalize()
  end

  def config_dir(env \\ System.get_env(), home \\ System.user_home!()) do
    env
    |> Map.get("XDG_CONFIG_HOME", Path.join(home, ".config"))
    |> expand_home(home)
    |> Path.join("cycle")
    |> normalize()
  end

  def config_file(env \\ System.get_env(), home \\ System.user_home!()) do
    env
    |> config_dir(home)
    |> Path.join("config.yaml")
    |> normalize()
  end

  def legacy_config_file(env \\ System.get_env(), home \\ System.user_home!()) do
    env
    |> config_dir(home)
    |> Path.join("config.env")
    |> normalize()
  end

  def normalize(nil), do: nil

  def normalize(path) when is_binary(path) do
    Path.expand(path)
  end

  defp expand_home("~/" <> rest, home), do: Path.expand(rest, home)
  defp expand_home(path, _home), do: path
end
