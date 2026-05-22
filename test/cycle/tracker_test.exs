defmodule Cycle.TrackerTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Cycle.{Config, Tracker}
  alias Cycle.ProjectRegistry
  alias Cycle.ProjectRegistry.Project

  test "fetch_candidates queries valid projects and skips invalid or disabled projects with reasons" do
    name = unique_stub()
    parent = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)
      send(parent, payload["variables"])

      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [
              issue_node("issue-1", "CYC-1", 2, "2026-05-22T02:00:00.000Z", "valid-project")
            ],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      })
    end)

    registry = %ProjectRegistry{
      projects: [
        project("valid-project", "valid",
          workflow: %{
            "policy" => %{
              "tracker" => %{"active_states" => ["Todo"]},
              "review_judge" => %{"enabled" => true, "source_state" => "Human Review"}
            }
          }
        ),
        project("invalid-project", "invalid", error: "missing workflow"),
        project("disabled-project", "disabled", error: "operator disabled")
      ]
    }

    assert {:ok, result} =
             Tracker.fetch_candidates(registry, config(), client(name))

    assert [%{identifier: "CYC-1", project: %{"linear_project" => %{"id" => "valid-project"}}}] =
             result.issues

    assert Enum.map(result.skipped, & &1.reason) == ["missing workflow", "operator disabled"]

    assert_received %{
      "projectId" => "valid-project",
      "stateNames" => ["Todo", "Human Review"]
    }

    refute_received %{"projectId" => "invalid-project"}
    refute_received %{"projectId" => "disabled-project"}
  end

  test "fetch_candidates uses config active states when project policy does not override them" do
    name = unique_stub()
    parent = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(parent, Jason.decode!(body)["variables"])

      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      })
    end)

    registry = %ProjectRegistry{projects: [project("project-id", "active")]}

    assert {:ok, _result} = Tracker.fetch_candidates(registry, config(), client(name))

    assert_received %{
      "projectId" => "project-id",
      "stateNames" => ["Todo", "In Progress", "Rework"]
    }
  end

  test "sort_issues is deterministic by priority, creation time, and identifier" do
    issues = [
      %Cycle.Issue{id: "3", identifier: "CYC-3", priority: 3, created_at: "2026-05-22T03:00:00Z"},
      %Cycle.Issue{id: "1", identifier: "CYC-1", priority: 1, created_at: "2026-05-22T03:00:00Z"},
      %Cycle.Issue{id: "2", identifier: "CYC-2", priority: 1, created_at: "2026-05-22T02:00:00Z"}
    ]

    assert Enum.map(Tracker.sort_issues(issues), & &1.identifier) == ["CYC-2", "CYC-1", "CYC-3"]
  end

  defp client(name),
    do: Cycle.Linear.Client.new(token: "lin_test", req_options: [plug: {Req.Test, name}])

  defp config do
    %Config{
      linear: %{"active_states" => ["Todo", "In Progress", "Rework"]},
      review_judge: %{"enabled" => false, "source_state" => "Human Review"}
    }
  end

  defp project(id, status, opts \\ []) do
    %Project{
      linear_project: %{
        "id" => id,
        "name" => "Project #{id}",
        "slug" => String.upcase(id),
        "url" => "https://linear.app/example/project/#{id}"
      },
      namespace: "cycle",
      metadata_namespace: "cycle",
      repo: %{"url" => "https://github.com/OWNER/REPO.git", "full_name" => "OWNER/REPO"},
      workflow: Keyword.get(opts, :workflow, %{}),
      policy_profile: "default",
      status: status,
      error: Keyword.get(opts, :error)
    }
  end

  defp issue_node(id, identifier, priority, created_at, project_id) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => "Candidate",
      "url" => "https://linear.app/example/issue/#{identifier}",
      "branchName" => "codex/#{String.downcase(identifier)}",
      "priority" => priority,
      "priorityLabel" => "High",
      "createdAt" => created_at,
      "updatedAt" => created_at,
      "state" => %{"name" => "Todo", "type" => "unstarted"},
      "assignee" => %{"id" => "user-id", "name" => "Ada"},
      "labels" => %{"nodes" => [%{"name" => "scheduler"}]},
      "inverseRelations" => %{"nodes" => []},
      "project" => %{"id" => project_id},
      "team" => %{"id" => "team-id"}
    }
  end

  defp unique_stub, do: :"tracker-test-#{System.unique_integer([:positive])}"
end
