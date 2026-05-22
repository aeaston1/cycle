defmodule Cycle.GlobalPolicyTest do
  use ExUnit.Case, async: true

  alias Cycle.GlobalPolicy
  alias Cycle.WorkflowPolicy

  test "exact required policy match is valid" do
    assert {:ok, global} =
             GlobalPolicy.from_config(%{
               "policy" => %{
                 "enforcement" => "report",
                 "required" => %{
                   "codex" => %{"model" => "gpt-5.5"},
                   "review_judge" => %{"policy" => "standard"},
                   "capacity" => %{"max_concurrent_agents" => 2},
                   "engine" => %{"id" => "openai-symphony@main"}
                 }
               }
             })

    assert {:ok, workflow} =
             WorkflowPolicy.parse("""
             ---
             agent:
               max_concurrent_agents: 2
             codex:
               model: gpt-5.5
             engine:
               id: openai-symphony@main
             review_judge:
               policy: standard
             ---
             """)

    assert %GlobalPolicy.Result{status: "valid", drift: []} =
             GlobalPolicy.classify(global, workflow)
  end

  test "missing non-required defaultable setting remains valid" do
    assert {:ok, global} = GlobalPolicy.from_config(%{"policy" => %{"enforcement" => "report"}})

    assert {:ok, workflow} =
             WorkflowPolicy.parse("---\nagent:\n  max_concurrent_agents: 1\n---\n")

    assert %GlobalPolicy.Result{status: "valid", drift: []} =
             GlobalPolicy.classify(global, workflow)
  end

  test "report-mode drift is visible and nonblocking" do
    assert {:ok, global} =
             GlobalPolicy.from_config(%{
               "policy" => %{
                 "enforcement" => "report",
                 "required" => %{"review_judge" => %{"model" => "gpt-5.5"}}
               }
             })

    assert {:ok, workflow} =
             WorkflowPolicy.parse("""
             ---
             review_judge:
               model: gpt-4.1
             ---
             """)

    assert %GlobalPolicy.Result{status: "drift", drift: [drift]} =
             GlobalPolicy.classify(global, workflow)

    assert drift.path == "review_judge.model"
    assert drift.desired == "gpt-5.5"
    assert drift.observed == "gpt-4.1"
    assert drift.severity == "info"
    assert drift.propagation_available == true
  end

  test "block-mode drift is blocking" do
    assert {:ok, global} =
             GlobalPolicy.from_config(%{
               "policy" => %{
                 "enforcement" => "block",
                 "required" => %{"capacity" => %{"max_concurrent_agents" => 4}}
               }
             })

    assert {:ok, workflow} =
             WorkflowPolicy.parse("""
             ---
             agent:
               max_concurrent_agents: 2
             ---
             """)

    assert %GlobalPolicy.Result{status: "drift", drift: [drift]} =
             GlobalPolicy.classify(global, workflow)

    assert drift.path == "agent.max_concurrent_agents"
    assert drift.severity == "blocking"
  end

  test "invalid global policy config returns path errors" do
    assert {:error, errors} =
             GlobalPolicy.from_config(%{
               "policy" => %{"enforcement" => "enforce", "required" => []}
             })

    assert %{path: "policy.enforcement", reason: "must be report or block"} in errors
    assert %{path: "policy.required", reason: "must be a mapping"} in errors
  end
end
