defmodule Cycle.StatusSnapshot do
  @moduledoc """
  Structured read model for Cycle status output.
  """

  alias Cycle.Config
  alias Cycle.EngineRegistry
  alias Cycle.ProjectRegistry
  alias Cycle.RunStore

  @run_states ~w(running queued retrying blocked judging completed failed)
  @top_drift_limit 5

  @type t :: map()

  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    home = Keyword.get(opts, :home, System.user_home!())
    api_get = Keyword.get(opts, :api_get, &Req.get/2)
    health_opts = Keyword.get(opts, :health_opts, [])

    with {:ok, config} <- Config.load(env: env, home: home) do
      {:ok, from_config(config, env: env, api_get: api_get, health_opts: health_opts)}
    end
  end

  @spec from_config(Config.t(), keyword()) :: t()
  def from_config(%Config{} = config, opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    api_get = Keyword.get(opts, :api_get, &Req.get/2)
    health_opts = Keyword.get(opts, :health_opts, [])

    projects = load_projects(config.projects["registry_path"])
    engines = load_engines(config.engines["registry_path"])
    runs = load_runs(Path.join(config.paths.state_dir, "runs.yaml"))

    project_summary = project_summary(projects)
    drift = drift_summary(projects)

    %{
      "schema" => "cycle.status_snapshot.v1",
      "paths" => %{
        "config" => config.paths.config_file,
        "state" => config.paths.state_dir,
        "projects_registry" => config.projects["registry_path"],
        "engines_registry" => config.engines["registry_path"],
        "runs_registry" => Path.join(config.paths.state_dir, "runs.yaml")
      },
      "linear" => linear_status(config, env),
      "projects" => project_summary,
      "engines" => engine_summary(config, engines, health_opts),
      "runs" => run_summary(runs),
      "capacity" => capacity_summary(config, projects, engines, runs),
      "drift" => drift,
      "discovery" => %{"last_errors" => discovery_errors(projects)},
      "service" => service_summary(config, api_get)
    }
  end

  defp load_projects(path) do
    with {:ok, raw} <- Cycle.Registry.Store.read(path, %{}),
         {:ok, registry} <- ProjectRegistry.from_map(Map.put_new(raw, "projects", [])) do
      registry.projects
    else
      _ -> []
    end
  end

  defp load_engines(path) do
    with {:ok, registry} <- EngineRegistry.read(path) do
      registry.engines
    else
      _ -> []
    end
  end

  defp load_runs(path) do
    with {:ok, registry} <- RunStore.load(path) do
      registry.runs
    else
      _ -> []
    end
  end

  defp linear_status(config, env) do
    configured? =
      present?(get_in(config.secrets, ["linear_api_key"])) ||
        present?(Map.get(env, get_in(config.linear, ["api_key_env"]) || "LINEAR_API_KEY"))

    %{"auth" => if(configured?, do: "configured", else: "missing")}
  end

  defp project_summary(projects) do
    counts =
      projects
      |> Enum.frequencies_by(&(&1.status || "unknown"))
      |> Map.put_new("watched", length(projects))
      |> Map.put_new("invalid", Enum.count(projects, &(&1.status == "invalid")))

    %{
      "counts" => counts,
      "details" => Enum.map(projects, &project_detail/1)
    }
  end

  defp project_detail(project) do
    %{
      "name" => get_in(project.linear_project || %{}, ["name"]),
      "slug" => get_in(project.linear_project || %{}, ["slug"]),
      "namespace" => project.metadata_namespace || project.namespace,
      "repo" => get_in(project.repo || %{}, ["url"]),
      "workflow" => get_in(project.workflow || %{}, ["path"]),
      "status" => project.status,
      "error" => project.error
    }
  end

  defp engine_summary(config, engines, health_opts) do
    engines = if engines == [], do: [default_engine(config)], else: engines

    %{
      "counts" => Enum.frequencies_by(engines, &health_state/1),
      "details" => Enum.map(engines, &engine_detail(&1, health_opts))
    }
  end

  defp default_engine(config) do
    default = get_in(config.engines, ["default"]) || "openai-symphony@main"

    case Cycle.EngineId.parse(default) do
      {:ok, engine_id} -> EngineRegistry.default_record(config, engine_id)
      {:error, _reason} -> %EngineRegistry.Engine{id: default, health: %{"state" => "unknown"}}
    end
  end

  defp health_state(engine), do: get_in(engine.health || %{}, ["state"]) || "unknown"

  defp engine_detail(engine, health_opts) do
    health = Cycle.Engine.Health.check(engine, health_opts)

    %{
      "id" => engine.id,
      "name" => engine.name,
      "ref" => engine.ref,
      "install_path" => engine.install_path,
      "health" => Map.take(health, ["state", "reason", "checked_at", "revision", "executable"]),
      "capacity" => engine.capacity || %{}
    }
  end

  defp run_summary(runs) do
    counts =
      @run_states
      |> Map.new(&{&1, 0})
      |> Map.merge(Enum.frequencies_by(runs, & &1.state))

    %{"counts" => counts, "details" => Enum.map(runs, &run_detail/1)}
  end

  defp run_detail(run) do
    %{
      "id" => run.id,
      "state" => run.state,
      "issue" => Map.take(run.issue || %{}, ["id", "identifier"]),
      "project" => Map.take(run.project || %{}, ["id", "name"]),
      "engine" => Map.take(run.engine || %{}, ["id", "name"]),
      "timestamps" => run.timestamps || %{},
      "retry" => run.retry || %{},
      "last_event" => redact_event(run.last_event)
    }
  end

  defp capacity_summary(config, projects, engines, runs) do
    running = Enum.count(runs, &(&1.state in ["running", "judging"]))
    global_limit = get_in(config.scheduler, ["max_concurrent_runs"])

    %{
      "global" => capacity(global_limit, running),
      "projects" => project_capacity(projects, runs),
      "states" => state_capacity(projects, runs),
      "engines" => engine_capacity(engines, runs)
    }
  end

  defp project_capacity(projects, runs) do
    Map.new(projects, fn project ->
      key =
        get_in(project.linear_project || %{}, ["id"]) ||
          get_in(project.linear_project || %{}, ["name"])

      limit = get_in(project.capacity || %{}, ["max_concurrent_agents"])

      used =
        Enum.count(runs, &(get_in(&1.project || %{}, ["id"]) == key and &1.state == "running"))

      {key || "unknown", capacity(limit, used)}
    end)
  end

  defp state_capacity(projects, runs) do
    projects
    |> Enum.flat_map(fn project ->
      project.capacity
      |> Kernel.||(%{})
      |> Map.get("states", %{})
      |> Enum.map(fn {state, limit} ->
        used = Enum.count(runs, &(&1.state == state))
        {state, capacity(limit, used)}
      end)
    end)
    |> Map.new()
  end

  defp engine_capacity(engines, runs) do
    Map.new(engines, fn engine ->
      used =
        Enum.count(
          runs,
          &(get_in(&1.engine || %{}, ["id"]) == engine.id and &1.state == "running")
        )

      {engine.id || "unknown",
       capacity(get_in(engine.capacity || %{}, ["max_concurrent_runs"]), used)}
    end)
  end

  defp capacity(nil, used), do: %{"used" => used, "available" => nil, "limit" => nil}

  defp capacity(limit, used),
    do: %{"used" => used, "available" => max(limit - used, 0), "limit" => limit}

  defp drift_summary(projects) do
    records =
      Enum.flat_map(projects, fn project ->
        project.policy_drift
        |> Kernel.||(%{})
        |> Map.get("records", [])
        |> Enum.map(&Map.put(&1, "project", get_in(project.linear_project || %{}, ["name"])))
      end)

    %{"count" => length(records), "top" => Enum.take(records, @top_drift_limit)}
  end

  defp discovery_errors(projects) do
    projects
    |> Enum.filter(&present?(&1.error))
    |> Enum.map(fn project ->
      %{
        "project" => get_in(project.linear_project || %{}, ["name"]),
        "status" => project.status,
        "error" => project.error,
        "last_discovery_at" => project.last_discovery_at || project.last_discovered_at
      }
    end)
  end

  defp service_summary(config, api_get) do
    url =
      get_in(config.service, ["status_url"]) ||
        "http://#{get_in(config.service, ["api", "bind"]) || "127.0.0.1"}:#{get_in(config.service, ["api", "port"]) || 4765}/health"

    %{"api" => api_health(url, api_get)}
  end

  defp api_health(url, api_get) do
    case api_get.(url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> %{"url" => url, "state" => "healthy"}
      {:ok, %{status: status}} -> %{"url" => url, "state" => "unhealthy", "status" => status}
      {:error, _reason} -> %{"url" => url, "state" => "unreachable"}
      _ -> %{"url" => url, "state" => "unknown"}
    end
  end

  defp redact_event(nil), do: nil
  defp redact_event(event) when is_map(event), do: Map.take(event, ["summary", "code", "reason"])
  defp redact_event(_event), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
