defmodule Cycle.SchedulerTest do
  use ExUnit.Case, async: true

  alias Cycle.EngineRegistry
  alias Cycle.Scheduler

  defmodule FakeAdapter do
    @behaviour Cycle.Engine.Adapter

    def install(_engine, _opts), do: :ok
    def health(_engine, _opts), do: %{"state" => "healthy"}
    def capabilities(engine), do: engine.capabilities
    def start_foreground(_engine, _opts), do: :ok
    def status(_engine, _opts), do: {:ok, %{}}
    def stop(_engine, _opts), do: :ok

    def dispatch(_engine, request, _opts), do: {:ok, %{"run_id" => request["run_id"]}}
  end

  test "scheduler can ask whether adapter dispatch is supported" do
    refute Scheduler.dispatch_supported?(FakeAdapter, engine(false))
    assert Scheduler.dispatch_supported?(FakeAdapter, engine(true))
  end

  test "unsupported dispatch stays queued with stable reason code" do
    assert {:queued, %{"code" => "engine_dispatch_unsupported"}} =
             Scheduler.dispatch_or_queue(FakeAdapter, engine(false), %{"run_id" => "run-1"})
  end

  test "supported dispatch may create a running result" do
    assert {:running, %{"run_id" => "run-1"}} =
             Scheduler.dispatch_or_queue(FakeAdapter, engine(true), %{"run_id" => "run-1"})
  end

  test "returns a dispatch decision when all gates pass" do
    assert [
             %Scheduler.Decision{
               status: :dispatch,
               reason_code: nil,
               message: nil,
               issue: %{identifier: "CYC-1"},
               engine: %{id: "openai-symphony@main"}
             }
           ] = Scheduler.decide([issue()], opts())
  end

  test "skips inactive and terminal issue states" do
    assert [
             %Scheduler.Decision{
               status: :skipped,
               reason_code: "issue_state_inactive",
               message: "issue is not in an active scheduler state"
             }
           ] = Scheduler.decide([issue(%{state: "Backlog"})], opts())

    assert [
             %Scheduler.Decision{
               status: :skipped,
               reason_code: "issue_terminal",
               message: "issue is in a terminal state"
             }
           ] = Scheduler.decide([issue(%{state: "Done", state_type: "completed"})], opts())
  end

  test "unresolved Linear blockers block dispatch" do
    blocker = %{"identifier" => "CYC-0", "state" => "In Progress", "state_type" => "started"}

    assert [
             %Scheduler.Decision{
               status: :blocked,
               reason_code: "linear_blocked",
               message: "issue has unresolved Linear blockers"
             }
           ] = Scheduler.decide([issue(%{blockers: [blocker]})], opts())
  end

  test "resolved Linear blockers do not block dispatch" do
    blocker = %{"identifier" => "CYC-0", "state" => "Done", "state_type" => "completed"}

    assert [%Scheduler.Decision{status: :dispatch}] =
             Scheduler.decide([issue(%{blockers: [blocker]})], opts())
  end

  test "active run states queue or retry later instead of dispatching twice" do
    assert [
             %Scheduler.Decision{
               status: :queued,
               reason_code: "issue_already_active"
             }
           ] = Scheduler.decide([issue()], opts(runs: [run("running")]))

    assert [
             %Scheduler.Decision{
               status: :retry_later,
               reason_code: "issue_retrying"
             }
           ] = Scheduler.decide([issue()], opts(runs: [run("retrying")]))
  end

  test "global capacity is enforced before dispatch allocation" do
    assert [
             %Scheduler.Decision{status: :queued, reason_code: "global_capacity_full"}
           ] =
             Scheduler.decide(
               [issue()],
               opts(global_capacity: 1, runs: [run("running", "other")])
             )
  end

  test "engine capacity and health are enforced" do
    assert [
             %Scheduler.Decision{status: :queued, reason_code: "engine_capacity_full"}
           ] =
             Scheduler.decide(
               [issue()],
               opts(
                 runs: [run("running", "other")],
                 engines: [engine(true, %{"max_concurrent_runs" => 1})]
               )
             )

    assert [
             %Scheduler.Decision{
               status: :queued,
               reason_code: "engine_unhealthy",
               message: "selected engine is not healthy"
             }
           ] = Scheduler.decide([issue()], opts(engines: [engine(true, %{}, "unhealthy")]))
  end

  test "project and state capacity are enforced" do
    assert [
             %Scheduler.Decision{status: :queued, reason_code: "project_capacity_full"}
           ] =
             Scheduler.decide(
               [issue(%{project: project(%{"capacity" => %{"max_concurrent_agents" => 1}})})],
               opts(runs: [run("running", "other", "Todo")])
             )

    assert [
             %Scheduler.Decision{status: :queued, reason_code: "state_capacity_full"}
           ] =
             Scheduler.decide(
               [
                 issue(%{
                   project:
                     project(%{
                       "capacity" => %{"max_concurrent_agents_by_state" => %{"todo" => 1}}
                     })
                 })
               ],
               opts(runs: [run("running", "other", "Todo")])
             )
  end

  test "invalid workflow and blocking drift prevent dispatch" do
    assert [
             %Scheduler.Decision{status: :blocked, reason_code: "workflow_invalid"}
           ] = Scheduler.decide([issue(%{project: project(%{"status" => "invalid"})})], opts())

    project =
      project(%{
        "status" => "drift",
        "policy_drift" => %{
          "status" => "drift",
          "records" => [%{"path" => "agent.max_concurrent_agents", "severity" => "blocking"}]
        }
      })

    assert [
             %Scheduler.Decision{status: :blocked, reason_code: "policy_drift_blocked"}
           ] = Scheduler.decide([issue(%{project: project})], opts())
  end

  test "report-only drift does not block dispatch" do
    project =
      project(%{
        "status" => "drift",
        "policy_drift" => %{
          "status" => "drift",
          "records" => [%{"path" => "agent.max_concurrent_agents", "severity" => "info"}]
        }
      })

    assert [%Scheduler.Decision{status: :dispatch}] =
             Scheduler.decide([issue(%{project: project})], opts())
  end

  test "issue is refreshed immediately before dispatch and stale state blocks dispatch" do
    refresh = fn original ->
      {:ok, %{original | state: "Done", state_type: "completed", project: nil}}
    end

    assert [
             %Scheduler.Decision{
               status: :skipped,
               reason_code: "issue_terminal",
               issue: %{state: "Done", project: %{"linear_project" => %{"id" => "project-id"}}}
             }
           ] = Scheduler.decide([issue()], opts(refresh_issue: refresh))
  end

  test "warn mode reports pressure without blocking dispatch" do
    assert [
             %Scheduler.Decision{
               status: :dispatch,
               details: %{pressure: %{"budget" => %{"status" => "warn"}}}
             }
           ] =
             Scheduler.decide(
               [issue()],
               opts(
                 budget: %{"mode" => "warn", "pressure" => true, "reason" => "token usage high"}
               )
             )
  end

  test "block mode prevents new dispatch with pressure reason" do
    assert [
             %Scheduler.Decision{
               status: :queued,
               reason_code: "scheduler_pressure_blocked",
               message: "operator budget limit reached",
               details: %{"pressure" => %{"gate" => "budget", "status" => "blocked"}}
             }
           ] =
             Scheduler.decide(
               [issue()],
               opts(
                 budget: %{
                   "mode" => "block",
                   "pressure" => true,
                   "reason" => "operator budget limit reached"
                 }
               )
             )
  end

  test "rate-limit pressure can block new dispatch" do
    assert [
             %Scheduler.Decision{
               status: :queued,
               reason_code: "scheduler_pressure_blocked",
               details: %{"pressure" => %{"gate" => "rate_limit", "status" => "blocked"}}
             }
           ] =
             Scheduler.decide(
               [issue()],
               opts(rate_limit: %{"mode" => "block", "pressure" => true})
             )
  end

  test "running run is not stopped solely due to new pressure" do
    assert [
             %Scheduler.Decision{
               status: :queued,
               reason_code: "issue_already_active"
             }
           ] =
             Scheduler.decide(
               [issue()],
               opts(
                 runs: [run("running")],
                 budget: %{"mode" => "block", "pressure" => true}
               )
             )
  end

  defp engine(single_issue) do
    engine(single_issue, %{})
  end

  defp engine(single_issue, capacity, health_state \\ "healthy") do
    %EngineRegistry.Engine{
      id: "openai-symphony@main",
      name: "openai-symphony",
      source: "https://github.com/OWNER/REPO.git",
      ref: "main",
      install_path: "/tmp/cycle/engines/openai-symphony/main",
      capabilities: %{"dispatch" => %{"single_issue" => single_issue}},
      health: %{"state" => health_state},
      capacity: capacity
    }
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        active_states: ["Todo", "In Progress", "Rework"],
        terminal_states: ["Done", "Canceled"],
        default_engine_id: "openai-symphony@main",
        engines: [engine(true)],
        runs: []
      ],
      overrides
    )
  end

  defp issue(overrides \\ %{}) do
    struct!(
      Cycle.Issue,
      Map.merge(
        %{
          id: "issue-id",
          identifier: "CYC-1",
          title: "Apply scheduler gates",
          state: "Todo",
          state_type: "unstarted",
          url: "https://linear.app/example/issue/CYC-1",
          branch: "codex/cyc-1",
          assignee: nil,
          labels: [],
          blockers: [],
          priority: 3,
          priority_label: "Medium",
          created_at: "2026-05-22T01:00:00Z",
          updated_at: "2026-05-22T02:00:00Z",
          project: project()
        },
        overrides
      )
    )
  end

  defp project(overrides \\ %{}) do
    Map.merge(
      %{
        "linear_project" => %{"id" => "project-id", "name" => "Cycle"},
        "namespace" => "cycle",
        "repo" => %{"url" => "https://github.com/OWNER/REPO.git"},
        "workflow" => %{"path" => "WORKFLOW.md"},
        "allowed_engines" => ["openai-symphony@main"],
        "capacity" => %{},
        "status" => "valid",
        "policy_drift" => %{"status" => "valid", "records" => []}
      },
      overrides
    )
  end

  defp run(state, issue_id \\ "issue-id", issue_state \\ "Todo") do
    %{
      "id" => "run-#{issue_id}",
      "state" => state,
      "issue" => %{"id" => issue_id, "identifier" => "CYC-#{issue_id}", "state" => issue_state},
      "project" => %{"id" => "project-id", "name" => "Cycle"},
      "engine" => %{"id" => "openai-symphony@main", "name" => "openai-symphony"}
    }
  end
end
