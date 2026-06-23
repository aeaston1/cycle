defmodule Cycle.Policy.ReviewRouterTest do
  use ExUnit.Case, async: true

  alias Cycle.Linear.Client
  alias Cycle.Policy.EvidenceHash
  alias Cycle.Policy.ReviewJudge.Decision
  alias Cycle.Policy.ReviewRouter

  @hash "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  test "stale issue state skips comment and state update" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(),
        proceed_decision(),
        opts(
          refresh_issue: fn _client, _issue_id ->
            {:ok, refreshed_issue(%{state: "Done"})}
          end,
          create_comment: fn _client, _issue_id, _body ->
            send(parent, :unexpected_comment)
            {:ok, comment()}
          end,
          update_issue_state: fn _client, _issue_id, _state ->
            send(parent, :unexpected_move)
            {:ok, refreshed_issue()}
          end
        )
      )

    assert result.status == :skipped
    assert result.reason_code == "stale_issue_state"
    refute_received :unexpected_comment
    refute_received :unexpected_move
  end

  test "disabled project skips writes" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(%{project: project(%{"status" => "disabled"})}),
        proceed_decision(),
        opts(
          create_comment: fn _client, _issue_id, _body ->
            send(parent, :unexpected_comment)
            {:ok, comment()}
          end
        )
      )

    assert result.status == :skipped
    assert result.reason_code == "project_disabled"
    refute_received :unexpected_comment
  end

  test "duplicate evidence hash skips writes when state move is already complete" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(),
        proceed_decision(),
        opts(
          refresh_issue: fn _client, _issue_id ->
            {:ok, refreshed_issue(%{state: "Merging"})}
          end,
          list_comments: fn _client, _issue_id ->
            {:ok, [%Client.Comment{body: "Existing\n#{EvidenceHash.marker_line(@hash)}"}]}
          end,
          create_comment: fn _client, _issue_id, _body ->
            send(parent, :unexpected_comment)
            {:ok, comment()}
          end,
          update_issue_state: fn _client, _issue_id, _state ->
            send(parent, :unexpected_move)
            {:ok, refreshed_issue()}
          end
        )
      )

    assert result.status == :skipped
    assert result.reason_code == "duplicate_evidence_hash"
    refute_received :unexpected_comment
    refute_received :unexpected_move
  end

  test "duplicate evidence hash still completes a missing state move" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(),
        proceed_decision(),
        opts(
          list_comments: fn _client, _issue_id ->
            {:ok, [%Client.Comment{body: "Existing\n#{EvidenceHash.marker_line(@hash)}"}]}
          end,
          create_comment: fn _client, _issue_id, _body ->
            send(parent, :unexpected_comment)
            {:ok, comment()}
          end,
          update_issue_state: fn _client, issue_id, state ->
            send(parent, {:move, issue_id, state})
            {:ok, refreshed_issue(%{state: state})}
          end
        )
      )

    assert result.status == :written
    assert result.comment == nil
    assert result.moved_issue.state == "Merging"
    refute_received :unexpected_comment
    assert_received {:move, "issue-id", "Merging"}
  end

  test "human review decision posts comment and moves to review state when configured" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(),
        human_review_decision(),
        opts(
          source_state: "Automated Review",
          review_state: "Human Review",
          refresh_issue: fn _client, _issue_id ->
            {:ok, refreshed_issue(%{state: "Automated Review"})}
          end,
          create_comment: fn _client, issue_id, body ->
            send(parent, {:comment, issue_id, body})
            {:ok, comment()}
          end,
          update_issue_state: fn _client, issue_id, state ->
            send(parent, {:move, issue_id, state})
            {:ok, refreshed_issue(%{state: state})}
          end
        )
      )

    assert result.status == :written
    assert result.moved_issue.state == "Human Review"
    assert_received {:comment, "issue-id", body}
    assert body =~ "Decision: require_human_review"
    assert body =~ EvidenceHash.marker_line(@hash)
    assert_received {:move, "issue-id", "Human Review"}
    assert [%{"message" => "review is required"}] = result.details["hard_stops"]
  end

  test "proceed decision posts comment before moving to proceed state" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(),
        proceed_decision(),
        opts(
          create_comment: fn _client, issue_id, body ->
            assert Process.get(:calls, []) == []
            Process.put(:calls, [:comment])
            send(parent, {:comment, issue_id, body})
            {:ok, comment()}
          end,
          update_issue_state: fn _client, issue_id, state ->
            assert Process.get(:calls) == [:comment]
            Process.put(:calls, [:move, :comment])
            send(parent, {:move, issue_id, state})
            {:ok, refreshed_issue(%{state: state})}
          end
        )
      )

    assert result.status == :written
    assert result.moved_issue.state == "Merging"
    assert_received {:comment, "issue-id", body}
    assert body =~ "Decision: proceed_to_merging"
    assert_received {:move, "issue-id", "Merging"}
  end

  test "decision comment redacts token-like summary text before posting" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(),
        %Decision{
          decision: "require_human_review",
          confidence: "high",
          reason: "External review failed with api_key=lin_super_secret",
          evidence: [
            "Authorization: Bearer abc1234567890abc1234567890abc1234567890",
            "Fetched https://token@github.com/OWNER/REPO.git"
          ]
        },
        opts(
          create_comment: fn _client, issue_id, body ->
            send(parent, {:comment, issue_id, body})
            {:ok, comment()}
          end
        )
      )

    assert result.status == :written
    assert_received {:comment, "issue-id", body}
    assert body =~ "[REDACTED]"
    refute body =~ "lin_super_secret"
    refute body =~ "abc1234567890abc1234567890abc1234567890"
    refute body =~ "https://token@github.com/OWNER/REPO.git"
    assert body =~ "https://[REDACTED]@github.com/OWNER/REPO.git"
  end

  test "move failure after comment is visible in result" do
    parent = self()

    result =
      ReviewRouter.route(
        issue(),
        proceed_decision(),
        opts(
          create_comment: fn _client, issue_id, _body ->
            send(parent, {:comment, issue_id})
            {:ok, comment()}
          end,
          update_issue_state: fn _client, _issue_id, _state ->
            {:error, {:graphql, [%{"message" => "state transition failed"}]}}
          end
        )
      )

    assert result.status == :failed
    assert result.reason_code == "linear_write_failed"
    assert result.message =~ "update_issue_state"
    assert result.details["stage"] == "update_issue_state"
    assert_received {:comment, "issue-id"}
  end

  test "external review details are summarized in comments and registry records" do
    parent = self()

    path =
      Path.join(
        System.tmp_dir!(),
        "cycle-review-router-external-#{System.unique_integer([:positive])}.yaml"
      )

    on_exit(fn -> File.rm(path) end)

    result =
      ReviewRouter.route(
        issue(),
        external_review_decision(),
        opts(
          review_judge_registry_path: path,
          create_comment: fn _client, issue_id, body ->
            send(parent, {:comment, issue_id, body})
            {:ok, comment()}
          end
        )
      )

    expected_summary = external_review_summary()

    assert result.status == :written

    assert Map.take(result.details["external_review"], Map.keys(expected_summary)) ==
             expected_summary

    assert_received {:comment, "issue-id", body}
    assert body =~ "External review:"
    assert body =~ "Provider: clawpatch"
    assert body =~ "Status: completed"
    assert body =~ "Reason code: blocking_findings"
    assert body =~ "Findings: 2"
    assert body =~ "Severity: high=1, medium=1"
    assert body =~ "Artifact: /tmp/cycle/reviews/CYC-1.json"
    assert body =~ "Log: /tmp/cycle/reviews/CYC-1.log"
    refute_raw_external_review_payload(body)

    assert {:ok, registry} = Cycle.ReviewJudgeRegistry.load(path)
    assert [record] = registry.records

    assert Map.take(record.details["external_review"], Map.keys(expected_summary)) ==
             expected_summary

    persisted = File.read!(path)
    refute_raw_external_review_payload(persisted)
  end

  test "records route result when review judge registry path is provided" do
    path =
      Path.join(
        System.tmp_dir!(),
        "cycle-review-router-#{System.unique_integer([:positive])}.yaml"
      )

    on_exit(fn -> File.rm(path) end)

    assert %ReviewRouter.Result{status: :written} =
             ReviewRouter.route(
               issue(),
               human_review_decision(),
               opts(review_judge_registry_path: path)
             )

    assert {:ok, registry} = Cycle.ReviewJudgeRegistry.load(path)
    assert [record] = registry.records
    assert record.issue["identifier"] == "CYC-1"
    assert record.status == "written"
    assert record.decision == "require_human_review"
    assert [%{"code" => "sensitive_surface"}] = record.hard_stops
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        client: Client.new(token: "lin_test"),
        evidence_hash: @hash,
        source_state: "Human Review",
        review_state: "Human Review",
        proceed_state: "Merging",
        refresh_issue: fn _client, _issue_id -> {:ok, refreshed_issue()} end,
        list_comments: fn _client, _issue_id -> {:ok, []} end,
        create_comment: fn _client, _issue_id, _body -> {:ok, comment()} end,
        update_issue_state: fn _client, _issue_id, state ->
          {:ok, refreshed_issue(%{state: state})}
        end
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
          title: "Review routing",
          state: "Human Review",
          state_type: "started",
          url: "https://linear.app/example/issue/CYC-1",
          labels: [],
          project: project()
        },
        overrides
      )
    )
  end

  defp refreshed_issue(overrides \\ %{}) do
    struct!(
      Client.Issue,
      Map.merge(
        %{
          id: "issue-id",
          identifier: "CYC-1",
          title: "Review routing",
          state: "Human Review",
          state_type: "started",
          project_id: "project-id",
          team_id: "team-id"
        },
        overrides
      )
    )
  end

  defp project(overrides \\ %{}) do
    Map.merge(
      %{
        "linear_project" => %{"id" => "project-id", "name" => "Cycle"},
        "status" => "valid"
      },
      overrides
    )
  end

  defp proceed_decision do
    %Decision{
      decision: "proceed_to_merging",
      confidence: "high",
      reason: "Validation passed.",
      evidence: ["tests passed"]
    }
  end

  defp human_review_decision do
    %Decision{
      decision: "require_human_review",
      confidence: "high",
      reason: "Sensitive change.",
      hard_stops: [
        %Cycle.Policy.ReviewJudge.HardStop{
          code: :sensitive_surface,
          message: "review is required"
        }
      ]
    }
  end

  defp external_review_decision do
    %Decision{
      decision: "require_human_review",
      confidence: "high",
      reason: "External reviewer found blocking issues.",
      provenance: %{"external_review" => external_review_payload()}
    }
  end

  defp external_review_payload do
    %{
      "provider" => "clawpatch",
      "status" => "completed",
      "reason_code" => "blocking_findings",
      "findings" => [
        %{"severity" => "high", "body" => "RAW_FINDING_BODY_SHOULD_NOT_LEAK"},
        %{"severity" => "medium", "body" => "RAW_SECOND_FINDING_SHOULD_NOT_LEAK"}
      ],
      "artifact_path" => "/tmp/cycle/reviews/CYC-1.json",
      "log_path" => "/tmp/cycle/reviews/CYC-1.log",
      "stdout" => "RAW_STDOUT_SHOULD_NOT_LEAK",
      "stderr" => "RAW_STDERR_SHOULD_NOT_LEAK",
      "patch" => "RAW_PATCH_SHOULD_NOT_LEAK",
      "full_diff" => "RAW_DIFF_SHOULD_NOT_LEAK",
      "prompt" => "RAW_PROMPT_SHOULD_NOT_LEAK",
      "provider_config" => %{"endpoint" => "https://review.example.invalid"}
    }
  end

  defp external_review_summary do
    %{
      "provider" => "clawpatch",
      "status" => "completed",
      "reason_code" => "blocking_findings",
      "findings_count" => 2,
      "severity_breakdown" => %{"high" => 1, "medium" => 1},
      "artifact_path" => "/tmp/cycle/reviews/CYC-1.json",
      "log_path" => "/tmp/cycle/reviews/CYC-1.log"
    }
  end

  defp refute_raw_external_review_payload(body) do
    refute body =~ "RAW_FINDING_BODY_SHOULD_NOT_LEAK"
    refute body =~ "RAW_SECOND_FINDING_SHOULD_NOT_LEAK"
    refute body =~ "RAW_STDOUT_SHOULD_NOT_LEAK"
    refute body =~ "RAW_STDERR_SHOULD_NOT_LEAK"
    refute body =~ "RAW_PATCH_SHOULD_NOT_LEAK"
    refute body =~ "RAW_DIFF_SHOULD_NOT_LEAK"
    refute body =~ "RAW_PROMPT_SHOULD_NOT_LEAK"
    refute body =~ "provider_config"
    refute body =~ "review.example.invalid"
  end

  defp comment do
    %Client.Comment{id: "comment-id", body: "comment"}
  end
end
