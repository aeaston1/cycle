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
  alias Cycle.WorkflowPolicy
  alias Cycle.WorkflowResolver

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
    workflow_opts = Keyword.get(opts, :workflow_resolver, [])

    with {:ok, projects} <- Client.list_projects(client, page_size: page_size),
         records <- normalize_projects(projects, now, workflow_opts),
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

  def normalize_projects(projects, now \\ DateTime.utc_now(), workflow_opts \\ [])
      when is_list(projects) do
    projects
    |> Enum.map(&normalize_project(&1, now, workflow_opts))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_project(%LinearProject{} = project, now, workflow_opts) do
    source = Enum.join(Enum.filter([project.description, project.content], &present?/1), "\n")

    case ProjectMetadata.parse(source, field: "description") do
      {:ok, metadata} -> resolve_record(project, metadata, now, workflow_opts)
      :not_opted_in -> nil
      {:error, errors} -> invalid_record(project, errors, now)
    end
  end

  defp resolve_record(project, metadata, now, workflow_opts) do
    repo = %{"url" => metadata.repo_url, "full_name" => metadata.repo_full_name}

    case WorkflowResolver.resolve(repo, metadata.workflow_path, workflow_opts) do
      {:ok, workflow} ->
        case WorkflowPolicy.parse(workflow.content) do
          {:ok, policy} -> valid_record(project, metadata, workflow, policy, now)
          {:error, errors} -> invalid_record(project, metadata, errors, now)
        end

      {:error, reason} ->
        invalid_record(project, metadata, reason, now)
    end
  end

  defp valid_record(project, metadata, workflow, policy, now) do
    %Project{
      linear_project: linear_project(project),
      namespace: metadata.source.namespace,
      metadata_namespace: metadata.source.namespace,
      repo: %{"url" => metadata.repo_url, "full_name" => metadata.repo_full_name},
      workflow: %{
        "path" => workflow.path,
        "resolved_path" => workflow.resolved_path,
        "cache_path" => workflow.cache_path,
        "hash" => workflow.hash,
        "policy_hash" => policy.hash,
        "policy" => policy_to_map(policy)
      },
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

  defp invalid_record(project, metadata, errors, now) when is_list(errors) do
    invalid_record(project, metadata, Enum.map(errors, &format_error/1) |> Enum.join("; "), now)
  end

  defp invalid_record(project, metadata, reason, now) do
    %Project{
      linear_project: linear_project(project),
      namespace: metadata.source.namespace,
      metadata_namespace: metadata.source.namespace,
      repo: %{"url" => metadata.repo_url, "full_name" => metadata.repo_full_name},
      workflow: %{"path" => metadata.workflow_path},
      allowed_engines: metadata.allowed_engines,
      policy_profile: metadata.policy_profile || @default_policy_profile,
      capacity: metadata.capacity,
      last_discovery_at: DateTime.to_iso8601(now),
      last_discovered_at: DateTime.to_iso8601(now),
      status: "invalid",
      error: "workflow: #{reason}",
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

  defp policy_to_map(%WorkflowPolicy{} = policy) do
    %{
      "agent" => policy.agent,
      "tracker" => policy.tracker,
      "review_judge" => policy.review_judge,
      "worker" => policy.worker,
      "hooks" => policy.hooks
    }
  end

  defp format_error(%{path: path, reason: reason}), do: "#{path}: #{reason}"
  defp present?(value), do: is_binary(value) && value != ""
end
