defmodule Cycle.ReconcilerTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Cycle.Linear.Client
  alias Cycle.Policy.ReviewEvidence.Evidence
  alias Cycle.Policy.ReviewRouter
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

  test "one-shot routes review judge issues outside normal scheduling" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_review_workflow!(checkout_path)
      stub_linear(name)
      parent = self()

      {:ok, config} =
        Cycle.Config.load(
          env: %{"CYCLE_HOME" => cycle_home, "LINEAR_API_KEY" => "lin_test"},
          home: cycle_home,
          workflow: %{
            "policy" => %{
              "required" => %{"agent" => %{"max_concurrent_agents" => 3}}
            }
          }
        )

      client =
        Client.new(
          token: "lin_test",
          req_options: Cycle.TestSupport.linear_graphql_req_options(name)
        )

      issue_lister = fn
        _client, "project-id", ["Human Review"], _opts ->
          {:ok, [client_issue(%{"state" => %{"name" => "Human Review", "type" => "started"}})]}

        _client, "project-id", states, _opts ->
          send(parent, {:scheduler_states, states})
          {:ok, []}
      end

      review_router = fn issue, decision, opts ->
        send(parent, {:review_routed, issue.identifier, decision.decision, opts[:evidence_hash]})

        %ReviewRouter.Result{
          status: :written,
          issue: issue,
          message: "review routed",
          details: %{"decision" => decision.decision}
        }
      end

      assert {:ok, result} =
               Reconciler.reconcile_once(config,
                 linear_client: client,
                 local_checkout_paths: [checkout_path],
                 issue_lister: issue_lister,
                 review_evidence_builder: &review_evidence/3,
                 review_judge_runner: __MODULE__.ProceedRunner,
                 review_router: review_router,
                 engine_health_opts: [
                   dir?: fn _path -> false end,
                   executable?: fn _path -> false end
                 ],
                 now: ~U[2026-05-22 12:00:00Z]
               )

      assert [%ReviewRouter.Result{status: :written}] = result.review_results
      assert [%{status: "drift"}] = result.discovery.records
      assert result.decisions == []
      assert_received {:review_routed, "AEA-200", "proceed_to_merging", "sha256:" <> _hash}
      assert_received {:scheduler_states, ["Todo", "In Progress"]}
    end)
  end

  test "due retry refreshes issue state and stores the next retry time for transient gates" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_workflow!(checkout_path)
      stub_linear(name)
      seed_retrying_run!(cycle_home)

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
                 retry_base_delay_seconds: 30,
                 retry_max_delay_seconds: 60,
                 now: ~U[2026-05-22 12:00:00Z]
               )

      assert [%RunStore.Run{state: "retrying", retry: retry, last_event: event} | _] =
               result.recorded

      assert retry["attempt"] == 2
      assert retry["next_retry_at"] == "2026-05-22T12:01:00Z"
      assert event["type"] == "retry_scheduled"
      assert event["reason_code"] == "engine_unhealthy"
    end)
  end

  test "terminal refreshed issue suppresses a due retry as stale" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_workflow!(checkout_path)

      stub_linear(name,
        refresh_issue: linear_issue(%{"state" => %{"name" => "Done", "type" => "completed"}})
      )

      seed_retrying_run!(cycle_home)

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

      assert [%RunStore.Run{state: "stale", last_event: event} | _] = result.recorded
      assert event["type"] == "retry_suppressed"
      assert event["reason_code"] == "issue_terminal"
    end)
  end

  test "invalid workflow suppresses a due retry as stale" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      File.mkdir_p!(checkout_path)
      File.write!(Path.join(checkout_path, "WORKFLOW.md"), "# Missing front matter\n")
      stub_linear(name)
      seed_retrying_run!(cycle_home)

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

      assert [%RunStore.Run{state: "stale", last_event: event} | _] = result.recorded
      assert event["reason_code"] == "workflow_invalid"
    end)
  end

  defp stub_linear(name, opts \\ []) do
    refreshed_issue = Keyword.get(opts, :refresh_issue, linear_issue())

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
          Req.Test.json(conn, %{"data" => %{"issue" => refreshed_issue}})
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

  defp linear_issue(overrides \\ %{}) do
    Map.merge(
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
      },
      overrides
    )
  end

  defp client_issue(overrides) do
    issue = linear_issue(overrides)

    %Client.Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      url: issue["url"],
      state: get_in(issue, ["state", "name"]),
      state_type: get_in(issue, ["state", "type"]),
      branch_name: issue["branchName"],
      assignee_id: get_in(issue, ["assignee", "id"]),
      assignee_name: get_in(issue, ["assignee", "name"]),
      assignee_email: get_in(issue, ["assignee", "email"]),
      labels: [],
      blocks: [],
      priority: issue["priority"],
      priority_label: issue["priorityLabel"],
      created_at: issue["createdAt"],
      updated_at: issue["updatedAt"],
      project_id: get_in(issue, ["project", "id"]),
      team_id: get_in(issue, ["team", "id"])
    }
  end

  defmodule ProceedRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config) do
      {:ok,
       %{
         "decision" => "proceed_to_merging",
         "confidence" => "high",
         "reason" => "Validated.",
         "evidence" => ["tests passed"]
       }}
    end
  end

  defp review_evidence(issue, _client, opts) do
    %Evidence{
      issue: %{"id" => issue.id, "identifier" => issue.identifier, "title" => issue.title},
      labels: issue.labels || [],
      comments: [],
      workpad: nil,
      run: %{"id" => "run-id", "evidence" => [%{"type" => "validation", "status" => "passed"}]},
      git: %{"changed_files" => [], "has_changes" => false},
      workflow_policy_version: opts[:workflow_policy_version],
      global_policy_version: opts[:global_policy_version],
      stable_hash_input: %{"issue" => %{"identifier" => issue.identifier}}
    }
  end

  defp seed_retrying_run!(cycle_home) do
    path = Path.join(cycle_home, "runs.yaml")

    assert {:ok, run} =
             RunStore.create_queued(
               path,
               %{
                 "id" => "run-1",
                 "issue" => %{
                   "id" => "issue-id",
                   "identifier" => "AEA-200",
                   "title" => "Fixture issue",
                   "state" => "Todo",
                   "url" => "https://linear.app/example/issue/AEA-200/fixture"
                 },
                 "project" => %{"id" => "project-id", "name" => "Cycle Fixture"},
                 "engine" => %{"id" => "openai-symphony@main", "name" => "openai-symphony"},
                 "workflow_path" => "WORKFLOW.md",
                 "workflow_hash" => "sha256:abc123",
                 "workspace_path" => Path.join(cycle_home, "workspaces/AEA-200"),
                 "retry" => %{
                   "attempt" => 1,
                   "max_attempts" => 3,
                   "next_retry_at" => "2026-05-22T11:59:00Z"
                 }
               },
               now: "2026-05-22T11:50:00Z"
             )

    assert {:ok, _running} =
             RunStore.transition(path, run.id, "running", %{}, now: "2026-05-22T11:51:00Z")

    assert {:ok, _retrying} =
             RunStore.transition(path, run.id, "retrying", %{}, now: "2026-05-22T11:52:00Z")
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

  defp write_review_workflow!(root) do
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
    review_judge:
      enabled: true
      source_state: Human Review
      review_state: Human Review
      proceed_state: Merging
      policy: standard
      minimum_skip_confidence: medium
    ---
    Fixture workflow.
    """)
  end

  defp unique_stub, do: :"reconciler-test-#{System.unique_integer([:positive])}"
end
