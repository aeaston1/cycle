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
               "last_errors",
               "linear",
               "migration",
               "paths",
               "pressure",
               "projects",
               "registries",
               "review_judge",
               "runs",
               "schema",
               "service"
             ]

      assert snapshot["schema"] == "cycle.status_snapshot.v1"

      assert snapshot["paths"]["logs"] ==
               Path.join(cycle_home_from_snapshot(snapshot), "logs/cycle.log")

      assert snapshot["linear"] == %{"auth" => "missing"}
      assert snapshot["registries"]["projects"]["state"] == "ok"
      assert snapshot["registries"]["engines"]["state"] == "ok"
      assert snapshot["registries"]["runs"]["state"] == "ok"
      assert snapshot["projects"]["counts"]["watched"] == 0
      assert snapshot["projects"]["counts"]["invalid"] == 0
      assert snapshot["runs"]["counts"]["running"] == 0
      assert snapshot["runs"]["counts"]["queued"] == 0
      assert snapshot["review_judge"]["source_queue_count"] == 0
      assert snapshot["review_judge"]["active_count"] == 0
      assert snapshot["review_judge"]["last_decisions"] == []
      assert snapshot["drift"] == %{"count" => 0, "top" => []}
      assert snapshot["pressure"]["budget"]["status"] == "ok"
      assert snapshot["pressure"]["rate_limit"]["status"] == "ok"
      assert is_binary(Jason.encode!(snapshot))
    end)
  end

  test "status reports configured pressure reasons" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{config_home: config_home} ->
      config_dir = Path.join(config_home, "cycle")
      File.mkdir_p!(config_dir)

      File.write!(
        Path.join(config_dir, "config.yaml"),
        """
        scheduler:
          budget:
            mode: warn
            pressure: true
            reason: token usage is high
          rate_limit:
            mode: block
            pressure: true
            reason: Linear rate limit is low
        """
      )

      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 api_get: fn _url, _opts -> {:error, :closed} end,
                 health_opts: [checked_at: @t0]
               )

      assert snapshot["pressure"]["budget"] == %{
               "mode" => "warn",
               "pressure" => true,
               "reason" => "token usage is high",
               "status" => "warn"
             }

      assert snapshot["pressure"]["rate_limit"] == %{
               "mode" => "block",
               "pressure" => true,
               "reason" => "Linear rate limit is low",
               "status" => "blocked"
             }
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

      assert %{
               "retry" => %{"reason" => "engine_unhealthy"},
               "last_event" => %{"reason_code" => "engine_unhealthy"}
             } = Enum.find(snapshot["runs"]["details"], &(&1["state"] == "retrying"))

      assert snapshot["capacity"]["global"] == %{"used" => 4, "available" => 6, "limit" => 10}
      assert snapshot["capacity"]["projects"]["project-id"]["used"] == 4

      assert snapshot["capacity"]["states"]["project-id"]["Todo"] == %{
               "used" => 4,
               "available" => 0,
               "limit" => 2
             }

      assert snapshot["capacity"]["engines"]["openai-symphony@main"]["used"] == 4
      assert snapshot["capacity"]["engines"]["openai-symphony@main"]["limit"] == 3
      assert snapshot["drift"]["count"] == 1
      assert [%{"path" => "review_judge.policy", "project" => "Cycle"}] = snapshot["drift"]["top"]

      assert [%{"project" => "Broken", "error" => "workflow missing"}] =
               snapshot["discovery"]["last_errors"]

      assert Enum.any?(snapshot["last_errors"], &(&1["source"] == "discovery"))
      assert Enum.any?(snapshot["last_errors"], &(&1["source"] == "run"))
      assert Enum.any?(snapshot["last_errors"], &(&1["source"] == "engine"))
      assert snapshot["service"]["api"]["state"] == "healthy"
    end)
  end

  test "state capacity is preserved per project when state names overlap" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      assert :ok =
               Store.write(Path.join(cycle_home, "projects.yaml"), %{
                 "schema_version" => 1,
                 "projects" => [
                   project_record(%{
                     "linear_project" => %{
                       "id" => "project-a",
                       "name" => "Project A",
                       "slug" => "project-a",
                       "url" => "https://linear.app/example/project/project-a"
                     },
                     "capacity" => %{"max_concurrent_agents_by_state" => %{"Todo" => 1}}
                   }),
                   project_record(%{
                     "linear_project" => %{
                       "id" => "project-b",
                       "name" => "Project B",
                       "slug" => "project-b",
                       "url" => "https://linear.app/example/project/project-b"
                     },
                     "capacity" => %{"max_concurrent_agents_by_state" => %{"Todo" => 2}}
                   })
                 ]
               })

      assert :ok =
               Store.write(Path.join(cycle_home, "runs.yaml"), %{
                 "schema_version" => 1,
                 "runs" => [
                   run_record("run-a", "running")
                   |> Map.put("project", %{"id" => "project-a", "name" => "Project A"}),
                   run_record("run-b", "running")
                   |> Map.put("project", %{"id" => "project-b", "name" => "Project B"})
                 ]
               })

      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 api_get: fn _url, _opts -> {:error, :closed} end,
                 health_opts: [checked_at: @t0]
               )

      assert snapshot["capacity"]["states"]["project-a"]["Todo"] == %{
               "used" => 1,
               "available" => 0,
               "limit" => 1
             }

      assert snapshot["capacity"]["states"]["project-b"]["Todo"] == %{
               "used" => 1,
               "available" => 1,
               "limit" => 2
             }
    end)
  end

  test "includes configured external Symphony status URL for migration comparison" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{config_home: config_home} ->
      config_dir = Path.join(config_home, "cycle")
      File.mkdir_p!(config_dir)

      File.write!(
        Path.join(config_dir, "config.yaml"),
        """
        service:
          external_symphony_status_url: http://127.0.0.1:4764/api/v1/status
        """
      )

      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 api_get: fn
                   "http://127.0.0.1:4764/api/v1/status", _opts -> {:ok, %{status: 200}}
                   _url, _opts -> {:error, :closed}
                 end,
                 migration_opts: [
                   service: %{
                     "manager" => "systemd",
                     "name" => "symphony.service",
                     "state" => "running",
                     "pid" => 4321,
                     "file_path" => "/etc/systemd/system/symphony.service",
                     "guidance" => nil
                   }
                 ],
                 health_opts: [checked_at: @t0]
               )

      assert snapshot["migration"]["configured_status_url"] ==
               "http://127.0.0.1:4764/api/v1/status"

      assert snapshot["migration"]["api"] == %{
               "state" => "healthy",
               "url" => "http://127.0.0.1:4764/api/v1/status"
             }

      assert snapshot["migration"]["service_hint"]["state"] == "running"
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

  test "includes review judge queue, decisions, skips, hard stops, and failures" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      write_project_registry(cycle_home)
      write_run_registry(cycle_home)
      write_review_judge_registry(cycle_home)

      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 api_get: fn _url, _opts -> {:error, :closed} end,
                 health_opts: [checked_at: @t0]
               )

      judge = snapshot["review_judge"]
      assert judge["source_queue_count"] == 3
      assert judge["active_count"] == 2
      assert judge["duplicate_skips"] == 1
      assert judge["route_failures"] == 1
      assert judge["hard_review_reasons"] == %{"sensitive_surface" => 1}

      assert [%{"issue" => %{"identifier" => "AEA-170"}, "decision" => "require_human_review"}] =
               judge["last_decisions"]

      decision_record = Enum.find(judge["records"], &(&1["issue"]["identifier"] == "AEA-170"))

      external_review = decision_record["details"]["external_review"]

      assert Map.take(external_review, [
               "provider",
               "status",
               "reason_code",
               "findings_count",
               "severity_breakdown",
               "artifact_path",
               "log_path"
             ]) == %{
               "provider" => "clawpatch",
               "status" => "completed",
               "reason_code" => "blocking_findings",
               "findings_count" => 2,
               "severity_breakdown" => %{"high" => 1, "medium" => 1},
               "artifact_path" => "/tmp/cycle/reviews/AEA-170.json",
               "log_path" => "/tmp/cycle/reviews/AEA-170.log"
             }

      assert Enum.any?(judge["records"], &(&1["reason_code"] == "linear_write_failed"))
      encoded = Jason.encode!(judge)
      refute encoded =~ "lin_secret_token"
      refute encoded =~ "RAW_STDOUT_SHOULD_NOT_LEAK"
      refute encoded =~ "RAW_STDERR_SHOULD_NOT_LEAK"
      refute encoded =~ "RAW_PATCH_SHOULD_NOT_LEAK"
      refute encoded =~ "RAW_DIFF_SHOULD_NOT_LEAK"
      refute encoded =~ "RAW_PROMPT_SHOULD_NOT_LEAK"
      refute encoded =~ "provider_config"
      refute encoded =~ "review.example.invalid"
    end)
  end

  test "reports invalid registry errors without raising" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      File.mkdir_p!(cycle_home)

      File.write!(
        Path.join(cycle_home, "projects.yaml"),
        "schema_version: 1\nprojects:\n  - status: definitely-not-valid\n"
      )

      assert {:ok, snapshot} =
               StatusSnapshot.build(
                 api_get: fn _url, _opts -> {:error, :closed} end,
                 health_opts: [checked_at: @t0]
               )

      assert snapshot["projects"]["counts"]["watched"] == 0
      assert snapshot["registries"]["projects"]["state"] == "error"
      assert snapshot["registries"]["projects"]["path"] == Path.join(cycle_home, "projects.yaml")
      assert snapshot["registries"]["projects"]["error"] =~ "status"
      assert snapshot["registries"]["projects"]["error"] =~ "must be one of"
    end)
  end

  defp write_project_registry(cycle_home) do
    assert :ok =
             Store.write(Path.join(cycle_home, "projects.yaml"), %{
               "schema_version" => 1,
               "projects" => [
                 project_record(%{
                   "status" => "drift",
                   "capacity" => %{
                     "max_concurrent_agents" => 2,
                     "max_concurrent_agents_by_state" => %{"Todo" => 2}
                   },
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

  defp write_review_judge_registry(cycle_home) do
    assert :ok =
             Store.write(Path.join(cycle_home, "review_judge.yaml"), %{
               "schema_version" => 1,
               "source_queue_count" => 3,
               "records" => [
                 %{
                   "id" => "active-AEA-169",
                   "issue" => %{"id" => "issue-active", "identifier" => "AEA-169"},
                   "project" => %{"id" => "project-id", "name" => "Cycle"},
                   "status" => "active",
                   "timestamps" => %{"updated_at" => @t0}
                 },
                 %{
                   "id" => "decision-AEA-170",
                   "issue" => %{"id" => "issue-decision", "identifier" => "AEA-170"},
                   "project" => %{"id" => "project-id", "name" => "Cycle"},
                   "status" => "written",
                   "decision" => "require_human_review",
                   "message" => "Hard stop requires human review.",
                   "hard_stops" => [%{"code" => "sensitive_surface"}],
                   "details" => %{
                     "body" => "Bearer lin_secret_token_123456789012345678901234",
                     "external_review" => %{
                       "provider" => "clawpatch",
                       "status" => "completed",
                       "reason_code" => "blocking_findings",
                       "findings" => [
                         %{"severity" => "high", "body" => "RAW_FINDING_BODY_SHOULD_NOT_LEAK"},
                         %{
                           "severity" => "medium",
                           "body" => "RAW_SECOND_FINDING_SHOULD_NOT_LEAK"
                         }
                       ],
                       "artifact_path" => "/tmp/cycle/reviews/AEA-170.json",
                       "log_path" => "/tmp/cycle/reviews/AEA-170.log",
                       "stdout" => "RAW_STDOUT_SHOULD_NOT_LEAK",
                       "stderr" => "RAW_STDERR_SHOULD_NOT_LEAK",
                       "patch" => "RAW_PATCH_SHOULD_NOT_LEAK",
                       "full_diff" => "RAW_DIFF_SHOULD_NOT_LEAK",
                       "prompt" => "RAW_PROMPT_SHOULD_NOT_LEAK",
                       "provider_config" => %{"endpoint" => "https://review.example.invalid"}
                     }
                   },
                   "timestamps" => %{"updated_at" => @t0}
                 },
                 %{
                   "id" => "duplicate-AEA-171",
                   "issue" => %{"id" => "issue-duplicate", "identifier" => "AEA-171"},
                   "project" => %{"id" => "project-id", "name" => "Cycle"},
                   "status" => "skipped",
                   "reason_code" => "duplicate_evidence_hash",
                   "timestamps" => %{"updated_at" => @t0}
                 },
                 %{
                   "id" => "failed-AEA-172",
                   "issue" => %{"id" => "issue-failed", "identifier" => "AEA-172"},
                   "project" => %{"id" => "project-id", "name" => "Cycle"},
                   "status" => "failed",
                   "reason_code" => "linear_write_failed",
                   "message" => "review judge Linear write failed during update_issue_state",
                   "timestamps" => %{"updated_at" => @t0}
                 }
               ]
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

  defp run_record(id, "retrying") do
    run_record(id, "queued")
    |> Map.merge(%{
      "state" => "retrying",
      "retry" => %{
        "attempt" => 2,
        "max_attempts" => 3,
        "next_retry_at" => "2026-05-22T12:10:00Z",
        "reason" => "engine_unhealthy"
      },
      "last_event" => %{
        "type" => "retry_scheduled",
        "reason_code" => "engine_unhealthy",
        "message" => "selected engine is not healthy"
      }
    })
  end

  defp run_record(id, state) do
    %{
      "id" => id,
      "issue" => %{"id" => "issue-id", "identifier" => "AEA-165", "state" => "Todo"},
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

  defp cycle_home_from_snapshot(snapshot), do: snapshot["paths"]["state"]
end
