defmodule Cycle.Registry.SchemaTest do
  use ExUnit.Case, async: true

  alias Cycle.EngineRegistry
  alias Cycle.ProjectRegistry
  alias Cycle.RunStore

  test "project registry schema validates and round trips while preserving unknown keys" do
    raw =
      project_registry(%{
        "projects" => [
          Map.merge(project_record(), %{
            "operator_note" => "preserve-me"
          })
        ],
        "file_note" => "kept"
      })

    assert {:ok, registry} = ProjectRegistry.from_map(raw)
    assert [project] = registry.projects
    assert project.linear_project["id"] == "project-id"
    assert project.extra == %{"operator_note" => "preserve-me"}

    assert ProjectRegistry.to_map(registry)["file_note"] == "kept"
    assert hd(ProjectRegistry.to_map(registry)["projects"])["operator_note"] == "preserve-me"
  end

  test "engine registry schema validates and round trips" do
    raw = %{
      "schema_version" => 1,
      "engines" => [engine_record()]
    }

    assert {:ok, registry} = EngineRegistry.from_map(raw)
    assert [engine] = registry.engines
    assert engine.id == "openai-symphony@main"
    assert engine.capabilities["states"] == ["Todo", "In Progress"]

    assert EngineRegistry.to_map(registry) == raw
  end

  test "engine lock schema validates and round trips" do
    raw = %{
      "schema_version" => 1,
      "locks" => [
        %{
          "name" => "symphony",
          "ref" => "main",
          "resolved_revision" => "abc123",
          "installed_at" => "2026-05-22T12:00:00Z"
        }
      ]
    }

    assert {:ok, registry} = EngineRegistry.lock_from_map(raw)
    assert [lock] = registry.locks
    assert lock.resolved_revision == "abc123"

    assert EngineRegistry.lock_to_map(registry) == raw
  end

  test "engine registry and lock persist as separate files" do
    root =
      Path.join(
        System.tmp_dir!(),
        "cycle-engine-registry-test-#{System.unique_integer([:positive])}"
      )

    registry_path = Path.join(root, "engines.yaml")
    lock_path = Path.join(root, "engines.lock.yaml")

    registry = %EngineRegistry{engines: [struct(EngineRegistry.Engine, atomize(engine_record()))]}

    lock_registry = %EngineRegistry.LockRegistry{
      locks: [
        %EngineRegistry.Lock{
          name: "openai-symphony",
          ref: "main",
          resolved_revision: "abc123",
          installed_at: "2026-05-22T12:00:00Z"
        }
      ]
    }

    try do
      assert :ok = EngineRegistry.write(registry_path, registry)
      assert :ok = EngineRegistry.write_lock(lock_path, lock_registry)

      assert {:ok, read_registry} = EngineRegistry.read(registry_path)
      assert {:ok, read_locks} = EngineRegistry.read_lock(lock_path)

      assert hd(read_registry.engines).install_path == "/tmp/cycle/engines/openai-symphony/main"
      assert hd(read_locks.locks).resolved_revision == "abc123"
    after
      File.rm_rf(root)
    end
  end

  test "engine registry rejects credentialed source urls" do
    raw = %{
      "schema_version" => 1,
      "engines" => [
        %{engine_record() | "source" => "https://token@github.com/OWNER/REPO.git"}
      ]
    }

    assert {:error, errors} = EngineRegistry.validate(raw)
    assert %{path: "$.engines[0].source", reason: "must not contain credentials"} in errors
  end

  test "engine registry write refuses invalid credentialed source urls" do
    registry = %EngineRegistry{
      engines: [
        %EngineRegistry.Engine{
          id: "openai-symphony@main",
          name: "openai-symphony",
          source: "https://token@github.com/OWNER/REPO.git",
          ref: "main",
          install_path: "/tmp/cycle/engines/openai-symphony/main",
          capabilities: %{},
          health: %{"state" => "missing"},
          capacity: %{}
        }
      ]
    }

    path =
      Path.join(
        System.tmp_dir!(),
        "cycle-invalid-engine-#{System.unique_integer([:positive])}.yaml"
      )

    assert {:error, errors} = EngineRegistry.write(path, registry)
    assert %{path: "$.engines[0].source", reason: "must not contain credentials"} in errors
    refute File.exists?(path)
  end

  test "run registry schema validates and round trips" do
    raw = %{
      "schema_version" => 1,
      "runs" => [run_record()]
    }

    assert {:ok, registry} = RunStore.from_map(raw)
    assert [run] = registry.runs
    assert run.id == "run-1"
    assert run.timestamps["created_at"] == "2026-05-22T12:00:00Z"

    assert RunStore.to_map(registry) == raw
  end

  test "missing required field returns path-level errors" do
    raw = project_registry(%{"projects" => [Map.delete(project_record(), "namespace")]})

    assert {:error, errors} = ProjectRegistry.validate(raw)
    assert %{path: "$.projects[0].namespace", reason: "is required"} in errors
  end

  test "invalid enum returns a path-level error" do
    raw = %{
      "schema_version" => 1,
      "runs" => [Map.put(run_record(), "state", "teleporting")]
    }

    assert {:error, errors} = RunStore.validate(raw)

    assert [
             %{
               path: "$.runs[0].state",
               reason:
                 "must be one of: queued, running, retrying, judging, blocked, completed, failed, cancelled, stale"
             }
           ] = errors
  end

  test "future schema version fails read-only with upgrade error" do
    raw = %{"schema_version" => 2, "engines" => []}

    assert {:error, [%{path: "$.schema_version", reason: reason}]} = EngineRegistry.validate(raw)
    assert reason == "unsupported future schema version 2; upgrade Cycle"
  end

  test "secret fields are rejected from sample records" do
    raw =
      project_registry(%{
        "projects" => [
          put_in(project_record(), ["repo", "token"], "do-not-store")
        ]
      })

    assert {:error, errors} = ProjectRegistry.validate(raw)
    assert %{path: "$.projects[0].repo.token", reason: "secret fields are not allowed"} in errors
  end

  test "project registry rejects credentialed repo urls" do
    raw =
      project_registry(%{
        "projects" => [
          put_in(project_record(), ["repo", "url"], "https://token@github.com/OWNER/REPO.git")
        ]
      })

    assert {:error, errors} = ProjectRegistry.validate(raw)
    assert %{path: "$.projects[0].repo.url", reason: "must not contain credentials"} in errors
  end

  defp project_registry(overrides) do
    Map.merge(
      %{
        "schema_version" => 1,
        "projects" => [project_record()]
      },
      overrides
    )
  end

  defp project_record do
    %{
      "linear_project" => %{
        "id" => "project-id",
        "name" => "Project",
        "slug" => "project",
        "url" => "https://linear.app/example/project/project-id"
      },
      "namespace" => "cycle",
      "repo" => %{
        "url" => "https://github.com/OWNER/REPO.git",
        "full_name" => "OWNER/REPO"
      },
      "workflow" => %{
        "path" => "WORKFLOW.md",
        "resolved_path" => "/tmp/cycle/workflows/OWNER/REPO/WORKFLOW.md"
      },
      "allowed_engines" => ["symphony"],
      "policy_profile" => "default",
      "capacity" => %{"max_concurrent_runs" => 1},
      "last_discovery_at" => "2026-05-22T12:00:00Z",
      "status" => "active",
      "error" => nil,
      "policy_drift" => %{"status" => "none"}
    }
  end

  defp engine_record do
    %{
      "id" => "openai-symphony@main",
      "name" => "openai-symphony",
      "source" => "https://github.com/OWNER/symphony.git",
      "ref" => "main",
      "install_path" => "/tmp/cycle/engines/openai-symphony/main",
      "capabilities" => %{
        "states" => ["Todo", "In Progress"],
        "extensions" => %{"custom_flag" => true}
      },
      "health" => %{"state" => "healthy", "checked_at" => "2026-05-22T12:00:00Z"},
      "capacity" => %{"max_concurrent_runs" => 2}
    }
  end

  defp run_record do
    %{
      "id" => "run-1",
      "issue" => %{"id" => "issue-id", "identifier" => "AEA-149"},
      "project" => %{"id" => "project-id", "name" => "Project"},
      "engine" => %{"id" => "symphony", "name" => "Symphony"},
      "workflow_path" => "WORKFLOW.md",
      "workflow_hash" => "sha256:abc123",
      "workspace_path" => "/tmp/cycle/workspaces/AEA-149",
      "state" => "running",
      "timestamps" => %{
        "created_at" => "2026-05-22T12:00:00Z",
        "updated_at" => "2026-05-22T12:05:00Z",
        "started_at" => "2026-05-22T12:01:00Z"
      },
      "retry" => %{"attempt" => 1, "max_attempts" => 3},
      "last_event" => %{"type" => "state_changed", "at" => "2026-05-22T12:05:00Z"},
      "evidence" => [
        %{"type" => "log", "path" => "/tmp/cycle/logs/run-1.log"}
      ]
    }
  end

  defp atomize(map), do: Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
end
