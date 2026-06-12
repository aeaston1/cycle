defmodule Cycle.Policy.ReviewEvidenceTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Cycle.Linear.Client
  alias Cycle.Linear.Client.Comment
  alias Cycle.Policy.ReviewEvidence
  alias Cycle.Policy.ReviewEvidence.MissingEvidence
  alias Cycle.RunStore

  @issue %{
    "id" => "issue-id",
    "identifier" => "AEA-169",
    "title" => "Build evidence",
    "state" => "Human Review",
    "labels" => ["cycle"]
  }

  test "latest_workpad returns the newest Codex Workpad comment" do
    older = comment("older", "## Codex Workpad\n\nold", "2026-05-22T12:00:00Z")
    newer = comment("newer", "## Codex Workpad\n\nnew", "2026-05-22T12:05:00Z")
    other = comment("other", "plain comment", "2026-05-22T12:10:00Z")

    assert %Comment{id: "newer"} = ReviewEvidence.latest_workpad([older, newer, other])
  end

  test "missing workpad does not add a missing evidence reason" do
    root = temp_root()

    try do
      init_git!(root)

      assert {:ok, run} =
               RunStore.create_queued(
                 run_store_path(root),
                 run_attrs(%{"workspace_path" => root}),
                 now: "2026-05-22T12:00:00Z"
               )

      assert {:ok, _running} =
               RunStore.transition(run_store_path(root), run.id, "running", %{},
                 now: "2026-05-22T12:01:00Z"
               )

      evidence =
        ReviewEvidence.build(
          @issue,
          client_with_comments([linear_comment("plain", "not a workpad")]),
          run_store_path: run_store_path(root)
        )

      assert evidence.workpad == nil
      refute Enum.any?(evidence.missing, &(&1.code == :missing_workpad))
    after
      File.rm_rf!(root)
    end
  end

  test "build fetches Linear comments and attaches latest RunStore evidence" do
    root = temp_root()

    try do
      init_git!(root)

      assert {:ok, _old_run} =
               RunStore.create_queued(
                 run_store_path(root),
                 run_attrs(%{"id" => "run-old", "workspace_path" => root}),
                 now: "2026-05-22T12:00:00Z"
               )

      assert {:ok, new_run} =
               RunStore.create_queued(
                 run_store_path(root),
                 run_attrs(%{"id" => "run-new", "workspace_path" => root}),
                 now: "2026-05-22T12:01:00Z"
               )

      assert {:ok, _running} =
               RunStore.transition(
                 run_store_path(root),
                 new_run.id,
                 "running",
                 %{"evidence" => [%{"type" => "log", "path" => "/tmp/run-new.log"}]},
                 now: "2026-05-22T12:02:00Z"
               )

      comments = [
        linear_comment("comment-1", "plain"),
        linear_comment("comment-2", "## Codex Workpad\n\nlatest")
      ]

      evidence =
        ReviewEvidence.build(@issue, client_with_comments(comments),
          run_store_path: run_store_path(root),
          workflow_policy_version: "workflow-v1",
          global_policy_version: "global-v1"
        )

      assert evidence.issue["identifier"] == "AEA-169"
      assert length(evidence.comments) == 2
      assert evidence.workpad["id"] == "comment-2"
      assert evidence.run["id"] == "run-new"
      assert evidence.run["evidence"] == [%{"type" => "log", "path" => "/tmp/run-new.log"}]
      assert evidence.git["workspace_path"] == root
      assert evidence.workflow_policy_version == "workflow-v1"
      assert evidence.global_policy_version == "global-v1"
      assert evidence.missing == []
    after
      File.rm_rf!(root)
    end
  end

  test "inspect_workspace reports changed files for existing git workspace" do
    root = temp_root()

    try do
      init_git!(root)
      File.write!(Path.join(root, "README.md"), "changed\n")
      File.write!(Path.join(root, "new.txt"), "new\n")

      assert {git, []} = ReviewEvidence.inspect_workspace(root, true)
      assert git["has_changes"] == true
      assert git["changed_files"] == ["README.md", "new.txt"]
      assert git["change_hash"] =~ ~r/^sha256:[0-9a-f]{64}$/
    after
      File.rm_rf!(root)
    end
  end

  test "inspect_workspace change hash changes when same file content changes" do
    root = temp_root()

    try do
      init_git!(root)
      File.write!(Path.join(root, "README.md"), "changed once\n")
      assert {first_git, []} = ReviewEvidence.inspect_workspace(root, true)

      File.write!(Path.join(root, "README.md"), "changed twice\n")
      assert {second_git, []} = ReviewEvidence.inspect_workspace(root, true)

      assert first_git["changed_files"] == second_git["changed_files"]
      refute first_git["change_hash"] == second_git["change_hash"]
    after
      File.rm_rf!(root)
    end
  end

  test "missing workspace returns a structured required reason" do
    missing = Path.join(temp_root(), "missing")

    assert {nil, [%MissingEvidence{} = reason]} = ReviewEvidence.inspect_workspace(missing, true)
    assert reason.code == :missing_workspace
    assert reason.required == true
    assert reason.details == %{"path" => missing}
  end

  test "code changing issues require run and git evidence" do
    evidence = ReviewEvidence.build(@issue, client_with_comments([]), code_changing?: true)

    assert Enum.map(evidence.missing, & &1.code) == [:missing_run_store, :missing_workspace]
    assert Enum.all?(evidence.missing, & &1.required)
  end

  test "stable hash input excludes volatile timestamps and raw comment bodies" do
    comment = linear_comment("comment-1", "## Codex Workpad\n\ncontains sensitive detail")

    evidence =
      ReviewEvidence.build(@issue, client_with_comments([comment]),
        code_changing?: false,
        workflow_policy_version: "workflow-v1",
        global_policy_version: "global-v1"
      )

    encoded = Jason.encode!(evidence.stable_hash_input)

    assert encoded =~ "body_hash"
    assert encoded =~ "workflow-v1"
    refute encoded =~ "contains sensitive detail"
    refute encoded =~ "created_at"
    refute encoded =~ "updated_at"
  end

  defp client_with_comments(comments) do
    name = unique_stub()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["query"] =~ "query CycleIssueComments"

      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "comments" => %{
              "nodes" => comments,
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      })
    end)

    Client.new(token: "lin_test", req_options: [plug: {Req.Test, name}])
  end

  defp linear_comment(id, body) do
    %{
      "id" => id,
      "body" => body,
      "url" => "https://linear.app/example/comment/#{id}",
      "createdAt" => "2026-05-22T12:00:00.000Z",
      "updatedAt" => "2026-05-22T12:00:00.000Z",
      "user" => %{"name" => "Codex"}
    }
  end

  defp comment(id, body, updated_at) do
    %Comment{
      id: id,
      body: body,
      url: "https://linear.app/example/comment/#{id}",
      created_at: "2026-05-22T12:00:00Z",
      updated_at: updated_at,
      user_name: "Codex"
    }
  end

  defp run_attrs(overrides) do
    Map.merge(
      %{
        "issue" => %{"id" => "issue-id", "identifier" => "AEA-169"},
        "project" => %{"id" => "project-id", "name" => "Cycle"},
        "engine" => %{"id" => "symphony", "name" => "Symphony"},
        "workflow_path" => "WORKFLOW.md",
        "workflow_hash" => "sha256:workflow",
        "workspace_path" => "/tmp/workspace"
      },
      overrides
    )
  end

  defp init_git!(root) do
    File.mkdir_p!(root)
    git!(root, ["init"])
    git!(root, ["config", "user.email", "cycle@example.invalid"])
    git!(root, ["config", "user.name", "Cycle Test"])
    File.write!(Path.join(root, "README.md"), "initial\n")
    git!(root, ["add", "README.md"])
    git!(root, ["commit", "-m", "initial"])
  end

  defp git!(root, args) do
    assert {_output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
  end

  defp run_store_path(root), do: Path.join(root, "runs.yaml")

  defp temp_root do
    Path.join(
      System.tmp_dir!(),
      "cycle-review-evidence-test-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_stub, do: :"review_evidence_#{System.unique_integer([:positive])}"
end
