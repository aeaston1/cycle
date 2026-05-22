defmodule Cycle.ProjectRegistry do
  @moduledoc """
  Versioned schema for Cycle project registry files.
  """

  alias Cycle.Registry.Schema

  @records_key "projects"
  @known_project_keys [
    "linear_project",
    "namespace",
    "metadata_namespace",
    "repo",
    "workflow",
    "allowed_engines",
    "policy_profile",
    "capacity",
    "last_discovery_at",
    "last_discovered_at",
    "status",
    "error",
    "policy_drift"
  ]
  @statuses ["valid", "drift", "invalid", "active", "disabled", "error", "discovering"]

  defstruct schema_version: Schema.schema_version(), projects: [], extra: %{}

  defmodule Project do
    @moduledoc false
    defstruct linear_project: %{},
              namespace: nil,
              metadata_namespace: nil,
              repo: %{},
              workflow: %{},
              allowed_engines: [],
              policy_profile: nil,
              capacity: %{},
              last_discovery_at: nil,
              last_discovered_at: nil,
              status: nil,
              error: nil,
              policy_drift: %{},
              extra: %{}

    @type t :: %__MODULE__{}
  end

  def validate(raw) do
    case Schema.validate_document(raw, @records_key, &validate_project/2) do
      {:ok, _document} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  def from_map(raw) do
    with {:ok, document} <- Schema.validate_document(raw, @records_key, &validate_project/2) do
      projects = Enum.map(document.records, &project_from_map/1)

      {:ok,
       %__MODULE__{
         schema_version: document.schema_version,
         projects: projects,
         extra: document.extra
       }}
    end
  end

  def to_map(%__MODULE__{} = registry) do
    %{
      "schema_version" => registry.schema_version,
      @records_key => Enum.map(registry.projects, &project_to_map/1)
    }
    |> Schema.put_extra(registry.extra)
  end

  defp validate_project(project, path) do
    [
      Schema.optional_map(project, "linear_project", path),
      Schema.required_string(project, "namespace", path),
      Schema.optional_string(project, "metadata_namespace", path),
      Schema.optional_map(project, "repo", path),
      Schema.optional_map(project, "workflow", path),
      Schema.optional_list(project, "allowed_engines", path),
      Schema.required_string(project, "policy_profile", path),
      Schema.optional_map(project, "capacity", path),
      Schema.optional_iso8601_utc(project, "last_discovery_at", path),
      Schema.optional_iso8601_utc(project, "last_discovered_at", path),
      Schema.enum(project, "status", @statuses, path),
      Schema.optional_string(project, "error", path),
      Schema.optional_map(project, "policy_drift", path)
    ]
    |> List.flatten()
    |> Kernel.++(validate_linear_project(project["linear_project"], "#{path}.linear_project"))
    |> Kernel.++(validate_repo(project, "#{path}.repo"))
    |> Kernel.++(validate_workflow(project, "#{path}.workflow"))
  end

  defp validate_linear_project(nil, path), do: [Schema.error(path, "is required")]

  defp validate_linear_project(map, path) when is_map(map) do
    Enum.flat_map(["id", "name", "slug", "url"], &Schema.required_string(map, &1, path))
  end

  defp validate_linear_project(_value, _path), do: []

  defp validate_repo(%{"status" => "invalid"}, _path), do: []
  defp validate_repo(%{"repo" => nil}, path), do: [Schema.error(path, "is required")]

  defp validate_repo(%{"repo" => map}, path) when is_map(map) do
    Enum.flat_map(["url", "full_name"], &Schema.required_string(map, &1, path))
  end

  defp validate_repo(_project, _path), do: []

  defp validate_workflow(%{"status" => "invalid"}, _path), do: []
  defp validate_workflow(%{"workflow" => nil}, path), do: [Schema.error(path, "is required")]

  defp validate_workflow(%{"workflow" => map}, path) when is_map(map) do
    Enum.flat_map(["path", "resolved_path"], &Schema.required_string(map, &1, path))
  end

  defp validate_workflow(_project, _path), do: []

  defp project_from_map(map) do
    %Project{
      linear_project: map["linear_project"],
      namespace: map["namespace"],
      metadata_namespace: map["metadata_namespace"],
      repo: map["repo"],
      workflow: map["workflow"],
      allowed_engines: Map.get(map, "allowed_engines", []),
      policy_profile: map["policy_profile"],
      capacity: Map.get(map, "capacity", %{}),
      last_discovery_at: map["last_discovery_at"],
      last_discovered_at: map["last_discovered_at"],
      status: map["status"],
      error: map["error"],
      policy_drift: Map.get(map, "policy_drift", %{}),
      extra: Schema.preserve_extra(map, @known_project_keys)
    }
  end

  defp project_to_map(%Project{} = project) do
    %{
      "linear_project" => project.linear_project,
      "namespace" => project.namespace,
      "metadata_namespace" => project.metadata_namespace,
      "repo" => project.repo,
      "workflow" => project.workflow,
      "allowed_engines" => project.allowed_engines,
      "policy_profile" => project.policy_profile,
      "capacity" => project.capacity,
      "last_discovery_at" => project.last_discovery_at,
      "last_discovered_at" => project.last_discovered_at,
      "status" => project.status,
      "error" => project.error,
      "policy_drift" => project.policy_drift
    }
    |> Schema.put_extra(project.extra)
  end
end
