defmodule Cycle.Scheduler do
  @moduledoc """
  Scheduler gates and engine dispatch helpers.

  The scheduler evaluates every candidate independently and returns stable
  decision records that can power status output before an execution adapter is
  ready to run issues.
  """

  alias Cycle.Issue
  alias Cycle.Linear.Client
  alias Cycle.EngineRegistry
  alias Cycle.EngineRegistry.Engine
  alias Cycle.RunStore
  alias Cycle.RunStore.Run

  @active_run_states ["queued", "running", "retrying", "judging"]
  @dispatch_statuses [:dispatch, :queued, :blocked, :skipped, :retry_later]
  @default_terminal_state_types ["completed", "canceled"]

  defmodule Decision do
    @moduledoc false
    @enforce_keys [:status, :issue]
    defstruct [:status, :issue, :engine, :reason_code, :message, details: %{}]
  end

  @type decision_status :: :dispatch | :queued | :blocked | :skipped | :retry_later
  @type reason_code :: String.t() | nil
  @type decision :: %Decision{
          status: decision_status(),
          issue: Issue.t(),
          engine: Engine.t() | nil,
          reason_code: reason_code(),
          message: String.t() | nil,
          details: map()
        }

  @spec decide([Issue.t()], keyword()) :: [decision()]
  def decide(candidates, opts \\ []) when is_list(candidates) do
    context = context(opts)

    candidates
    |> Enum.map(&decide_candidate(&1, context))
    |> allocate_capacity(context)
  end

  @spec active_run_states :: [String.t()]
  def active_run_states, do: @active_run_states

  @spec dispatch_supported?(module(), EngineRegistry.Engine.t()) :: boolean()
  def dispatch_supported?(adapter, %EngineRegistry.Engine{} = engine) do
    Cycle.Engine.Adapter.dispatch_supported?(adapter, engine)
  end

  @spec dispatch_or_queue(module(), EngineRegistry.Engine.t(), map(), keyword()) ::
          {:running, map()} | {:queued, map()}
  def dispatch_or_queue(adapter, %EngineRegistry.Engine{} = engine, request, opts \\ []) do
    if dispatch_supported?(adapter, engine) do
      case adapter.dispatch(engine, request, opts) do
        {:ok, run_status} ->
          {:running, run_status}

        {:error, %{"code" => "engine_dispatch_unsupported"} = error} ->
          {:queued, error}

        {:error, error} ->
          {:queued, error}
      end
    else
      {:queued,
       %{
         "code" => "engine_dispatch_unsupported",
         "message" => "selected engine adapter does not support single-issue dispatch"
       }}
    end
  end

  defp context(opts) do
    %{
      active_states: Keyword.get(opts, :active_states, []),
      terminal_states: Keyword.get(opts, :terminal_states, []),
      terminal_state_types:
        Keyword.get(opts, :terminal_state_types, @default_terminal_state_types),
      default_engine_id: Keyword.get(opts, :default_engine_id),
      engines: engines(opts),
      runs: runs(opts),
      global_capacity: Keyword.get(opts, :global_capacity),
      worker_host_capacity: Keyword.get(opts, :worker_host_capacity),
      worker_host: Keyword.get(opts, :worker_host),
      pressure: pressure_state(opts),
      now: Keyword.get(opts, :now),
      refresh_issue: Keyword.get(opts, :refresh_issue)
    }
  end

  defp engines(opts) do
    case Keyword.get(opts, :engines) || Keyword.get(opts, :engine_registry) do
      %EngineRegistry{} = registry -> registry.engines
      engines when is_list(engines) -> engines
      nil -> []
    end
  end

  defp runs(opts) do
    case Keyword.get(opts, :runs) || Keyword.get(opts, :run_store) do
      %RunStore{} = registry -> registry.runs
      runs when is_list(runs) -> runs
      nil -> []
    end
  end

  defp decide_candidate(%Issue{} = issue, context) do
    issue
    |> stale_refresh(context)
    |> case do
      {:ok, refreshed} ->
        evaluate(refreshed, context)

      {:error, reason} ->
        retry_later(
          issue,
          "issue_refresh_failed",
          "issue could not be refreshed before dispatch",
          %{error: inspect(reason)}
        )
    end
  end

  defp stale_refresh(%Issue{} = issue, %{refresh_issue: nil}), do: {:ok, issue}

  defp stale_refresh(%Issue{} = issue, %{refresh_issue: refresh_issue})
       when is_function(refresh_issue, 1) do
    case refresh_issue.(issue) do
      {:ok, nil} -> {:ok, %{issue | id: nil}}
      {:ok, refreshed} -> {:ok, normalize_refreshed_issue(refreshed, issue)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stale_refresh(%Issue{} = issue, %{refresh_issue: refresh_issue})
       when is_function(refresh_issue, 2) do
    case refresh_issue.(issue.id, issue) do
      {:ok, nil} -> {:ok, %{issue | id: nil}}
      {:ok, refreshed} -> {:ok, normalize_refreshed_issue(refreshed, issue)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_refreshed_issue(%Issue{} = refreshed, %Issue{} = original) do
    if is_map(refreshed.project), do: refreshed, else: %{refreshed | project: original.project}
  end

  defp normalize_refreshed_issue(%Client.Issue{} = refreshed, %Issue{} = original) do
    %Issue{
      id: refreshed.id,
      identifier: refreshed.identifier,
      title: refreshed.title,
      state: refreshed.state,
      state_type: refreshed.state_type,
      url: refreshed.url,
      branch: refreshed.branch_name,
      assignee: assignee(refreshed),
      labels: refreshed.labels || [],
      blockers: refreshed.blocks || [],
      priority: refreshed.priority,
      priority_label: refreshed.priority_label,
      created_at: refreshed.created_at,
      updated_at: refreshed.updated_at,
      project: original.project
    }
  end

  defp evaluate(%Issue{} = issue, context) do
    cond do
      blank?(issue.id) ->
        retry_later(issue, "issue_not_visible", "issue is no longer visible in Linear")

      terminal_issue?(issue, context) ->
        skipped(issue, "issue_terminal", "issue is in a terminal state")

      not active_issue?(issue, context) ->
        skipped(issue, "issue_state_inactive", "issue is not in an active scheduler state")

      unresolved_blockers?(issue, context) ->
        blocked(issue, "linear_blocked", "issue has unresolved Linear blockers")

      active_run = active_run_for_issue(issue, context.runs) ->
        run_decision(issue, active_run)

      project_status(issue) == "disabled" ->
        skipped(issue, "project_disabled", "project is disabled")

      project_status(issue) == "invalid" ->
        blocked(issue, "workflow_invalid", "project workflow is invalid")

      policy_blocks?(issue) ->
        blocked(issue, "policy_drift_blocked", "project workflow drift blocks dispatch")

      true ->
        select_engine(issue, context)
        |> case do
          {:ok, engine} -> engine_decision(issue, engine)
          {:error, decision} -> decision
        end
    end
  end

  defp engine_decision(%Issue{} = issue, %Engine{} = engine) do
    cond do
      engine_health(engine) != "healthy" ->
        queued(
          issue,
          "engine_unhealthy",
          "selected engine is not healthy",
          %{engine_id: engine.id},
          engine
        )

      not engine_dispatch_capable?(engine) ->
        queued(
          issue,
          "engine_dispatch_unsupported",
          "selected engine does not support single-issue dispatch",
          %{engine_id: engine.id},
          engine
        )

      true ->
        dispatch(issue, engine)
    end
  end

  defp allocate_capacity(decisions, context) do
    initial = %{
      global: count_active(context.runs),
      engine: count_by(context.runs, &get_in(run_engine(&1), ["id"])),
      project: count_by(context.runs, &get_in(run_project(&1), ["id"])),
      state: count_by(context.runs, &{get_in(run_project(&1), ["id"]), run_issue_state(&1)}),
      worker_host: count_by(context.runs, &run_worker_host/1)
    }

    decisions
    |> Enum.reduce({[], initial}, fn
      %Decision{status: :dispatch} = decision, {acc, usage} ->
        case capacity_decision(decision, usage, context) do
          {:ok, next_decision, next_usage} -> {[next_decision | acc], next_usage}
          {:error, blocked_decision} -> {[blocked_decision | acc], usage}
        end

      decision, {acc, usage} ->
        {[decision | acc], usage}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp capacity_decision(%Decision{issue: issue, engine: engine} = decision, usage, context) do
    cond do
      cap_reached?(usage.global, context.global_capacity) ->
        {:error, queued(issue, "global_capacity_full", "global scheduler capacity is full")}

      cap_reached?(Map.get(usage.engine, engine.id, 0), engine_capacity(engine)) ->
        {:error,
         queued(
           issue,
           "engine_capacity_full",
           "selected engine capacity is full",
           %{engine_id: engine.id},
           engine
         )}

      cap_reached?(
        Map.get(usage.worker_host, context.worker_host, 0),
        context.worker_host_capacity
      ) ->
        {:error,
         queued(issue, "worker_host_capacity_full", "worker host capacity is full", %{}, engine)}

      cap_reached?(Map.get(usage.project, project_id(issue), 0), project_capacity(issue)) ->
        {:error, queued(issue, "project_capacity_full", "project capacity is full", %{}, engine)}

      cap_reached?(
        Map.get(usage.state, {project_id(issue), state_key(issue.state)}, 0),
        state_capacity(issue)
      ) ->
        {:error,
         queued(issue, "state_capacity_full", "project state capacity is full", %{}, engine)}

      blocked_pressure = blocked_pressure(context.pressure) ->
        {:error,
         queued(
           issue,
           "scheduler_pressure_blocked",
           blocked_pressure["reason"],
           %{"pressure" => blocked_pressure},
           engine
         )}

      true ->
        next_decision = annotate_pressure(decision, context.pressure)
        {:ok, next_decision, increment_usage(usage, decision, context)}
    end
  end

  def pressure_state(opts) do
    scheduler = Keyword.get(opts, :scheduler, %{})

    budget =
      Keyword.get(opts, :budget) ||
        Map.get(scheduler, "budget") ||
        %{"mode" => Keyword.get(opts, :budget_mode, "warn")}

    rate_limit =
      Keyword.get(opts, :rate_limit) ||
        Map.get(scheduler, "rate_limit") ||
        Map.get(scheduler, "rate_limits") ||
        %{"mode" => "warn"}

    %{
      "budget" => pressure_gate("budget", budget),
      "rate_limit" =>
        pressure_gate("rate_limit", rate_limit)
        |> merge_observed_rate_limits(Keyword.get(opts, :rate_limit_observations, []))
    }
  end

  defp pressure_gate(name, config) when is_map(config) do
    mode = normalize_mode(config["mode"] || config[:mode] || "warn")
    pressure? = truthy?(config["pressure"] || config[:pressure])
    reason = config["reason"] || config[:reason] || default_pressure_reason(name, mode)

    %{
      "mode" => mode,
      "pressure" => pressure?,
      "status" => pressure_status(mode, pressure?),
      "reason" => reason
    }
  end

  defp pressure_gate(name, _config), do: pressure_gate(name, %{})

  defp merge_observed_rate_limits(gate, observations) when is_list(observations) do
    observed? =
      Enum.any?(observations, fn observation ->
        is_map(observation) and truthy?(observation["pressure"] || observation[:pressure])
      end)

    if observed? do
      %{
        gate
        | "pressure" => true,
          "status" => pressure_status(gate["mode"], true),
          "reason" => observed_rate_limit_reason(observations, gate["reason"])
      }
    else
      gate
    end
  end

  defp merge_observed_rate_limits(gate, _observations), do: gate

  defp observed_rate_limit_reason(observations, fallback) do
    observations
    |> Enum.find_value(fn observation ->
      if is_map(observation), do: observation["reason"] || observation[:reason]
    end)
    |> Kernel.||(fallback)
  end

  defp blocked_pressure(pressure) do
    Enum.find_value(["budget", "rate_limit"], fn name ->
      gate = pressure[name]

      if gate["status"] == "blocked" do
        Map.put(gate, "gate", name)
      end
    end)
  end

  defp annotate_pressure(%Decision{} = decision, pressure) do
    warnings =
      pressure
      |> Enum.filter(fn {_name, gate} -> gate["status"] == "warn" end)
      |> Map.new()

    if map_size(warnings) == 0 do
      decision
    else
      put_in(decision.details[:pressure], warnings)
    end
  end

  defp increment_usage(usage, %Decision{issue: issue, engine: engine}, context) do
    usage
    |> Map.update!(:global, &(&1 + 1))
    |> Map.update!(:engine, &inc(&1, engine.id))
    |> Map.update!(:project, &inc(&1, project_id(issue)))
    |> Map.update!(:state, &inc(&1, {project_id(issue), state_key(issue.state)}))
    |> Map.update!(:worker_host, &inc(&1, context.worker_host))
  end

  defp select_engine(%Issue{} = issue, context) do
    allowed = project_allowed_engines(issue)
    preferred = Enum.reject(allowed ++ [context.default_engine_id], &blank?/1)

    engine =
      case preferred do
        [] -> List.first(context.engines)
        ids -> Enum.find(context.engines, &(&1.id in ids))
      end

    case engine do
      %Engine{} -> {:ok, engine}
      nil -> {:error, queued(issue, "engine_unavailable", "no configured engine is available")}
    end
  end

  defp terminal_issue?(%Issue{} = issue, context) do
    state_key(issue.state) in Enum.map(context.terminal_states, &state_key/1) or
      state_key(issue.state_type) in Enum.map(context.terminal_state_types, &state_key/1)
  end

  defp active_issue?(%Issue{} = issue, %{active_states: []}), do: not blank?(issue.state)

  defp active_issue?(%Issue{} = issue, context) do
    state_key(issue.state) in Enum.map(context.active_states, &state_key/1)
  end

  defp unresolved_blockers?(%Issue{} = issue, context) do
    Enum.any?(issue.blockers || [], fn blocker ->
      state = Map.get(blocker, "state")
      type = Map.get(blocker, "state_type")

      state_key(state) not in Enum.map(context.terminal_states, &state_key/1) and
        state_key(type) not in Enum.map(context.terminal_state_types, &state_key/1)
    end)
  end

  defp active_run_for_issue(issue, runs) do
    Enum.find(runs, fn run ->
      run_state(run) in @active_run_states and get_in(run_issue(run), ["id"]) == issue.id
    end)
  end

  defp run_decision(issue, run) do
    case run_state(run) do
      "retrying" ->
        retry_later(issue, "issue_retrying", "issue has a retrying run")

      state when state in ["queued", "running", "judging"] ->
        queued(issue, "issue_already_active", "issue already has an active run")
    end
  end

  defp policy_blocks?(%Issue{} = issue) do
    drift = get_in(issue.project || %{}, ["policy_drift"]) || %{}
    drift["status"] == "invalid" or has_blocking_drift?(drift)
  end

  defp has_blocking_drift?(%{"status" => "drift", "records" => records}) when is_list(records) do
    Enum.any?(records, &(Map.get(&1, "severity") == "blocking"))
  end

  defp has_blocking_drift?(_drift), do: false

  defp project_status(%Issue{project: project}) when is_map(project), do: project["status"]
  defp project_status(_issue), do: nil

  defp project_allowed_engines(%Issue{project: project}) when is_map(project) do
    case project["allowed_engines"] do
      engines when is_list(engines) -> engines
      _ -> []
    end
  end

  defp project_allowed_engines(_issue), do: []

  defp project_capacity(%Issue{project: project}) when is_map(project) do
    get_in(project, ["capacity", "max_concurrent_agents"]) ||
      get_in(project, ["workflow", "policy", "agent", "max_concurrent_agents"])
  end

  defp project_capacity(_issue), do: nil

  defp state_capacity(%Issue{project: project, state: state}) when is_map(project) do
    caps =
      get_in(project, ["capacity", "max_concurrent_agents_by_state"]) ||
        get_in(project, ["workflow", "policy", "agent", "max_concurrent_agents_by_state"]) ||
        %{}

    caps[state] || caps[state_key(state)]
  end

  defp state_capacity(_issue), do: nil

  defp engine_capacity(%Engine{} = engine), do: engine.capacity["max_concurrent_runs"]
  defp engine_health(%Engine{} = engine), do: engine.health["state"] || "unknown"

  defp engine_dispatch_capable?(%Engine{} = engine),
    do: get_in(engine.capabilities, ["dispatch", "single_issue"]) == true

  defp count_active(runs), do: Enum.count(runs, &(run_state(&1) in @active_run_states))

  defp count_by(runs, fun) do
    runs
    |> Enum.filter(&(run_state(&1) in @active_run_states))
    |> Enum.reduce(%{}, fn run, acc -> inc(acc, fun.(run)) end)
  end

  defp inc(map, nil), do: map
  defp inc(map, key), do: Map.update(map, key, 1, &(&1 + 1))

  defp cap_reached?(_used, nil), do: false
  defp cap_reached?(_used, ""), do: false
  defp cap_reached?(used, cap) when is_integer(cap), do: used >= cap

  defp cap_reached?(used, cap) when is_binary(cap),
    do: match?({value, ""} when used >= value, Integer.parse(cap))

  defp cap_reached?(_used, _cap), do: false

  defp normalize_mode(mode) when mode in ["off", "warn", "block"], do: mode
  defp normalize_mode(mode) when mode in [:off, :warn, :block], do: Atom.to_string(mode)
  defp normalize_mode(_mode), do: "warn"

  defp pressure_status("off", _pressure?), do: "off"
  defp pressure_status("block", true), do: "blocked"
  defp pressure_status("warn", true), do: "warn"
  defp pressure_status(_mode, _pressure?), do: "ok"

  defp default_pressure_reason("budget", _mode), do: "budget pressure is configured"
  defp default_pressure_reason("rate_limit", _mode), do: "rate-limit pressure is configured"
  defp default_pressure_reason(name, _mode), do: "#{name} pressure is configured"

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp run_state(%Run{} = run), do: run.state
  defp run_state(run) when is_map(run), do: run["state"] || run[:state]

  defp run_issue(%Run{} = run), do: run.issue
  defp run_issue(run) when is_map(run), do: run["issue"] || run[:issue] || %{}

  defp run_project(%Run{} = run), do: run.project
  defp run_project(run) when is_map(run), do: run["project"] || run[:project] || %{}

  defp run_engine(%Run{} = run), do: run.engine
  defp run_engine(run) when is_map(run), do: run["engine"] || run[:engine] || %{}

  defp run_issue_state(run), do: get_in(run_issue(run), ["state"]) |> state_key()

  defp run_worker_host(%Run{extra: extra}) when is_map(extra),
    do: get_in(extra, ["worker", "host"])

  defp run_worker_host(run) when is_map(run) do
    get_in(run, ["worker", "host"]) || get_in(run, [:worker, :host])
  end

  defp project_id(%Issue{project: project}) when is_map(project),
    do: get_in(project, ["linear_project", "id"]) || project["id"] || project["name"]

  defp project_id(_issue), do: nil

  defp assignee(%Client.Issue{assignee_id: nil, assignee_name: nil, assignee_email: nil}), do: nil

  defp assignee(%Client.Issue{} = issue) do
    %{"id" => issue.assignee_id, "name" => issue.assignee_name, "email" => issue.assignee_email}
  end

  defp dispatch(issue, engine), do: %Decision{status: :dispatch, issue: issue, engine: engine}

  defp queued(issue, code, message, details \\ %{}, engine \\ nil),
    do: decision(:queued, issue, code, message, details, engine)

  defp blocked(issue, code, message, details \\ %{}),
    do: decision(:blocked, issue, code, message, details, nil)

  defp skipped(issue, code, message, details \\ %{}),
    do: decision(:skipped, issue, code, message, details, nil)

  defp retry_later(issue, code, message, details \\ %{}),
    do: decision(:retry_later, issue, code, message, details, nil)

  defp decision(status, issue, code, message, details, engine)
       when status in @dispatch_statuses do
    %Decision{
      status: status,
      issue: issue,
      engine: engine,
      reason_code: code,
      message: message,
      details: details
    }
  end

  defp state_key(nil), do: nil

  defp state_key(state) when is_atom(state), do: state |> Atom.to_string() |> state_key()

  defp state_key(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
