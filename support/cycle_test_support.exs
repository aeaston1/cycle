defmodule Cycle.TestSupport do
  @moduledoc """
  Shared helpers for tests that need isolated Cycle state or fake HTTP calls.
  """

  import ExUnit.Callbacks

  @fixtures_dir Path.expand("../test/fixtures", __DIR__)

  def fixture_path(name) do
    Path.join(@fixtures_dir, name)
  end

  def read_fixture(name) do
    name
    |> fixture_path()
    |> File.read!()
  end

  def with_isolated_cycle_env(_context, fun) when is_function(fun, 1) do
    root = Path.join(System.tmp_dir!(), "cycle-test-#{System.unique_integer([:positive])}")
    config_home = Path.join(root, "config")
    state_home = Path.join(root, "state")
    cycle_home = Path.join(root, "cycle")

    File.mkdir_p!(config_home)
    File.mkdir_p!(state_home)
    File.mkdir_p!(cycle_home)

    previous_env =
      for name <- ["CYCLE_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME"], into: %{} do
        {name, System.get_env(name)}
      end

    System.put_env("CYCLE_HOME", cycle_home)
    System.put_env("XDG_CONFIG_HOME", config_home)
    System.put_env("XDG_STATE_HOME", state_home)

    on_exit(fn ->
      restore_env(previous_env)
      File.rm_rf!(root)
    end)

    fun.(%{
      root: root,
      cycle_home: cycle_home,
      config_home: config_home,
      state_home: state_home
    })
  end

  def stub_linear_graphql(name, response) do
    Req.Test.stub(name, fn conn ->
      Req.Test.json(conn, response)
    end)
  end

  def linear_graphql_req_options(name) do
    [
      base_url: "https://api.linear.app/graphql",
      plug: {Req.Test, name}
    ]
  end

  defp restore_env(previous_env) do
    Enum.each(previous_env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
