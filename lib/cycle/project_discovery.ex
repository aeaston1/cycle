defmodule Cycle.ProjectDiscovery do
  @moduledoc """
  Discovers opted-in Linear projects and persists the Cycle project registry.
  """

  alias Cycle.Linear.Client
  alias Cycle.Linear.Client.Project, as: LinearProject
  alias Cycle.ProjectMetadata
  alias Cycle.ProjectRegistry
  alias Cycle.ProjectRegistry.Project
  alias Cycle.Registry.Store

  @default_page_size 100
  @default_policy_profile "default"

  defmodule Result do
    @moduledoc false
    defstruct records: [], registry_path: nil, last_discovered_at: nil
  end

  def discover(%Client{} = client, opts \\ []) do
    page_size = Keyword.get(opts, :limit, @default_page_size)
    registry_path = Keyword.fetch!(opts, :registry_path)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, projects} <- Client.list_projects(client, page_size: page_size),
         records <- normalize_projects(projects, now),
         registry <- %ProjectRegistry{projects: records},
         :ok <- Store.write(registry_path, ProjectRegistry.to_map(registry)) do
      {:ok,
       %Result{
         records: records,
         registry_path: registry_path,
         last_discovered_at: DateTime.to_iso8601(now)
       }}
    end
  end

  def normalize_projects(projects, now \\ DateTime.utc_now()) when is_list(projects) do
    projects
    |> Enum.map(&normalize_project(&1, now))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_project(%LinearProject{} = project, now) do
    source = Enum.join(Enum.filter([project.description, project.content], &present?/1), "\n")

    case ProjectMetadata.parse(source, field: "description") do
      {:ok, metadata} -> valid_record(project, metadata, now)
      :not_opted_in -> nil
      {:error, errors} -> invalid_record(project, errors, now)
    end
  end

  defp valid_record(project, metadata, now) do
    %Project{
      linear_project: linear_project(project),
      namespace: metadata.source.namespace,
      metadata_namespace: metadata.source.namespace,
      repo: %{"url" => metadata.repo_url, "full_name" => metadata.repo_full_name},
      workflow: %{"path" => metadata.workflow_path, "resolved_path" => metadata.workflow_path},
      allowed_engines: metadata.allowed_engines,
      policy_profile: metadata.policy_profile || @default_policy_profile,
      capacity: metadata.capacity,
      last_discovery_at: DateTime.to_iso8601(now),
      last_discovered_at: DateTime.to_iso8601(now),
      status: "valid",
      error: nil,
      policy_drift: %{}
    }
  end

  defp invalid_record(project, errors, now) do
    %Project{
      linear_project: linear_project(project),
      namespace: "cycle",
      metadata_namespace: "cycle",
      repo: %{},
      workflow: %{},
      allowed_engines: [],
      policy_profile: @default_policy_profile,
      capacity: %{},
      last_discovery_at: DateTime.to_iso8601(now),
      last_discovered_at: DateTime.to_iso8601(now),
      status: "invalid",
      error: Enum.map(errors, &format_error/1) |> Enum.join("; "),
      policy_drift: %{}
    }
  end

  defp linear_project(project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "slug" => project.slug_id,
      "url" => project.url
    }
  end

  defp format_error(%{path: path, reason: reason}), do: "#{path}: #{reason}"
  defp present?(value), do: is_binary(value) && value != ""
end
