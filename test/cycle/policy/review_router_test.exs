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

  test "duplicate evidence hash skips writes" do
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
          end
        )
      )

    assert result.status == :skipped
    assert result.reason_code == "duplicate_evidence_hash"
    refute_received :unexpected_comment
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
      hard_stops: [%Cycle.Policy.ReviewJudge.HardStop{code: :sensitive_surface}]
    }
  end

  defp comment do
    %Client.Comment{id: "comment-id", body: "comment"}
  end
end
