defmodule Cycle.Policy.EvidenceHashTest do
  use ExUnit.Case, async: true

  alias Cycle.Policy.EvidenceHash

  @evidence %{
    "issue" => %{
      "id" => "issue-id",
      "identifier" => "AEA-170",
      "title" => "Add review judge evidence hashing",
      "state" => "Human Review"
    },
    "labels" => ["cycle", "review-judge"],
    "comments" => [
      %{"id" => "comment-1", "body_hash" => "sha256:comment", "user_name" => "Codex"}
    ],
    "workpad" => %{"id" => "comment-1", "body_hash" => "sha256:comment"},
    "git" => %{
      "branch" => "eastonae/aea-170",
      "head" => "abc1234",
      "changed_files" => ["lib/cycle/policy/evidence_hash.ex"],
      "has_changes" => true
    },
    "workflow_policy_version" => "workflow-v1",
    "global_policy_version" => "global-v1"
  }

  test "same evidence produces the same hash with canonical key ordering" do
    same_evidence = %{
      "global_policy_version" => "global-v1",
      "workflow_policy_version" => "workflow-v1",
      "git" => @evidence["git"],
      "workpad" => @evidence["workpad"],
      "comments" => @evidence["comments"],
      "labels" => @evidence["labels"],
      "issue" => @evidence["issue"]
    }

    assert EvidenceHash.compute(@evidence, judge_profile: "standard") ==
             EvidenceHash.compute(same_evidence, judge_profile: "standard")
  end

  test "meaningful evidence changes produce different hashes" do
    changed = put_in(@evidence, ["labels"], ["cycle", "review-judge", "bug"])

    refute EvidenceHash.compute(@evidence, judge_profile: "standard") ==
             EvidenceHash.compute(changed, judge_profile: "standard")
  end

  test "volatile timestamps are ignored when absent from stable input" do
    first =
      @evidence
      |> put_in(["comments"], [
        %{
          "id" => "comment-1",
          "body_hash" => "sha256:comment",
          "user_name" => "Codex"
        }
      ])

    second =
      @evidence
      |> put_in(["comments"], [
        %{
          "id" => "comment-1",
          "body_hash" => "sha256:comment",
          "user_name" => "Codex"
        }
      ])

    assert EvidenceHash.compute(first, judge_profile: "standard") ==
             EvidenceHash.compute(second, judge_profile: "standard")
  end

  test "judge profile and policy versions are part of the hash input" do
    base = EvidenceHash.compute(@evidence, judge_profile: "standard")

    refute base == EvidenceHash.compute(@evidence, judge_profile: "strict")
    refute base == EvidenceHash.compute(@evidence, global_policy_version: "global-v2")
    refute base == EvidenceHash.compute(@evidence, workflow_policy_version: "workflow-v2")
  end

  test "external review fingerprints are part of the evidence hash input" do
    first =
      Map.put(@evidence, "external_review", %{
        "provider" => "clawpatch",
        "fingerprint" =>
          "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "workspace_path" => "/tmp/cycle/workspaces/AEA-170"
      })

    second =
      put_in(
        first,
        ["external_review", "fingerprint"],
        "sha256:2222222222222222222222222222222222222222222222222222222222222222"
      )

    refute EvidenceHash.compute(first, judge_profile: "standard") ==
             EvidenceHash.compute(second, judge_profile: "standard")
  end

  test "duplicate comment detection matches existing judge hash marker" do
    hash = EvidenceHash.compute(@evidence, judge_profile: "standard")

    comments = [
      %{"body" => "plain operator note"},
      %{"body" => "Review judge decision\n\n#{EvidenceHash.marker_line(hash)}\n"}
    ]

    assert EvidenceHash.duplicate_comment?(comments, hash)

    refute EvidenceHash.duplicate_comment?(
             comments,
             EvidenceHash.compute(@evidence, judge_profile: "strict")
           )
  end

  test "marker format is documented by fixture-style comment body" do
    hash = EvidenceHash.compute(@evidence, judge_profile: "standard")

    body = """
    ## Cycle Review Judge

    Decision: proceed_to_merging

    #{EvidenceHash.marker_line(hash)}
    """

    assert body =~ "Cycle-Evidence-Hash: sha256:"
    assert EvidenceHash.extract(body) == hash
  end
end
