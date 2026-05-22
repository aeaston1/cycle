defmodule Cycle.Tracker do
  @moduledoc """
  Fetches normalized scheduler and review judge candidates from opted-in projects.
  """

  alias Cycle.{Config, Issue, ProjectRegistry}
  alias Cycle.Linear.Client
  alias Cycle.ProjectRegistry.Project

  defmodule Result do
    @moduledoc false
    defstruct issues: [], skipped: []
  end

  defmodule SkippedProject do
    @moduledoc false
    defstruct [:project, :reason]
  end

  @eligible_statuses ["active", "valid"]
  @disabled_statuses ["disabled"]

  @spec fetch_candidates(ProjectRegistry.t(), Config.t(), Client.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def fetch_candidates(
        %ProjectRegistry{} = registry,
        %Config{} = config,
        %Client{} = client,
        opts \\ []
      ) do
    Enum.reduce_while(registry.projects, {:ok, %Result{}}, fn project, {:ok, result} ->
      case candidate_states(project, config) do
        {:ok, states} ->
          case Client.list_issues(client, linear_project_id(project), states, opts) do
            {:ok, issues} ->
              normalized = Enum.map(issues, &Issue.from_linear(&1, project))
              {:cont, {:ok, %{result | issues: result.issues ++ normalized}}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:skip, reason} ->
          skipped = %SkippedProject{project: project_summary(project), reason: reason}
          {:cont, {:ok, %{result | skipped: result.skipped ++ [skipped]}}}
      end
    end)
    |> sort_result()
  end

  defp sort_result({:error, reason}), do: {:error, reason}

  defp sort_result({:ok, %Result{} = result}),
    do: {:ok, %{result | issues: sort_issues(result.issues)}}

  @spec sort_issues([Issue.t()]) :: [Issue.t()]
  def sort_issues(issues) when is_list(issues) do
    Enum.sort_by(issues, fn issue ->
      {
        priority_rank(issue.priority),
        timestamp(issue.created_at),
        issue.identifier || "",
        issue.id || ""
      }
    end)
  end

  defp candidate_states(%Project{} = project, %Config{} = config) do
    cond do
      project.status in @eligible_statuses ->
        {:ok,
         (active_states(project, config) ++ review_source_states(project, config))
         |> Enum.uniq()
         |> Enum.filter(&present?/1)}

      project.status in @disabled_statuses ->
        {:skip, project.error || "project is disabled"}

      true ->
        {:skip, project.error || "project status is #{project.status || "unknown"}"}
    end
  end

  defp active_states(%Project{} = project, %Config{} = config) do
    get_in(project.workflow, ["policy", "tracker", "active_states"]) ||
      get_in(config.linear, ["active_states"]) ||
      []
  end

  defp review_source_states(%Project{} = project, %Config{} = config) do
    project_review = get_in(project.workflow, ["policy", "review_judge"]) || %{}
    config_review = config.review_judge || %{}

    enabled =
      if Map.has_key?(project_review, "enabled") do
        Map.get(project_review, "enabled")
      else
        Map.get(config_review, "enabled") || false
      end

    if enabled do
      [Map.get(project_review, "source_state") || Map.get(config_review, "source_state")]
    else
      []
    end
  end

  defp priority_rank(priority) when is_integer(priority), do: priority
  defp priority_rank(_priority), do: 0

  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_value), do: ""

  defp linear_project_id(%Project{} = project), do: get_in(project.linear_project, ["id"])

  defp project_summary(%Project{} = project) do
    %{
      "id" => linear_project_id(project),
      "name" => get_in(project.linear_project, ["name"]),
      "slug" => get_in(project.linear_project, ["slug"]),
      "status" => project.status
    }
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
