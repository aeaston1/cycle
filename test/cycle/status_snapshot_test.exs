defmodule Cycle.StatusSnapshotTest do
  use ExUnit.Case, async: false

  alias Cycle.EngineRegistry
  alias Cycle.Registry.Store
  alias Cycle.StatusSnapshot

  @t0 "2026-05-22T12:00:00Z"

  test "builds an empty serializable snapshot with stable top-level keys" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn _paths ->
      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 env: Map.delete(System.get_env(), "LINEAR_API_KEY"),
                 api_get: fn _url, _opts -> {:error, :closed} end,
                 health_opts: [checked_at: @t0]
               )

      assert Map.keys(snapshot) == [
               "capacity",
               "discovery",
               "drift",
               "engines",
               "linear",
               "paths",
               "projects",
               "runs",
               "schema",
               "service"
             ]

      assert snapshot["schema"] == "cycle.status_snapshot.v1"
      assert snapshot["linear"] == %{"auth" => "missing"}
      assert snapshot["projects"]["counts"]["watched"] == 0
      assert snapshot["projects"]["counts"]["invalid"] == 0
      assert snapshot["runs"]["counts"]["running"] == 0
      assert snapshot["runs"]["counts"]["queued"] == 0
      assert snapshot["drift"] == %{"count" => 0, "top" => []}
      assert is_binary(Jason.encode!(snapshot))
    end)
  end

  test "builds populated counts, capacity, drift details, and discovery errors" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      write_project_registry(cycle_home)
      write_engine_registry(cycle_home)
      write_run_registry(cycle_home)

      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 env: Map.put(System.get_env(), "LINEAR_API_KEY", "lin_secret_token"),
                 api_get: fn _url, _opts -> {:ok, %{status: 200}} end,
                 health_opts: [checked_at: @t0]
               )

      assert snapshot["linear"] == %{"auth" => "configured"}
      assert snapshot["projects"]["counts"]["watched"] == 2
      assert snapshot["projects"]["counts"]["invalid"] == 1
      assert snapshot["runs"]["counts"]["running"] == 1
      assert snapshot["runs"]["counts"]["queued"] == 1
      assert snapshot["runs"]["counts"]["retrying"] == 1
      assert snapshot["runs"]["counts"]["blocked"] == 1
      assert snapshot["runs"]["counts"]["judging"] == 1
      assert snapshot["runs"]["counts"]["completed"] == 1
      assert snapshot["runs"]["counts"]["failed"] == 1
      assert snapshot["capacity"]["global"] == %{"used" => 2, "available" => 8, "limit" => 10}
      assert snapshot["capacity"]["projects"]["project-id"]["used"] == 1
      assert snapshot["capacity"]["engines"]["openai-symphony@main"]["limit"] == 3
      assert snapshot["drift"]["count"] == 1
      assert [%{"path" => "review_judge.policy", "project" => "Cycle"}] = snapshot["drift"]["top"]

      assert [%{"project" => "Broken", "error" => "workflow missing"}] =
               snapshot["discovery"]["last_errors"]

      assert snapshot["service"]["api"]["state"] == "healthy"
    end)
  end

  test "redacts secrets and raw event bodies" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      write_run_registry(cycle_home)

      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 env: Map.put(System.get_env(), "LINEAR_API_KEY", "lin_secret_token"),
                 api_get: fn _url, _opts -> {:error, :closed} end,
                 health_opts: [checked_at: @t0]
               )

      encoded = Jason.encode!(snapshot)
      refute encoded =~ "lin_secret_token"
      refute encoded =~ "full private log body"
      assert encoded =~ "validation failed"
    end)
  end

  defp write_project_registry(cycle_home) do
    assert :ok =
             Store.write(Path.join(cycle_home, "projects.yaml"), %{
               "schema_version" => 1,
               "projects" => [
                 project_record(%{
                   "status" => "drift",
                   "capacity" => %{"max_concurrent_agents" => 2},
                   "policy_drift" => %{
                     "status" => "drift",
                     "records" => [%{"path" => "review_judge.policy"}]
                   }
                 }),
                 project_record(%{
                   "linear_project" => %{
                     "id" => "broken-id",
                     "name" => "Broken",
                     "slug" => "broken",
                     "url" => "https://linear.app/example/project/broken-id"
                   },
                   "status" => "invalid",
                   "repo" => nil,
                   "workflow" => nil,
                   "error" => "workflow missing"
                 })
               ]
             })
  end

  defp write_engine_registry(cycle_home) do
    engine = %EngineRegistry.Engine{
      id: "openai-symphony@main",
      name: "openai-symphony",
      source: "https://github.com/openai/symphony.git",
      ref: "main",
      install_path: Path.join([cycle_home, "engines", "openai-symphony", "main"]),
      health: %{"state" => "missing"},
      capacity: %{"max_concurrent_runs" => 3}
    }

    EngineRegistry.write(Path.join(cycle_home, "engines.yaml"), %EngineRegistry{engines: [engine]})
  end

  defp write_run_registry(cycle_home) do
    runs =
      ~w(running queued retrying blocked judging completed failed)
      |> Enum.with_index(1)
      |> Enum.map(fn {state, index} -> run_record("run-#{index}", state) end)

    assert :ok =
             Store.write(Path.join(cycle_home, "runs.yaml"), %{
               "schema_version" => 1,
               "runs" => runs
             })
  end

  defp project_record(overrides) do
    Map.merge(
      %{
        "linear_project" => %{
          "id" => "project-id",
          "name" => "Cycle",
          "slug" => "cycle",
          "url" => "https://linear.app/example/project/project-id"
        },
        "namespace" => "cycle",
        "repo" => %{"url" => "https://github.com/OWNER/REPO.git", "full_name" => "OWNER/REPO"},
        "workflow" => %{"path" => "WORKFLOW.md", "resolved_path" => "/tmp/cycle/WORKFLOW.md"},
        "allowed_engines" => ["openai-symphony@main"],
        "policy_profile" => "default",
        "capacity" => %{},
        "last_discovery_at" => @t0,
        "status" => "valid",
        "error" => nil,
        "policy_drift" => %{"status" => "valid", "records" => []}
      },
      overrides
    )
  end

  defp run_record(id, state) do
    %{
      "id" => id,
      "issue" => %{"id" => "issue-id", "identifier" => "AEA-165"},
      "project" => %{"id" => "project-id", "name" => "Cycle"},
      "engine" => %{"id" => "openai-symphony@main", "name" => "Symphony"},
      "workflow_path" => "WORKFLOW.md",
      "workflow_hash" => "sha256:abc123",
      "workspace_path" => "/tmp/cycle/workspaces/#{id}",
      "state" => state,
      "timestamps" => %{"created_at" => @t0, "updated_at" => @t0},
      "retry" => %{"attempt" => 0},
      "last_event" => %{"summary" => "validation failed", "body" => "full private log body"},
      "evidence" => [%{"type" => "log", "path" => "/tmp/cycle/#{id}.log"}]
    }
  end
end
