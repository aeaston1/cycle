defmodule Cycle.Issue do
  @moduledoc """
  Normalized Linear issue record used by Cycle schedulers and review judges.
  """

  alias Cycle.Linear.Client
  alias Cycle.ProjectRegistry.Project

  defstruct [
    :id,
    :identifier,
    :title,
    :state,
    :state_type,
    :url,
    :branch,
    :assignee,
    :labels,
    :blockers,
    :priority,
    :priority_label,
    :created_at,
    :updated_at,
    :project
  ]

  @type t :: %__MODULE__{}

  @spec from_linear(Client.Issue.t(), Project.t()) :: t()
  def from_linear(%Client.Issue{} = issue, %Project{} = project) do
    %__MODULE__{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      state_type: issue.state_type,
      url: issue.url,
      branch: issue.branch_name,
      assignee: assignee(issue),
      labels: issue.labels || [],
      blockers: issue.blocks || [],
      priority: issue.priority,
      priority_label: issue.priority_label,
      created_at: issue.created_at,
      updated_at: issue.updated_at,
      project: project_metadata(project)
    }
  end

  defp assignee(%Client.Issue{assignee_id: nil, assignee_name: nil, assignee_email: nil}), do: nil

  defp assignee(%Client.Issue{} = issue) do
    %{"id" => issue.assignee_id, "name" => issue.assignee_name, "email" => issue.assignee_email}
  end

  defp project_metadata(%Project{} = project) do
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
    |> Map.merge(project.extra)
  end
end
