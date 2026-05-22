defmodule Cycle.WorkflowPolicyTest do
  use ExUnit.Case, async: true

  alias Cycle.WorkflowPolicy

  test "valid workflow front matter parses into Cycle-readable policy" do
    assert {:ok, policy} =
             WorkflowPolicy.parse("""
             ---
             agent:
               max_concurrent_agents: 3
               max_concurrent_agents_by_state:
                 In Progress: 1
                 Human Review: 2
               max_turns: 8
             tracker:
               active_states:
                 - Todo
                 - In Progress
               terminal_states:
                 - Done
                 - Canceled
             review_judge:
               enabled: true
               source_state: Merging
               review_state: Human Review
               proceed_state: Done
               policy: very_lenient
               minimum_skip_confidence: 0.8
               hard_require_human_review: false
             worker:
               ssh_hosts:
                 - worker-1
               max_concurrent_agents_per_host: 2
             hooks:
               before_run:
                 - tests/smoke.sh
             engine_prompt: ignored by Cycle
             ---
             Prompt body should not be part of the policy hash.
             """)

    assert policy.agent["max_concurrent_agents"] == 3
    assert policy.agent["max_turns"] == 8

    assert policy.agent["max_concurrent_agents_by_state"] == %{
             "in_progress" => 1,
             "human_review" => 2
           }

    assert policy.tracker["active_states"] == ["Todo", "In Progress"]
    assert policy.tracker["terminal_states"] == ["Done", "Canceled"]
    assert policy.review_judge["enabled"] == true
    assert policy.review_judge["source_state"] == "Merging"
    assert policy.review_judge["review_state"] == "Human Review"
    assert policy.review_judge["proceed_state"] == "Done"
    assert policy.review_judge["policy"] == "very_lenient"
    assert policy.review_judge["minimum_skip_confidence"] == 0.8
    assert policy.review_judge["hard_require_human_review"] == false
    assert policy.worker["ssh_hosts"] == ["worker-1"]
    assert policy.worker["max_concurrent_agents_per_host"] == 2
    assert policy.hooks == %{"before_run" => ["tests/smoke.sh"]}
    assert policy.hash =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "missing front matter returns invalid workflow error" do
    assert {:error, [%{path: "workflow", reason: "missing YAML front matter"}]} =
             WorkflowPolicy.parse("agent:\n  max_concurrent_agents: 1\n")
  end

  test "non-map front matter returns invalid workflow error" do
    assert {:error, [%{path: "workflow", reason: "YAML front matter must be a mapping"}]} =
             WorkflowPolicy.parse("""
             ---
             - not
             - a
             - map
             ---
             """)
  end

  test "invalid YAML returns a structured workflow error" do
    assert {:error, [%{path: "workflow", reason: reason}]} =
             WorkflowPolicy.parse("""
             ---
             agent:
               max_concurrent_agents: 1
                max_turns: 8
             ---
             """)

    assert reason =~ "invalid YAML"
  end

  test "invalid field types return path-level validation errors" do
    assert {:error, errors} =
             WorkflowPolicy.parse("""
             ---
             agent:
               max_concurrent_agents: zero
               max_concurrent_agents_by_state:
                 Todo: 0
               max_turns: many
             tracker:
               active_states: Todo
             review_judge:
               enabled: yes
               minimum_skip_confidence: high
             worker:
               ssh_hosts: worker-1
               max_concurrent_agents_per_host: 0
             ---
             """)

    assert %{path: "agent.max_concurrent_agents", reason: "must be a positive integer"} in errors
    assert %{path: "agent.max_turns", reason: "must be a positive integer"} in errors

    assert %{
             path: "agent.max_concurrent_agents_by_state.Todo",
             reason: "must be a positive integer"
           } in errors

    assert %{path: "tracker.active_states", reason: "must be a list of strings"} in errors
    assert %{path: "review_judge.enabled", reason: "must be a boolean"} in errors
    assert %{path: "review_judge.minimum_skip_confidence", reason: "must be a number"} in errors
    assert %{path: "worker.ssh_hosts", reason: "must be a list of strings"} in errors

    assert %{
             path: "worker.max_concurrent_agents_per_host",
             reason: "must be a positive integer"
           } in errors
  end

  test "unknown fields do not fail parsing" do
    assert {:ok, policy} =
             WorkflowPolicy.parse("""
             ---
             agent:
               max_concurrent_agents: 1
             codex:
               model: example-model
             prompts:
               body: ignored
             ---
             """)

    assert policy.agent["max_concurrent_agents"] == 1
  end

  test "state limit keys are normalized" do
    assert {:ok, policy} =
             WorkflowPolicy.parse("""
             ---
             agent:
               max_concurrent_agents_by_state:
                 " In Progress ": 1
                 "human-review": 2
                 "Done/Closed": 3
             ---
             """)

    assert policy.agent["max_concurrent_agents_by_state"] == %{
             "in_progress" => 1,
             "human_review" => 2,
             "done_closed" => 3
           }
  end
end
