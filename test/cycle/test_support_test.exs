defmodule Cycle.TestSupportTest do
  use ExUnit.Case, async: false

  alias Cycle.TestSupport

  test "isolated Cycle env uses temp paths and cleans them after exit" do
    key = {__MODULE__, self(), :isolated_root}

    ExUnit.Callbacks.on_exit(fn ->
      root = :persistent_term.get(key)
      :persistent_term.erase(key)

      refute File.exists?(root)
    end)

    TestSupport.with_isolated_cycle_env(%{}, fn paths ->
      assert String.starts_with?(paths.root, System.tmp_dir!())
      assert System.get_env("CYCLE_HOME") == paths.cycle_home
      assert System.get_env("XDG_CONFIG_HOME") == paths.config_home
      assert System.get_env("XDG_STATE_HOME") == paths.state_home

      File.write!(Path.join(paths.state_home, "marker"), "temporary")
      assert File.exists?(Path.join(paths.state_home, "marker"))

      :persistent_term.put(key, paths.root)
    end)
  end

  test "Linear GraphQL fake returns configured JSON" do
    stub_name = {__MODULE__, :linear_graphql_fake}
    response = %{"data" => %{"viewer" => %{"name" => "Cycle Test"}}}

    TestSupport.stub_linear_graphql(stub_name, response)

    assert {:ok, %{body: ^response}} =
             Req.post(
               TestSupport.linear_graphql_req_options(stub_name),
               json: %{query: "{ viewer { name } }"}
             )
  end

  test "registry and workflow fixtures are present" do
    fixtures = [
      "registries/valid_cycle_metadata.yml",
      "registries/symphony_metadata.yml",
      "registries/invalid_metadata.yml",
      "workflows/valid_workflow.yml",
      "workflows/invalid_workflow.yml",
      "workflows/drifted_workflow.yml"
    ]

    for fixture <- fixtures do
      assert TestSupport.read_fixture(fixture) != ""
    end
  end
end
