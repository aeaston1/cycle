defmodule Cycle.API.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Cycle.EngineRegistry
  alias Cycle.Registry.Store
  alias Cycle.TestSupport

  @opts []
  @t0 "2026-01-01T00:00:00Z"

  setup context do
    TestSupport.with_isolated_cycle_env(context, fn paths ->
      {:ok, config} = Cycle.Config.load()
      {:ok, Map.put(paths, :config, config)}
    end)
  end

  test "GET /health returns status and version" do
    response = request(:get, "/health")

    assert response.status == 200

    assert Jason.decode!(response.resp_body) == %{
             "status" => "ok",
             "version" => Cycle.Version.current()
           }
  end

  test "GET /api/v1/status returns a StatusSnapshot", %{config: config} do
    response = request(:get, "/api/v1/status", config)

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["schema"] == "cycle.status_snapshot.v1"
  end

  test "GET /api/v1/projects returns registry projects without secrets", %{
    cycle_home: cycle_home,
    config: config
  } do
    write_project_registry(cycle_home)

    response = request(:get, "/api/v1/projects", config)
    payload = Jason.decode!(response.resp_body)

    assert response.status == 200
    assert [project] = payload["projects"]
    assert project["repo"]["url"] == "https://github.com/OWNER/REPO.git"
    refute inspect(payload) =~ "lin_"
  end

  test "GET /api/v1/engines returns engine registry and health", %{
    cycle_home: cycle_home,
    config: config
  } do
    write_engine_registry(cycle_home)

    response = request(:get, "/api/v1/engines", config)
    payload = Jason.decode!(response.resp_body)

    assert response.status == 200
    assert [engine] = payload["engines"]
    assert engine["id"] == "openai-symphony@main"
    assert engine["health"]["state"] == "missing"
  end

  test "GET /api/v1/runs lists runs and GET /api/v1/runs/:id returns one", %{
    cycle_home: cycle_home,
    config: config
  } do
    write_run_registry(cycle_home)

    list_response = request(:get, "/api/v1/runs", config)
    list_payload = Jason.decode!(list_response.resp_body)

    assert list_response.status == 200
    assert [%{"id" => "run-1"}] = list_payload["runs"]
    refute inspect(list_payload) =~ "full private log body"

    run_response = request(:get, "/api/v1/runs/run-1", config)
    assert Jason.decode!(run_response.resp_body)["id"] == "run-1"
  end

  test "GET /api/v1/runs/:id returns 404 for a missing run", %{config: config} do
    response = request(:get, "/api/v1/runs/missing", config)

    assert response.status == 404
    assert Jason.decode!(response.resp_body)["error"]["code"] == "run_not_found"
  end

  test "GET /api/v1/logs returns pointers only", %{config: config} do
    response = request(:get, "/api/v1/logs", config)
    payload = Jason.decode!(response.resp_body)

    assert response.status == 200
    assert payload["log_file"] =~ "/cycle/logs/cycle.log"
    assert Map.has_key?(payload, "runs_registry")
    refute Map.has_key?(payload, "contents")
  end

  defp request(method, path, config \\ nil) do
    opts = if config, do: [config: config], else: @opts

    method
    |> conn(path)
    |> Cycle.API.Router.call(Cycle.API.Router.init(opts))
  end

  defp write_project_registry(cycle_home) do
    Store.write(Path.join(cycle_home, "projects.yaml"), %{
      "schema_version" => 1,
      "projects" => [
        %{
          "linear_project" => %{
            "id" => "project-id",
            "name" => "Cycle",
            "slug" => "cycle",
            "url" => "https://linear.app/example/project/project-id"
          },
          "namespace" => "cycle",
          "repo" => %{
            "url" => "https://github.com/OWNER/REPO.git",
            "full_name" => "OWNER/REPO"
          },
          "workflow" => %{"path" => "WORKFLOW.md", "resolved_path" => "/tmp/WORKFLOW.md"},
          "allowed_engines" => ["openai-symphony@main"],
          "policy_profile" => "default",
          "capacity" => %{},
          "last_discovery_at" => @t0,
          "status" => "valid",
          "policy_drift" => %{"status" => "valid", "records" => []}
        }
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
    Store.write(Path.join(cycle_home, "runs.yaml"), %{
      "schema_version" => 1,
      "runs" => [
        %{
          "id" => "run-1",
          "issue" => %{"id" => "issue-id", "identifier" => "AEA-167"},
          "project" => %{"id" => "project-id", "name" => "Cycle"},
          "engine" => %{"id" => "openai-symphony@main", "name" => "Symphony"},
          "workflow_path" => "WORKFLOW.md",
          "workflow_hash" => "sha256:abc123",
          "workspace_path" => "/tmp/cycle/workspaces/run-1",
          "state" => "running",
          "timestamps" => %{"created_at" => @t0, "updated_at" => @t0},
          "retry" => %{"attempt" => 0},
          "last_event" => %{"summary" => "failed", "body" => "full private log body"},
          "evidence" => [%{"type" => "log", "path" => "/tmp/cycle/run-1.log"}]
        }
      ]
    })
  end
end
