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
      assert result.dispatched == []
      assert_received {:review_routed, "AEA-200", "proceed_to_merging", "sha256:" <> _hash}
      assert_received {:scheduler_states, ["Todo", "In Progress"]}
    end)
  end

  test "project workflow cannot enable external review when operator flag is disabled" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_review_workflow!(checkout_path, external_review_enabled: true)
      stub_linear(name)
      parent = self()

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

      issue_lister = fn
        _client, "project-id", ["Human Review"], _opts ->
          {:ok, [client_issue(%{"state" => %{"name" => "Human Review", "type" => "started"}})]}

        _client, "project-id", _states, _opts ->
          {:ok, []}
      end

      review_router = fn issue, decision, opts ->
        send(parent, {:review_routed, issue.identifier, decision.decision, opts[:review_state]})

        %ReviewRouter.Result{
          status: :written,
          issue: issue,
          message: "review routed",
          details: %{"decision" => decision.decision}
        }
      end

      external_review_starter = fn _registry_path, job_id, _issue, _evidence, _policy, _opts ->
        send(parent, {:external_review_started, job_id})
        :ok
      end

      assert {:ok, result} =
               Reconciler.reconcile_once(config,
                 linear_client: client,
                 local_checkout_paths: [checkout_path],
                 issue_lister: issue_lister,
                 review_evidence_builder: &external_review_evidence/3,
                 review_judge_runner: __MODULE__.ProceedRunner,
                 review_router: review_router,
                 external_review_starter: external_review_starter,
                 engine_health_opts: [
                   dir?: fn _path -> false end,
                   executable?: fn _path -> false end
                 ],
                 now: ~U[2026-05-22 12:00:00Z]
               )

      assert [%ReviewRouter.Result{status: :written}] = result.review_results
      assert_received {:review_routed, "AEA-200", "proceed_to_merging", "Human Review"}
      refute_received {:external_review_started, _job_id}
    end)
  end

  test "external review starts asynchronously and completed findings route to rework" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_review_workflow!(checkout_path, active_states: ["Todo", "In Progress", "Rework"])
      stub_linear(name)
      parent = self()

      {:ok, config} =
        Cycle.Config.load(
          env: %{
            "CYCLE_HOME" => cycle_home,
            "LINEAR_API_KEY" => "lin_test",
            "CYCLE_REVIEW_EXTERNAL_ENABLED" => "true"
          },
          home: cycle_home
        )

      client =
        Client.new(
          token: "lin_test",
          req_options: Cycle.TestSupport.linear_graphql_req_options(name)
        )

      issue_lister = fn
        _client, "project-id", ["Human Review"], _opts ->
          {:ok, [client_issue(%{"state" => %{"name" => "Human Review", "type" => "started"}})]}

        _client, "project-id", _states, _opts ->
          {:ok, []}
      end

      review_router = fn issue, decision, opts ->
        send(
          parent,
          {:review_routed, issue.identifier, decision.decision, opts[:review_state],
           opts[:evidence_hash], Enum.map(decision.hard_stops, & &1.code)}
        )

        %ReviewRouter.Result{
          status: :written,
          issue: issue,
          message: "review routed",
          details: %{"decision" => decision.decision}
        }
      end

      external_review_starter = fn registry_path, job_id, issue, _evidence, _policy, opts ->
        send(parent, {:external_review_started, job_id})

        assert {:ok, _record} =
                 Cycle.ReviewJudgeRegistry.record(
                   registry_path,
                   external_review_record(job_id, issue),
                   now: opts[:now]
                 )

        :ok
      end

      common_opts = [
        linear_client: client,
        local_checkout_paths: [checkout_path],
        issue_lister: issue_lister,
        review_evidence_builder: &external_review_evidence/3,
        review_judge_runner: __MODULE__.ProceedRunner,
        review_router: review_router,
        external_review_starter: external_review_starter,
        engine_health_opts: [
          dir?: fn _path -> false end,
          executable?: fn _path -> false end
        ],
        now: ~U[2026-05-22 12:00:00Z]
      ]

      assert {:ok, first} = Reconciler.reconcile_once(config, common_opts)

      assert [%ReviewRouter.Result{status: :skipped, reason_code: "external_review_started"}] =
               first.review_results

      assert_received {:external_review_started, "external-review-AEA-200-" <> _suffix}
      refute_received {:review_routed, _, _, _, _, _}

      assert {:ok, second} = Reconciler.reconcile_once(config, common_opts)
      assert [%ReviewRouter.Result{status: :written}] = second.review_results

      assert_received {:review_routed, "AEA-200", "require_human_review", "Rework",
                       "sha256:" <> _hash, [:external_review_findings]}
    end)
  end

  test "external review findings fall back to human review when rework is not active" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_review_workflow!(checkout_path)
      stub_linear(name)
      parent = self()

      {:ok, config} =
        Cycle.Config.load(
          env: %{
            "CYCLE_HOME" => cycle_home,
            "LINEAR_API_KEY" => "lin_test",
            "CYCLE_REVIEW_EXTERNAL_ENABLED" => "true"
          },
          home: cycle_home
        )

      client =
        Client.new(
          token: "lin_test",
          req_options: Cycle.TestSupport.linear_graphql_req_options(name)
        )

      issue_lister = fn
        _client, "project-id", ["Human Review"], _opts ->
          {:ok, [client_issue(%{"state" => %{"name" => "Human Review", "type" => "started"}})]}

        _client, "project-id", _states, _opts ->
          {:ok, []}
      end

      review_router = fn issue, decision, opts ->
        send(parent, {:review_routed, issue.identifier, decision.decision, opts[:review_state]})

        %ReviewRouter.Result{
          status: :written,
          issue: issue,
          message: "review routed",
          details: %{"decision" => decision.decision}
        }
      end

      external_review_starter = fn registry_path, job_id, issue, _evidence, _policy, opts ->
        assert {:ok, _record} =
                 Cycle.ReviewJudgeRegistry.record(
                   registry_path,
                   external_review_record(job_id, issue),
                   now: opts[:now]
                 )

        :ok
      end

      common_opts = [
        linear_client: client,
        local_checkout_paths: [checkout_path],
        issue_lister: issue_lister,
        review_evidence_builder: &external_review_evidence/3,
        review_judge_runner: __MODULE__.ProceedRunner,
        review_router: review_router,
        external_review_starter: external_review_starter,
        engine_health_opts: [
          dir?: fn _path -> false end,
          executable?: fn _path -> false end
        ],
        now: ~U[2026-05-22 12:00:00Z]
      ]

      assert {:ok, first} = Reconciler.reconcile_once(config, common_opts)

      assert [%ReviewRouter.Result{status: :skipped, reason_code: "external_review_started"}] =
               first.review_results

      assert {:ok, second} = Reconciler.reconcile_once(config, common_opts)
      assert [%ReviewRouter.Result{status: :written}] = second.review_results

      assert_received {:review_routed, "AEA-200", "require_human_review", "Human Review"}
    end)
  end

  test "stale active external review forces human review" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_review_workflow!(checkout_path, active_states: ["Todo", "In Progress", "Rework"])
      stub_linear(name)
      parent = self()

      {:ok, config} =
        Cycle.Config.load(
          env: %{
            "CYCLE_HOME" => cycle_home,
            "LINEAR_API_KEY" => "lin_test",
            "CYCLE_REVIEW_EXTERNAL_ENABLED" => "true"
          },
          home: cycle_home
        )

      client =
        Client.new(
          token: "lin_test",
          req_options: Cycle.TestSupport.linear_graphql_req_options(name)
        )

      issue_lister = fn
        _client, "project-id", ["Human Review"], _opts ->
          {:ok, [client_issue(%{"state" => %{"name" => "Human Review", "type" => "started"}})]}

        _client, "project-id", _states, _opts ->
          {:ok, []}
      end

      review_router = fn issue, decision, opts ->
        send(
          parent,
          {:review_routed, issue.identifier, decision.decision, opts[:review_state],
           Enum.map(decision.hard_stops, & &1.code)}
        )

        %ReviewRouter.Result{
          status: :written,
          issue: issue,
          message: "review routed",
          details: %{"decision" => decision.decision}
        }
      end

      external_review_starter = fn _registry_path, job_id, _issue, _evidence, _policy, _opts ->
        send(parent, {:external_review_started, job_id})
        :ok
      end

      common_opts = [
        linear_client: client,
        local_checkout_paths: [checkout_path],
        issue_lister: issue_lister,
        review_evidence_builder: &external_review_evidence/3,
        review_judge_runner: __MODULE__.ProceedRunner,
        review_router: review_router,
        external_review_starter: external_review_starter,
        engine_health_opts: [
          dir?: fn _path -> false end,
          executable?: fn _path -> false end
        ]
      ]

      assert {:ok, first} =
               Reconciler.reconcile_once(
                 config,
                 Keyword.put(common_opts, :now, ~U[2026-05-22 12:00:00Z])
               )

      assert [%ReviewRouter.Result{status: :skipped, reason_code: "external_review_started"}] =
               first.review_results

      assert_received {:external_review_started, "external-review-AEA-200-" <> _suffix}

      assert {:ok, second} =
               Reconciler.reconcile_once(
                 config,
                 Keyword.put(common_opts, :now, ~U[2026-05-22 12:03:00Z])
               )

      assert [%ReviewRouter.Result{status: :written}] = second.review_results

      assert_received {:review_routed, "AEA-200", "require_human_review", "Human Review",
                       [:external_review_timeout]}

      refute_received {:external_review_started, _job_id}
    end)
  end

  test "failed external review record without summary forces human review" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_review_workflow!(checkout_path, active_states: ["Todo", "In Progress", "Rework"])
      stub_linear(name)
      parent = self()

      {:ok, config} =
        Cycle.Config.load(
          env: %{
            "CYCLE_HOME" => cycle_home,
            "LINEAR_API_KEY" => "lin_test",
            "CYCLE_REVIEW_EXTERNAL_ENABLED" => "true"
          },
          home: cycle_home
        )

      client =
        Client.new(
          token: "lin_test",
          req_options: Cycle.TestSupport.linear_graphql_req_options(name)
        )

      issue_lister = fn
        _client, "project-id", ["Human Review"], _opts ->
          {:ok, [client_issue(%{"state" => %{"name" => "Human Review", "type" => "started"}})]}

        _client, "project-id", _states, _opts ->
          {:ok, []}
      end

      review_router = fn issue, decision, opts ->
        send(
          parent,
          {:review_routed, issue.identifier, decision.decision, opts[:review_state],
           Enum.map(decision.hard_stops, & &1.code)}
        )

        %ReviewRouter.Result{
          status: :written,
          issue: issue,
          message: "review routed",
          details: %{"decision" => decision.decision}
        }
      end

      external_review_starter = fn registry_path, job_id, issue, _evidence, _policy, opts ->
        assert {:ok, _record} =
                 Cycle.ReviewJudgeRegistry.record(
                   registry_path,
                   failed_external_review_record(job_id, issue),
                   now: opts[:now]
                 )

        :ok
      end

      common_opts = [
        linear_client: client,
        local_checkout_paths: [checkout_path],
        issue_lister: issue_lister,
        review_evidence_builder: &external_review_evidence/3,
        review_judge_runner: __MODULE__.ProceedRunner,
        review_router: review_router,
        external_review_starter: external_review_starter,
        engine_health_opts: [
          dir?: fn _path -> false end,
          executable?: fn _path -> false end
        ],
        now: ~U[2026-05-22 12:00:00Z]
      ]

      assert {:ok, first} = Reconciler.reconcile_once(config, common_opts)

      assert [%ReviewRouter.Result{status: :skipped, reason_code: "external_review_started"}] =
               first.review_results

      assert {:ok, second} = Reconciler.reconcile_once(config, common_opts)
      assert [%ReviewRouter.Result{status: :written}] = second.review_results

      assert_received {:review_routed, "AEA-200", "require_human_review", "Human Review",
                       [:external_review_failed]}
    end)
  end

  test "wrong workspace git evidence forces human review before the runner is called" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_review_workflow!(checkout_path)
      stub_linear(name)
      parent = self()

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

      issue_lister = fn
        _client, "project-id", ["Human Review"], _opts ->
          {:ok, [client_issue(%{"state" => %{"name" => "Human Review", "type" => "started"}})]}

        _client, "project-id", _states, _opts ->
          {:ok, []}
      end

      review_router = fn issue, decision, opts ->
        send(
          parent,
          {:review_routed, issue.identifier, decision.decision,
           Enum.map(decision.hard_stops, & &1.code), opts[:evidence_hash]}
        )

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
                 review_evidence_builder: &wrong_workspace_review_evidence/3,
                 review_judge_runner: __MODULE__.UnexpectedRunner,
                 review_router: review_router,
                 engine_health_opts: [
                   dir?: fn _path -> false end,
                   executable?: fn _path -> false end
                 ],
                 now: ~U[2026-05-22 12:00:00Z]
               )

      assert [%ReviewRouter.Result{status: :written}] = result.review_results
      assert result.decisions == []

      assert_received {:review_routed, "AEA-200", "require_human_review", [:workspace_mismatch],
                       "sha256:" <> _hash}
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

  test "due retry uses project workflow active states" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = unique_stub()
      checkout_path = Path.join(cycle_home, "checkout")
      write_workflow!(checkout_path, active_states: ["Doing"])

      stub_linear(name,
        refresh_issue: linear_issue(%{"state" => %{"name" => "Doing", "type" => "started"}})
      )

      seed_retrying_run!(cycle_home)

      {:ok, config} =
        Cycle.Config.load(
          env: %{"CYCLE_HOME" => cycle_home, "LINEAR_API_KEY" => "lin_test"},
          home: cycle_home,
          workflow: %{"linear" => %{"active_states" => ["Todo"]}}
        )

      client =
        Client.new(
          token: "lin_test",
          req_options: Cycle.TestSupport.linear_graphql_req_options(name)
        )

      issue_lister = fn _client, _project_id, _states, _opts -> {:ok, []} end

      assert {:ok, result} =
               Reconciler.reconcile_once(config,
                 linear_client: client,
                 no_dispatch: true,
                 local_checkout_paths: [checkout_path],
                 issue_lister: issue_lister,
                 engine_health_opts: [
                   dir?: fn _path -> false end,
                   executable?: fn _path -> false end
                 ],
                 retry_base_delay_seconds: 30,
                 retry_max_delay_seconds: 60,
                 now: ~U[2026-05-22 12:00:00Z]
               )

      assert [%RunStore.Run{state: "retrying", retry: retry, last_event: event}] =
               result.recorded

      assert retry["attempt"] == 2
      assert event["type"] == "retry_scheduled"
      assert event["reason_code"] == "engine_unhealthy"
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

  defmodule UnexpectedRunner do
    @behaviour Cycle.Policy.ReviewJudge.Runner

    def run(_prompt, _model_config) do
      raise "review judge runner should not be called for hard-stop evidence"
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

  defp external_review_evidence(issue, _client, opts) do
    cycle_home = opts[:run_store_path] |> Path.dirname()
    workspace_path = Path.join([cycle_home, "workspaces", issue.identifier])
    File.mkdir_p!(workspace_path)

    evidence = %Evidence{
      issue: %{"id" => issue.id, "identifier" => issue.identifier, "title" => issue.title},
      labels: issue.labels || [],
      comments: [],
      workpad: nil,
      run: %{
        "id" => "run-id",
        "workspace_path" => workspace_path,
        "evidence" => [%{"type" => "validation", "status" => "passed"}]
      },
      git: %{
        "workspace_path" => workspace_path,
        "changed_files" => [],
        "has_changes" => false
      },
      workflow_policy_version: opts[:workflow_policy_version],
      global_policy_version: opts[:global_policy_version]
    }

    %{evidence | stable_hash_input: Cycle.Policy.ReviewEvidence.stable_hash_input(evidence)}
  end

  defp external_review_record(job_id, issue) do
    %{
      "id" => job_id,
      "issue" => %{"id" => issue.id, "identifier" => issue.identifier},
      "project" => %{"id" => "project-id", "name" => "Cycle Fixture"},
      "status" => "completed",
      "decision" => "require_human_review",
      "reason_code" => "external_review_findings",
      "message" => "external review found 1 actionable finding",
      "hard_stops" => [],
      "details" => %{
        "external_review" => %{
          "provider" => "clawpatch",
          "execution" => "local_workspace",
          "status" => "findings",
          "reason_code" => "external_review_findings",
          "message" => "external review found 1 actionable finding",
          "findings_count" => 1,
          "severity_breakdown" => %{"high" => 1},
          "artifact_path" => "/tmp/cycle/reviews/AEA-200.json",
          "fingerprint" => "sha256:" <> String.duplicate("a", 64)
        }
      }
    }
  end

  defp failed_external_review_record(job_id, issue) do
    %{
      "id" => job_id,
      "issue" => %{"id" => issue.id, "identifier" => issue.identifier},
      "project" => %{"id" => "project-id", "name" => "Cycle Fixture"},
      "status" => "failed",
      "decision" => "require_human_review",
      "reason_code" => "external_review_failed",
      "message" => "external review failed",
      "hard_stops" => [],
      "details" => %{}
    }
  end

  defp wrong_workspace_review_evidence(issue, _client, opts) do
    run_workspace_path =
      opts[:workspace_path] || Path.join(System.tmp_dir!(), "cycle-run-#{issue.identifier}")

    git_workspace_path = Path.join(Path.dirname(run_workspace_path), "wrong-#{issue.identifier}")

    evidence = %Evidence{
      issue: %{"id" => issue.id, "identifier" => issue.identifier, "title" => issue.title},
      labels: issue.labels || [],
      comments: [],
      workpad: nil,
      run: %{
        "id" => "run-id",
        "workspace_path" => run_workspace_path,
        "evidence" => [%{"type" => "validation", "status" => "passed"}]
      },
      git: %{
        "workspace_path" => git_workspace_path,
        "changed_files" => [],
        "has_changes" => false
      },
      workflow_policy_version: opts[:workflow_policy_version],
      global_policy_version: opts[:global_policy_version]
    }

    %{evidence | stable_hash_input: Cycle.Policy.ReviewEvidence.stable_hash_input(evidence)}
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

  defp write_workflow!(root, opts \\ []) do
    File.mkdir_p!(root)
    active_states = Keyword.get(opts, :active_states, ["Todo", "In Progress"])

    File.write!(Path.join(root, "WORKFLOW.md"), """
    ---
    agent:
      max_concurrent_agents: 2
    tracker:
      active_states:
    #{Enum.map_join(active_states, "\n", &"    - #{&1}")}
      terminal_states:
        - Done
    ---
    Fixture workflow.
    """)
  end

  defp write_review_workflow!(root, opts \\ []) do
    File.mkdir_p!(root)
    active_states = Keyword.get(opts, :active_states, ["Todo", "In Progress"])

    external_review =
      if Keyword.get(opts, :external_review_enabled),
        do: """
          external_review:
            enabled: true
        """,
        else: ""

    File.write!(Path.join(root, "WORKFLOW.md"), """
    ---
    agent:
      max_concurrent_agents: 2
    tracker:
      active_states:
    #{Enum.map_join(active_states, "\n", &"    - #{&1}")}
      terminal_states:
        - Done
    review_judge:
      enabled: true
      source_state: Human Review
      review_state: Human Review
      proceed_state: Merging
      policy: standard
      minimum_skip_confidence: medium
    #{external_review}
    ---
    Fixture workflow.
    """)
  end

  defp unique_stub, do: :"reconciler-test-#{System.unique_integer([:positive])}"
end
