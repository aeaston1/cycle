defmodule Cycle.IssueTest do
  use ExUnit.Case, async: true

  alias Cycle.Issue
  alias Cycle.Linear.Client
  alias Cycle.ProjectRegistry.Project

  test "normalizes Linear issue fields and preserves project metadata" do
    project = project()

    linear_issue = %Client.Issue{
      id: "issue-id",
      identifier: "CYC-12",
      title: "Fetch candidates",
      state: "Todo",
      state_type: "unstarted",
      url: "https://linear.app/example/issue/CYC-12",
      branch_name: "codex/cyc-12",
      assignee_id: "user-id",
      assignee_name: "Ada",
      assignee_email: "ada@example.test",
      labels: ["scheduler"],
      blocks: [
        %{
          "id" => "blocker-id",
          "identifier" => "CYC-1",
          "state_type" => "started"
        }
      ],
      priority: 1,
      priority_label: "Urgent",
      created_at: "2026-05-22T01:00:00.000Z",
      updated_at: "2026-05-22T02:00:00.000Z"
    }

    assert %Issue{
             id: "issue-id",
             identifier: "CYC-12",
             title: "Fetch candidates",
             state: "Todo",
             state_type: "unstarted",
             url: "https://linear.app/example/issue/CYC-12",
             branch: "codex/cyc-12",
             assignee: %{"id" => "user-id", "name" => "Ada", "email" => "ada@example.test"},
             labels: ["scheduler"],
             blockers: [%{"identifier" => "CYC-1"}],
             priority: 1,
             priority_label: "Urgent",
             created_at: "2026-05-22T01:00:00.000Z",
             updated_at: "2026-05-22T02:00:00.000Z",
             project: %{
               "linear_project" => %{"id" => "project-id", "name" => "Cycle"},
               "namespace" => "cycle",
               "metadata_namespace" => "cycle",
               "repo" => %{"url" => "https://github.com/OWNER/REPO.git"},
               "status" => "valid",
               "custom" => "preserved"
             }
           } = Issue.from_linear(linear_issue, project)
  end

  defp project do
    %Project{
      linear_project: %{
        "id" => "project-id",
        "name" => "Cycle",
        "slug" => "CYC",
        "url" => "https://linear.app/example/project/cyc"
      },
      namespace: "cycle",
      metadata_namespace: "cycle",
      repo: %{"url" => "https://github.com/OWNER/REPO.git"},
      workflow: %{"path" => "WORKFLOW.md"},
      allowed_engines: ["openai-symphony@main"],
      policy_profile: "default",
      capacity: %{"max_concurrent_agents" => 1},
      status: "valid",
      extra: %{"custom" => "preserved"}
    }
  end
end
