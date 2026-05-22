defmodule Cycle.API.Serializers do
  @moduledoc """
  Explicit JSON serializers for the local read-only Cycle API.
  """

  alias Cycle.Config
  alias Cycle.EngineRegistry
  alias Cycle.ProjectRegistry
  alias Cycle.RunStore

  def projects(%Config{} = config) do
    config.projects["registry_path"]
    |> load_projects()
    |> Enum.map(&project/1)
  end

  def engines(%Config{} = config, health_opts \\ []) do
    engines =
      config.engines["registry_path"]
      |> load_engines()
      |> case do
        [] -> [default_engine(config)]
        engines -> engines
      end

    Enum.map(engines, &engine(&1, health_opts))
  end

  def runs(%Config{} = config) do
    config
    |> runs_path()
    |> load_runs()
    |> Enum.map(&run/1)
  end

  def logs(%Config{} = config) do
    %{
      "log_file" => get_in(config.service, ["logs", "path"]),
      "logs_dir" => config.paths.logs_dir,
      "runs_registry" => runs_path(config),
      "projects_registry" => config.projects["registry_path"],
      "engines_registry" => config.engines["registry_path"]
    }
  end

  def project(%ProjectRegistry.Project{} = project) do
    %{
      "linear_project" => Map.take(project.linear_project || %{}, ["id", "name", "slug", "url"]),
      "namespace" => project.metadata_namespace || project.namespace,
      "repo" => Map.take(project.repo || %{}, ["url", "full_name"]),
      "workflow" => Map.take(project.workflow || %{}, ["path", "resolved_path", "hash"]),
      "allowed_engines" => project.allowed_engines || [],
      "policy_profile" => project.policy_profile,
      "capacity" => project.capacity || %{},
      "last_discovery_at" => project.last_discovery_at || project.last_discovered_at,
      "status" => project.status,
      "error" => project.error,
      "policy_drift" => project.policy_drift || %{}
    }
  end

  def engine(%EngineRegistry.Engine{} = engine, health_opts \\ []) do
    health = Cycle.Engine.Health.check(engine, health_opts)

    %{
      "id" => engine.id,
      "name" => engine.name,
      "source" => engine.source,
      "ref" => engine.ref,
      "install_path" => engine.install_path,
      "capabilities" => engine.capabilities || %{},
      "health" => Map.take(health, ["state", "reason", "checked_at", "revision", "executable"]),
      "capacity" => engine.capacity || %{}
    }
  end

  def run(%RunStore.Run{} = run) do
    %{
      "id" => run.id,
      "issue" => Map.take(run.issue || %{}, ["id", "identifier"]),
      "project" => Map.take(run.project || %{}, ["id", "name"]),
      "engine" => Map.take(run.engine || %{}, ["id", "name"]),
      "workflow_path" => run.workflow_path,
      "workflow_hash" => run.workflow_hash,
      "workspace_path" => run.workspace_path,
      "state" => run.state,
      "timestamps" => run.timestamps || %{},
      "retry" => run.retry || %{},
      "last_event" => redact_event(run.last_event),
      "evidence" => log_evidence(run.evidence || [])
    }
  end

  def runs_path(%Config{} = config), do: Path.join(config.paths.state_dir, "runs.yaml")

  def load_projects(path) do
    with {:ok, raw} <- Cycle.Registry.Store.read(path, %{}),
         {:ok, registry} <- ProjectRegistry.from_map(Map.put_new(raw, "projects", [])) do
      registry.projects
    else
      _ -> []
    end
  end

  def load_engines(path) do
    with {:ok, registry} <- EngineRegistry.read(path) do
      registry.engines
    else
      _ -> []
    end
  end

  def load_runs(path) do
    with {:ok, registry} <- RunStore.load(path) do
      registry.runs
    else
      _ -> []
    end
  end

  defp default_engine(config) do
    default = get_in(config.engines, ["default"]) || "openai-symphony@main"

    case Cycle.EngineId.parse(default) do
      {:ok, engine_id} -> EngineRegistry.default_record(config, engine_id)
      {:error, _reason} -> %EngineRegistry.Engine{id: default, health: %{"state" => "unknown"}}
    end
  end

  defp redact_event(nil), do: nil
  defp redact_event(event) when is_map(event), do: Map.take(event, ["summary", "code", "reason"])
  defp redact_event(_event), do: nil

  defp log_evidence(evidence) do
    Enum.map(evidence, fn
      %{"type" => "log", "path" => path} -> %{"type" => "log", "path" => path}
      %{"path" => path} -> %{"path" => path}
      item when is_map(item) -> Map.take(item, ["type", "path", "summary"])
      _ -> %{}
    end)
  end
end
