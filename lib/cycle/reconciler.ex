defmodule Cycle.Reconciler do
  @moduledoc """
  Foreground Cycle control loop for discovery, validation, scheduling, and run
  registry updates.
  """

  alias Cycle.Engine.Health
  alias Cycle.EngineRegistry
  alias Cycle.GlobalPolicy
  alias Cycle.Issue
  alias Cycle.Linear.Client
  alias Cycle.ProjectDiscovery
  alias Cycle.RunStore
  alias Cycle.Scheduler

  defmodule Result do
    @moduledoc false
    defstruct [
      :discovery,
      :engine_registry,
      :run_store,
      engine_health: [],
      issues: [],
      decisions: [],
      recorded: [],
      dispatched: []
    ]
  end

  @default_limit 100

  @spec start(Cycle.Config.t(), keyword()) :: :ok | {:ok, Result.t()} | {:error, term()}
  def start(config, opts \\ []) do
    logger = Keyword.get(opts, :logger, &default_log/1)
    :ok = Cycle.Log.configure(config)

    cond do
      Keyword.get(opts, :dry_run, false) ->
        dry_run(config, opts, logger)

      Keyword.get(opts, :once, false) ->
        reconcile_once(config, opts)

      true ->
        loop(config, opts, logger)
    end
  end

  @spec reconcile_once(Cycle.Config.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def reconcile_once(config, opts \\ []) do
    :ok = Cycle.Log.configure(config)
    client = Keyword.get_lazy(opts, :linear_client, fn -> Client.new(config) end)
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)

    with :ok <- require_linear_auth(config, client),
         {:ok, global_policy} <- GlobalPolicy.from_config(config),
         {:ok, discovery} <- discover(config, client, global_policy, now, opts),
         {:ok, engine_registry} <- load_engine_registry(config, opts),
         {:ok, run_store} <- RunStore.load(run_store_path(config)),
         {:ok, retry_outcome} <-
           reconcile_retries(
             config,
             run_store,
             discovery.records,
             engine_registry,
             client,
             now,
             opts
           ),
         {:ok, run_store} <- RunStore.load(run_store_path(config)),
         {:ok, issues} <- list_candidate_issues(config, client, discovery.records, opts),
         decisions <- decide(config, issues, engine_registry, run_store, client, opts),
         {:ok, outcome} <- apply_decisions(config, decisions, opts) do
      {:ok,
       %Result{
         discovery: discovery,
         engine_registry: engine_registry,
         run_store: run_store,
         engine_health: Enum.map(engine_registry.engines, & &1.health),
         issues: issues,
         decisions: decisions,
         recorded: retry_outcome.recorded ++ outcome.recorded,
         dispatched: outcome.dispatched
       }}
    end
  end

  defp dry_run(config, opts, logger) do
    interval = polling_interval(config)
    dispatch? = Keyword.get(opts, :no_dispatch, false) != true

    logger.("cycle start dry-run")
    logger.("  project registry: #{config.projects["registry_path"]}")
    logger.("  engine registry: #{config.engines["registry_path"]}")
    logger.("  run registry: #{run_store_path(config)}")
    logger.("  polling interval: #{interval}ms")
    logger.("  dispatch: #{dispatch?}")
    :ok
  end

  defp loop(config, opts, logger) do
    interval = polling_interval(config)
    logger.("cycle start foreground loop started; polling every #{interval}ms")

    Stream.repeatedly(fn ->
      case reconcile_once(config, opts) do
        {:ok, result} ->
          log_result(result, logger)
          :timer.sleep(interval)
          :ok

        {:error, reason} ->
          logger.("cycle reconcile failed: #{format_error(reason)}")
          :timer.sleep(interval)
          :ok
      end
    end)
    |> Enum.reduce(:ok, fn :ok, :ok -> :ok end)
  catch
    :exit, {:shutdown, _} -> :ok
  end

  defp discover(config, client, global_policy, now, opts) do
    ProjectDiscovery.discover(client,
      limit: Keyword.get(opts, :project_limit, @default_limit),
      registry_path: config.projects["registry_path"],
      global_policy: global_policy,
      now: now,
      workflow_resolver: [
        cache_root: config.projects["workflow_cache_path"],
        local_checkout_roots: Keyword.get(opts, :local_checkout_roots, [File.cwd!()]),
        local_checkout_paths: Keyword.get(opts, :local_checkout_paths, [])
      ]
    )
  end

  defp load_engine_registry(config, opts) do
    default_engine = default_engine(config)
    registry_path = config.engines["registry_path"]

    registry =
      case EngineRegistry.read(registry_path) do
        {:ok, %EngineRegistry{engines: []} = registry} ->
          EngineRegistry.upsert(registry, default_engine)

        {:ok, registry} ->
          if Enum.any?(registry.engines, &(&1.id == default_engine.id)) do
            registry
          else
            EngineRegistry.upsert(registry, default_engine)
          end

        {:error, _reason} ->
          %EngineRegistry{engines: [default_engine]}
      end

    refreshed =
      %{registry | engines: Enum.map(registry.engines, &refresh_engine_health(&1, opts))}

    Enum.each(refreshed.engines, &log_engine_health(config, &1))

    with :ok <- EngineRegistry.write(registry_path, refreshed), do: {:ok, refreshed}
  end

  defp refresh_engine_health(engine, opts) do
    %{engine | health: Health.check(engine, Keyword.get(opts, :engine_health_opts, []))}
  end

  defp log_engine_health(config, engine) do
    if get_in(engine.health || %{}, ["state"]) not in ["healthy", nil] do
      Cycle.Log.log_event(config, :warning, "engine health check failed", %{
        "engine_id" => engine.id,
        "state" => get_in(engine.health || %{}, ["state"]),
        "reason" => get_in(engine.health || %{}, ["reason"]),
        "path" => get_in(engine.health || %{}, ["path"])
      })
    end
  end

  defp list_candidate_issues(config, client, projects, opts) do
    active_states = get_in(config.linear, ["active_states"]) || []
    issue_lister = Keyword.get(opts, :issue_lister, &Client.list_issues/4)

    projects
    |> Enum.reject(&(&1.status == "invalid"))
    |> Enum.reduce_while({:ok, []}, fn project, {:ok, acc} ->
      project_id = get_in(project.linear_project, ["id"])

      case issue_lister.(client, project_id, active_states, []) do
        {:ok, issues} ->
          normalized = Enum.map(issues, &Issue.from_linear(&1, project))
          {:cont, {:ok, acc ++ normalized}}

        {:error, reason} ->
          Cycle.Log.log_event(config, :error, "discovery issue listing failed", %{
            "project_id" => project_id,
            "project" => get_in(project.linear_project || %{}, ["name"]),
            "error" => inspect(reason)
          })

          {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_retries(config, run_store, projects, engine_registry, client, now, opts) do
    run_store.runs
    |> Enum.filter(&due_retry?(&1, now))
    |> Enum.reduce_while({:ok, %{recorded: []}}, fn run, {:ok, acc} ->
      case reconcile_retry(config, run, run_store, projects, engine_registry, client, now, opts) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, updated} -> {:cont, {:ok, %{acc | recorded: acc.recorded ++ [updated]}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp due_retry?(%RunStore.Run{state: "retrying", retry: retry}, now) when is_map(retry) do
    case retry["next_retry_at"] do
      nil -> true
      timestamp -> compare_timestamp(timestamp, now) != :gt
    end
  end

  defp due_retry?(_run, _now), do: false

  defp reconcile_retry(config, run, run_store, projects, engine_registry, client, now, opts) do
    with {:ok, project} <- retry_project(run, projects),
         {:ok, issue} <- retry_issue(run, project, client) do
      retry_decision(config, run, issue, run_store, engine_registry, now, opts)
    else
      {:suppress, reason, message} -> suppress_retry(config, run, reason, message, now)
      {:reschedule, reason, message} -> reschedule_retry(config, run, reason, message, now, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_project(run, projects) do
    project_id = get_in(run.project || %{}, ["id"])

    project =
      Enum.find(projects, fn project ->
        get_in(project.linear_project || %{}, ["id"]) == project_id ||
          get_in(project.linear_project || %{}, ["name"]) == project_id
      end)

    case project do
      nil ->
        {:suppress, "project_missing", "project is no longer discovered"}

      %{status: "disabled"} ->
        {:suppress, "project_disabled", "project is disabled"}

      %{status: "invalid", error: error} ->
        {:suppress, "workflow_invalid", error || "project workflow is invalid"}

      project ->
        {:ok, project}
    end
  end

  defp retry_issue(run, project, client) do
    issue = issue_from_run(run, project)

    case Client.refresh_issue(client, issue.id) do
      {:ok, nil} -> {:suppress, "issue_not_visible", "issue is no longer visible in Linear"}
      {:ok, refreshed} -> {:ok, Issue.from_linear(refreshed, project)}
      {:error, reason} -> {:reschedule, "issue_refresh_failed", inspect(reason)}
    end
  end

  defp retry_decision(config, run, issue, run_store, engine_registry, now, opts) do
    runs = Enum.reject(run_store.runs, &(&1.id == run.id))

    decision =
      Scheduler.decide([issue],
        active_states: get_in(config.linear, ["active_states"]) || [],
        terminal_states: get_in(config.linear, ["terminal_states"]) || [],
        default_engine_id: get_in(config.engines, ["default"]),
        engine_registry: engine_registry,
        run_store: %{run_store | runs: runs},
        global_capacity: get_in(config.scheduler, ["max_concurrent_runs"]),
        budget_mode: get_in(config.scheduler, ["budget", "mode"]) || "warn",
        worker_host: hostname(),
        refresh_issue: nil,
        now: now
      )
      |> List.first()

    case decision do
      %Scheduler.Decision{status: :dispatch} ->
        ready_retry(config, run, decision, now)

      %Scheduler.Decision{reason_code: reason, message: message}
      when reason in [
             "issue_terminal",
             "issue_state_inactive",
             "workflow_invalid",
             "engine_unavailable"
           ] ->
        suppress_retry(config, run, reason, message, now)

      %Scheduler.Decision{reason_code: reason, message: message} ->
        reschedule_retry(
          config,
          run,
          reason || "retry_gate_delayed",
          message || "retry delayed",
          now,
          opts
        )
    end
  end

  defp ready_retry(config, run, decision, now) do
    RunStore.transition(
      run_store_path(config),
      run.id,
      "queued",
      %{
        "last_event" => %{
          "type" => "retry_ready",
          "reason_code" => "retry_ready",
          "message" => "retry gates passed; run queued",
          "scheduler_status" => Atom.to_string(decision.status)
        }
      },
      now: now
    )
  end

  defp suppress_retry(config, run, reason, message, now) do
    RunStore.transition(
      run_store_path(config),
      run.id,
      "stale",
      %{
        "last_event" => %{
          "type" => "retry_suppressed",
          "reason_code" => reason,
          "message" => message
        }
      },
      now: now
    )
  end

  defp reschedule_retry(config, run, reason, message, now, opts) do
    RunStore.schedule_retry(run_store_path(config), run.id, reason,
      now: now,
      message: message,
      base_delay_seconds: Keyword.get(opts, :retry_base_delay_seconds, 60),
      max_delay_seconds: Keyword.get(opts, :retry_max_delay_seconds, 900),
      max_attempts: Keyword.get(opts, :retry_max_attempts, 3)
    )
  end

  defp decide(config, issues, engine_registry, run_store, client, opts) do
    decisions =
      Scheduler.decide(issues,
        active_states: get_in(config.linear, ["active_states"]) || [],
        terminal_states: get_in(config.linear, ["terminal_states"]) || [],
        default_engine_id: get_in(config.engines, ["default"]),
        engine_registry: engine_registry,
        run_store: run_store,
        global_capacity: get_in(config.scheduler, ["max_concurrent_runs"]),
        budget_mode: get_in(config.scheduler, ["budget", "mode"]) || "warn",
        worker_host: hostname(),
        refresh_issue: Keyword.get(opts, :refresh_issue, &Client.refresh_issue(client, &1.id))
      )

    Enum.each(decisions, &log_scheduler_decision(config, &1))
    decisions
  end

  defp log_scheduler_decision(config, decision) do
    if decision.status != :dispatch do
      Cycle.Log.log_event(config, :info, "scheduler gate decision", %{
        "issue" => decision.issue.identifier || decision.issue.id,
        "status" => Atom.to_string(decision.status),
        "reason_code" => decision.reason_code,
        "message" => decision.message,
        "details" => decision.details
      })
    end
  end

  defp apply_decisions(config, decisions, opts) do
    Enum.reduce_while(decisions, {:ok, %{recorded: [], dispatched: []}}, fn decision,
                                                                            {:ok, acc} ->
      case apply_decision(config, decision, opts) do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, {:recorded, run}} ->
          {:cont, {:ok, %{acc | recorded: acc.recorded ++ [run]}}}

        {:ok, {:dispatched, run}} ->
          {:cont, {:ok, %{acc | dispatched: acc.dispatched ++ [run]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_decision(_config, %Scheduler.Decision{status: status}, _opts)
       when status in [:skipped, :retry_later],
       do: {:ok, nil}

  defp apply_decision(config, %Scheduler.Decision{status: :blocked} = decision, opts) do
    with {:ok, run} <- create_queued_run(config, decision, opts),
         {:ok, blocked} <-
           RunStore.transition(run_store_path(config), run.id, "blocked", %{
             "last_event" => decision_event(decision, "blocked")
           }) do
      {:ok, {:recorded, blocked}}
    end
  end

  defp apply_decision(config, %Scheduler.Decision{status: :queued} = decision, opts) do
    with {:ok, run} <- create_queued_run(config, decision, opts) do
      {:ok, {:recorded, run}}
    end
  end

  defp apply_decision(config, %Scheduler.Decision{status: :dispatch} = decision, opts) do
    if Keyword.get(opts, :no_dispatch, false) do
      queued = %{
        decision
        | status: :queued,
          reason_code: "no_dispatch",
          message: "dispatch disabled by --no-dispatch"
      }

      apply_decision(config, queued, opts)
    else
      adapter = Keyword.get(opts, :engine_adapter, Cycle.Engine.Symphony)
      request = dispatch_request(config, decision)

      case Scheduler.dispatch_or_queue(adapter, decision.engine, request, opts) do
        {:running, status} ->
          {:ok, {:dispatched, Map.put(status, "request", request)}}

        {:queued, error} ->
          Cycle.Log.log_event(config, :error, "engine dispatch failed or queued", %{
            "issue" => decision.issue.identifier || decision.issue.id,
            "engine_id" => decision.engine.id,
            "error" => error
          })

          queued = %{
            decision
            | status: :queued,
              reason_code: error["code"] || "engine_dispatch_queued",
              message: error["message"] || "engine dispatch queued"
          }

          apply_decision(config, queued, opts)
      end
    end
  end

  defp create_queued_run(config, decision, opts) do
    RunStore.create_queued(run_store_path(config), run_attrs(config, decision),
      now: Keyword.get(opts, :now)
    )
  end

  defp run_attrs(config, decision) do
    %{
      "issue" => issue_map(decision.issue),
      "project" => project_map(decision.issue.project),
      "engine" => engine_map(decision.engine),
      "workflow_path" => get_in(decision.issue.project, ["workflow", "path"]) || "WORKFLOW.md",
      "workflow_hash" => get_in(decision.issue.project, ["workflow", "hash"]) || "unknown",
      "workspace_path" => workspace_path(config, decision.issue),
      "last_event" => decision_event(decision, "queued")
    }
  end

  defp dispatch_request(config, decision) do
    %{
      "issue" => issue_map(decision.issue),
      "project" => project_map(decision.issue.project),
      "engine" => engine_map(decision.engine),
      "workflow_path" => get_in(decision.issue.project, ["workflow", "path"]) || "WORKFLOW.md",
      "workspace_path" => workspace_path(config, decision.issue)
    }
  end

  defp decision_event(decision, state) do
    %{
      "type" => "scheduler_decision",
      "state" => state,
      "status" => Atom.to_string(decision.status),
      "reason_code" => decision.reason_code,
      "message" => decision.message,
      "summary" =>
        String.trim("#{decision.reason_code || decision.status} #{decision.message || ""}")
    }
  end

  defp issue_map(issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "state" => issue.state,
      "url" => issue.url
    }
  end

  defp issue_from_run(run, project) do
    issue = run.issue || %{}

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      state: issue["state"],
      url: issue["url"],
      project: %{
        "linear_project" => project.linear_project,
        "namespace" => project.namespace,
        "metadata_namespace" => project.metadata_namespace,
        "repo" => project.repo,
        "workflow" => project.workflow,
        "allowed_engines" => project.allowed_engines,
        "policy_profile" => project.policy_profile,
        "capacity" => project.capacity,
        "status" => project.status,
        "error" => project.error,
        "policy_drift" => project.policy_drift
      }
    }
  end

  defp project_map(project) when is_map(project) do
    linear_project = project["linear_project"] || %{}

    %{
      "id" => linear_project["id"] || project["id"] || project["name"] || "unknown",
      "name" => linear_project["name"] || project["name"] || "unknown",
      "repo" => project["repo"] || %{}
    }
  end

  defp engine_map(nil), do: %{"id" => "none", "name" => "none"}

  defp engine_map(engine) do
    %{"id" => engine.id, "name" => engine.name, "ref" => engine.ref}
  end

  defp workspace_path(config, issue) do
    Path.join([config.paths.state_dir, "workspaces", issue.identifier || issue.id || "unknown"])
  end

  defp default_engine(config) do
    config.engines
    |> Map.get("default", "openai-symphony@main")
    |> Cycle.EngineId.parse()
    |> case do
      {:ok, engine_id} ->
        EngineRegistry.default_record(config, engine_id)

      {:error, _reason} ->
        EngineRegistry.default_record(config, %{
          name: "openai-symphony",
          ref: "main",
          id: "openai-symphony@main"
        })
    end
  end

  defp require_linear_auth(config, %Client{token: token, token_env: token_env}) do
    env = token_env || get_in(config.linear, ["api_key_env"]) || "LINEAR_API_KEY"

    if is_binary(token) and token != "",
      do: :ok,
      else: {:error, {:auth, :missing_token, env}}
  end

  defp run_store_path(config), do: Path.join(config.paths.state_dir, "runs.yaml")
  defp polling_interval(config), do: get_in(config.polling, ["interval_ms"]) || 30_000

  defp compare_timestamp(timestamp, %DateTime{} = now) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, 0} -> DateTime.compare(datetime, now)
      _ -> :lt
    end
  end

  defp compare_timestamp(timestamp, now) when is_binary(now) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(now) do
      compare_timestamp(timestamp, datetime)
    else
      _ -> :lt
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      {:error, _reason} -> "unknown"
    end
  end

  defp log_result(result, logger) do
    logger.(
      "cycle reconcile ok: projects=#{length(result.discovery.records)} issues=#{length(result.issues)} decisions=#{length(result.decisions)} recorded=#{length(result.recorded)} dispatched=#{length(result.dispatched)}"
    )

    Enum.each(result.engine_health, fn health ->
      logger.("  engine health: #{health["state"]} #{health["reason"] || health["path"] || ""}")
    end)
  end

  defp default_log(message), do: IO.puts(message)
  defp format_error({:auth, :missing_token, env}), do: "#{env} is not configured"
  defp format_error(reason), do: inspect(reason)
end
