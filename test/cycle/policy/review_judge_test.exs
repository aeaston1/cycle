defmodule Cycle.Policy.ReviewJudgeTest do
  use ExUnit.Case, async: true

  alias Cycle.Policy.ReviewEvidence.Evidence
  alias Cycle.Policy.ReviewEvidence.MissingEvidence
  alias Cycle.Policy.ReviewJudge
  alias Cycle.Policy.ReviewJudge.Prompt

  @policy %{
    "policy" => "standard",
    "model" => "gpt-test",
    "reasoning_effort" => "medium",
    "service_tier" => "default",
    "minimum_skip_confidence" => "medium",
    "hard_require_human_review" => %{
      "paths" => ["priv/repo/**"],
      "labels" => ["security"]
    },
    "sensitive_surface_paths" => []
  }

  test "hard path stop returns require_human_review" do
    decision =
      evidence(changed_files: ["priv/repo/migrations/001_create_users.exs"])
      |> ReviewJudge.decide(@policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "require_human_review"
    assert hard_stop_codes(decision) == [:hard_path_stop]
  end

  test "hard path stop supports ordinary glob patterns" do
    policy =
      put_in(@policy, ["hard_require_human_review", "paths"], [
        "config/*.exs",
        "*.md",
        "lib/**/*.ex"
      ])

    decision =
      evidence(changed_files: ["config/runtime.exs"])
      |> ReviewJudge.decide(policy, runner: __MODULE__.ProceedRunner)

    assert :hard_path_stop in hard_stop_codes(decision)

    decision =
      evidence(changed_files: ["README.md"])
      |> ReviewJudge.decide(policy, runner: __MODULE__.ProceedRunner)

    assert :hard_path_stop in hard_stop_codes(decision)

    decision =
      evidence(changed_files: ["lib/cycle/policy/review_judge.ex"])
      |> ReviewJudge.decide(policy, runner: __MODULE__.ProceedRunner)

    assert :hard_path_stop in hard_stop_codes(decision)
  end

  test "hard label stop returns require_human_review" do
    decision =
      evidence(labels: ["security"])
      |> ReviewJudge.decide(@policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "require_human_review"
    assert :hard_label_stop in hard_stop_codes(decision)
  end

  test "missing validation evidence returns require_human_review" do
    decision =
      evidence(run_evidence: [])
      |> ReviewJudge.decide(@policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "require_human_review"
    assert :missing_validation_evidence in hard_stop_codes(decision)
  end

  test "successful non-validation artifacts do not satisfy validation evidence" do
    decision =
      evidence(
        run_evidence: [%{"type" => "artifact", "name" => "checkout", "status" => "success"}]
      )
      |> ReviewJudge.decide(@policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "require_human_review"
    assert :missing_validation_evidence in hard_stop_codes(decision)
  end

  test "named passing checks satisfy validation evidence" do
    decision =
      evidence(run_evidence: [%{"type" => "artifact", "name" => "smoke check", "status" => "ok"}])
      |> ReviewJudge.decide(@policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "proceed_to_merging"
  end

  test "missing required evidence returns require_human_review" do
    decision =
      evidence(
        git: nil,
        missing: [
          %MissingEvidence{
            code: :git_state_unavailable,
            message: "git unavailable",
            required: true
          }
        ]
      )
      |> ReviewJudge.decide(@policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "require_human_review"
    assert :missing_required_evidence in hard_stop_codes(decision)
    assert :git_evidence_unavailable in hard_stop_codes(decision)
  end

  test "sensitive workflow surface returns require_human_review" do
    policy = Map.delete(@policy, "sensitive_surface_paths")

    decision =
      evidence(changed_files: ["WORKFLOW.md"])
      |> ReviewJudge.decide(policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "require_human_review"
    assert :sensitive_surface in hard_stop_codes(decision)
  end

  test "malformed model output returns require_human_review" do
    decision =
      evidence()
      |> ReviewJudge.decide(@policy, runner: __MODULE__.MalformedRunner)

    assert decision.decision == "require_human_review"
    assert hard_stop_codes(decision) == [:malformed_model_output]
  end

  test "low confidence below threshold returns require_human_review" do
    decision =
      evidence()
      |> ReviewJudge.decide(@policy, runner: __MODULE__.LowConfidenceRunner)

    assert decision.decision == "require_human_review"
    assert hard_stop_codes(decision) == [:confidence_below_threshold]
  end

  test "valid proceed output at threshold returns proceed_to_merging" do
    decision =
      evidence()
      |> ReviewJudge.decide(@policy, runner: __MODULE__.ProceedRunner)

    assert decision.decision == "proceed_to_merging"
    assert decision.confidence == "medium"
    assert decision.hard_stops == []
    assert decision.provenance["policy_profile"] == "standard"
    assert decision.provenance["model_config"]["model"] == "gpt-test"
  end

  test "string model evidence is normalized before routing" do
    decision =
      evidence()
      |> ReviewJudge.decide(@policy, runner: __MODULE__.StringEvidenceRunner)

    assert decision.decision == "proceed_to_merging"
    assert decision.evidence == ["tests passed"]
  end

  test "malformed optional model fields fail closed" do
    decision =
      evidence()
      |> ReviewJudge.decide(@policy, runner: __MODULE__.MalformedEvidenceRunner)

    assert decision.decision == "require_human_review"
    assert hard_stop_codes(decision) == [:malformed_model_output]
  end

  test "model failure returns require_human_review" do
    decision =
      evidence()
      |> ReviewJudge.decide(@policy, runner: __MODULE__.FailingRunner)

    assert decision.decision == "require_human_review"
    assert hard_stop_codes(decision) == [:judge_failure]
  end

  test "confidence ordering follows low medium high" do
    refute ReviewJudge.confidence_at_least?("low", "medium")
    assert ReviewJudge.confidence_at_least?("medium", "medium")
    assert ReviewJudge.confidence_at_least?("high", "medium")
  end

  test "core prompt keeps review judge policy wording in one place" do
    prompt = Prompt.core()

    assert prompt =~ "Optimize for human review value"
    assert prompt =~ "proceed_to_merging or require_human_review"
    assert prompt =~ "workflow, infrastructure, security, data, or public API surfaces"
  end

  defmodule ProceedRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config) do
      {:ok,
       %{
         decision: "proceed_to_merging",
         confidence: "medium",
         human_review_value: "low",
         reason: "Scoped and validated.",
         evidence: ["tests/smoke.sh passed"]
       }}
    end
  end

  defmodule LowConfidenceRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config) do
      {:ok, %{"decision" => "proceed_to_merging", "confidence" => "low"}}
    end
  end

  defmodule StringEvidenceRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config) do
      {:ok,
       %{
         decision: "proceed_to_merging",
         confidence: "medium",
         reason: "Validated.",
         evidence: "tests passed"
       }}
    end
  end

  defmodule MalformedEvidenceRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config) do
      {:ok,
       %{
         decision: "proceed_to_merging",
         confidence: "medium",
         reason: "Validated.",
         evidence: [%{"not" => "a string"}]
       }}
    end
  end

  defmodule MalformedRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config), do: {:ok, "not json"}
  end

  defmodule FailingRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config), do: {:error, :timeout}
  end

  defp evidence(opts \\ []) do
    changed_files = Keyword.get(opts, :changed_files, ["lib/cycle/example.ex"])

    run_evidence =
      Keyword.get(opts, :run_evidence, [%{"type" => "validation", "status" => "passed"}])

    %Evidence{
      issue: %{"id" => "issue-id", "identifier" => "AEA-171", "title" => "Review judge"},
      labels: Keyword.get(opts, :labels, []),
      comments: [],
      workpad: nil,
      run: %{"id" => "run-id", "evidence" => run_evidence},
      git:
        Keyword.get(opts, :git, %{
          "changed_files" => changed_files,
          "has_changes" => changed_files != []
        }),
      workflow_policy_version: "workflow-v1",
      global_policy_version: "global-v1",
      missing: Keyword.get(opts, :missing, []),
      stable_hash_input: %{"issue" => %{"identifier" => "AEA-171"}}
    }
  end

  defp hard_stop_codes(decision), do: Enum.map(decision.hard_stops, & &1.code)
end
