defmodule Cycle.ReconcilerTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Cycle.Linear.Client
  alias Cycle.Reconciler
  alias Cycle.RunStore

  test "one-shot no-dispatch updates discovery and records queued scheduler decisions" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_workflow!(checkout_path)
      stub_linear(name)

      {:ok, config} =
        Cycle.Config.load(
          env: %{"CYCLE_HOME" => cycle_home, "LINEAR_API_KEY" => "lin_test"},
          home: cycle_home
        )

      client =
        Client.new(
          token: "lin_test",
          req_options: Cycle.TestSupport.linear_graphql_req_options(name)
        )

      assert {:ok, result} =
               Reconciler.reconcile_once(config,
                 linear_client: client,
                 no_dispatch: true,
                 local_checkout_paths: [checkout_path],
                 engine_health_opts: [
                   dir?: fn _path -> false end,
                   executable?: fn _path -> false end
                 ],
                 now: ~U[2026-05-22 12:00:00Z]
               )

      assert length(result.discovery.records) == 1
      assert [%{reason_code: "engine_unhealthy"}] = result.decisions

      assert [%RunStore.Run{state: "queued", last_event: %{"reason_code" => "engine_unhealthy"}}] =
               result.recorded

      assert {:ok, runs} = RunStore.load(Path.join(cycle_home, "runs.yaml"))
      assert [%RunStore.Run{issue: %{"identifier" => "AEA-200"}, state: "queued"}] = runs.runs

      assert {:ok, log_body} = File.read(Path.join([cycle_home, "logs", "cycle.log"]))
      assert log_body =~ "engine health check failed"
      assert log_body =~ "scheduler gate decision"
    end)
  end

  test "missing Linear auth fails before polling" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      {:ok, config} = Cycle.Config.load(env: %{"CYCLE_HOME" => cycle_home}, home: cycle_home)
      client = Client.new(token: nil, token_env: "LINEAR_API_KEY")

      assert Reconciler.reconcile_once(config, linear_client: client) ==
               {:error, {:auth, :missing_token, "LINEAR_API_KEY"}}
    end)
  end

  defp stub_linear(name) do
    Req.Test.stub(name, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = read_body(conn)
      query = Jason.decode!(body)["query"]

      cond do
        query =~ "CycleListProjects" ->
          Req.Test.json(conn, %{
            "data" => %{
              "projects" => %{
                "nodes" => [linear_project()],
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
              }
            }
          })

        query =~ "CycleListIssues" ->
          Req.Test.json(conn, %{
            "data" => %{
              "issues" => %{
                "nodes" => [linear_issue()],
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
              }
            }
          })

        query =~ "CycleRefreshIssue" ->
          Req.Test.json(conn, %{"data" => %{"issue" => linear_issue()}})
      end
    end)
  end

  defp linear_project do
    %{
      "id" => "project-id",
      "name" => "Cycle Fixture",
      "slugId" => "CYCLE",
      "url" => "https://linear.app/example/project/cycle",
      "description" => """
      cycle:
        enabled: true
        repo: https://github.com/OWNER/REPO.git
      """,
      "content" => nil
    }
  end

  defp linear_issue do
    %{
      "id" => "issue-id",
      "identifier" => "AEA-200",
      "title" => "Fixture issue",
      "url" => "https://linear.app/example/issue/AEA-200/fixture",
      "branchName" => "owner/fixture",
      "priority" => 3,
      "priorityLabel" => "Medium",
      "createdAt" => "2026-05-22T10:00:00Z",
      "updatedAt" => "2026-05-22T11:00:00Z",
      "state" => %{"name" => "Todo", "type" => "unstarted"},
      "assignee" => nil,
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []},
      "project" => %{"id" => "project-id"},
      "team" => %{"id" => "team-id"}
    }
  end

  defp write_workflow!(root) do
    File.mkdir_p!(root)

    File.write!(Path.join(root, "WORKFLOW.md"), """
    ---
    agent:
      max_concurrent_agents: 2
    tracker:
      active_states:
        - Todo
        - In Progress
      terminal_states:
        - Done
    ---
    Fixture workflow.
    """)
  end

  defp unique_stub, do: :"reconciler-test-#{System.unique_integer([:positive])}"
end
