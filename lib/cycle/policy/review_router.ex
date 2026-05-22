defmodule Cycle.Policy.ReviewRouter do
  @moduledoc """
  Safely writes review judge decisions back to Linear.

  Routing is conservative: the issue is refreshed immediately before writes,
  project opt-in is checked from the current issue context, and duplicate
  evidence hashes skip all writes.
  """

  require Logger

  alias Cycle.Issue
  alias Cycle.Linear.Client
  alias Cycle.Policy.EvidenceHash
  alias Cycle.Policy.ReviewJudge.Decision

  defmodule Result do
    @moduledoc "Review judge Linear routing result."
    defstruct [
      :status,
      :reason_code,
      :message,
      :issue,
      :comment,
      :moved_issue,
      :error,
      details: %{}
    ]
  end

  @type result_status :: :written | :skipped | :failed
  @type result :: %Result{
          status: result_status(),
          reason_code: String.t() | nil,
          message: String.t() | nil,
          issue: Issue.t() | Client.Issue.t() | nil,
          comment: Client.Comment.t() | nil,
          moved_issue: Client.Issue.t() | nil,
          error: term(),
          details: map()
        }

  @doc """
  Posts a review judge decision comment and optionally routes issue state.

  Required options:

    * `:client` - `Cycle.Linear.Client` used for Linear writes.
    * `:evidence_hash` - stable evidence hash included in the comment.
    * `:source_state` - state the issue must still be in before writing.

  Optional state options:

    * `:review_state` - state used for `require_human_review` decisions.
    * `:proceed_state` - state used for `proceed_to_merging` decisions.
  """
  def route(%Issue{} = issue, %Decision{} = decision, opts) when is_list(opts) do
    client = Keyword.fetch!(opts, :client)
    evidence_hash = Keyword.fetch!(opts, :evidence_hash)
    source_state = Keyword.fetch!(opts, :source_state)

    with {:ok, refreshed} <- refresh_issue(client, issue, opts),
         :ok <- ensure_source_state(refreshed, source_state),
         :ok <- ensure_project_enabled(issue, refreshed),
         {:ok, comments} <- list_comments(client, refreshed.id, opts),
         :ok <- ensure_not_duplicate(comments, evidence_hash),
         {:ok, comment} <-
           create_comment(client, refreshed.id, comment_body(decision, evidence_hash), opts),
         {:ok, moved_issue} <- maybe_move_issue(client, refreshed, decision, opts) do
      written(issue, refreshed, comment, moved_issue, decision)
    else
      {:skip, reason_code, message, details} ->
        skipped(issue, reason_code, message, details)

      {:error, stage, reason} ->
        failed(issue, stage, reason)

      {:error, reason} ->
        failed(issue, "linear_write", reason)
    end
  end

  defp refresh_issue(client, %Issue{id: issue_id}, opts) do
    refresh = Keyword.get(opts, :refresh_issue, &Client.refresh_issue/2)

    case call_refresh(refresh, client, issue_id) do
      {:ok, %Client.Issue{} = issue} -> {:ok, issue}
      {:ok, nil} -> {:skip, "issue_not_visible", "issue is no longer visible in Linear", %{}}
      {:ok, issue} -> {:error, "refresh_issue", {:unexpected_issue, issue}}
      {:error, reason} -> {:error, "refresh_issue", reason}
    end
  end

  defp call_refresh(fun, client, issue_id) when is_function(fun, 2), do: fun.(client, issue_id)
  defp call_refresh(fun, _client, issue_id) when is_function(fun, 1), do: fun.(issue_id)

  defp ensure_source_state(%Client.Issue{state: state}, source_state) do
    if state == source_state do
      :ok
    else
      {:skip, "stale_issue_state", "issue left review source state",
       %{
         "current_state" => state,
         "source_state" => source_state
       }}
    end
  end

  defp ensure_project_enabled(%Issue{} = original, %Client.Issue{} = refreshed) do
    project = original.project || %{}
    original_project_id = get_in(project, ["linear_project", "id"])

    cond do
      project_status(project) == "disabled" ->
        {:skip, "project_disabled", "project is disabled", %{"project_id" => original_project_id}}

      is_binary(original_project_id) and is_binary(refreshed.project_id) and
          original_project_id != refreshed.project_id ->
        {:skip, "project_changed", "issue moved to a different Linear project",
         %{
           "original_project_id" => original_project_id,
           "current_project_id" => refreshed.project_id
         }}

      true ->
        :ok
    end
  end

  defp project_status(project) when is_map(project), do: Map.get(project, "status")
  defp project_status(_project), do: nil

  defp list_comments(client, issue_id, opts) do
    list = Keyword.get(opts, :list_comments, &Client.list_comments/2)

    case call_issue_fun(list, client, issue_id) do
      {:ok, comments} when is_list(comments) -> {:ok, comments}
      {:ok, other} -> {:error, "list_comments", {:unexpected_comments, other}}
      {:error, reason} -> {:error, "list_comments", reason}
    end
  end

  defp ensure_not_duplicate(comments, evidence_hash) do
    if EvidenceHash.duplicate_comment?(comments, evidence_hash) do
      {:skip, "duplicate_evidence_hash", "review judge evidence hash was already posted",
       %{
         "evidence_hash" => evidence_hash
       }}
    else
      :ok
    end
  end

  defp create_comment(client, issue_id, body, opts) do
    create = Keyword.get(opts, :create_comment, &Client.create_comment/3)

    case call_comment_fun(create, client, issue_id, body) do
      {:ok, %Client.Comment{} = comment} -> {:ok, comment}
      {:ok, comment} -> {:error, "create_comment", {:unexpected_comment, comment}}
      {:error, reason} -> {:error, "create_comment", reason}
    end
  end

  defp maybe_move_issue(client, %Client.Issue{} = issue, %Decision{} = decision, opts) do
    case target_state(issue, decision, opts) do
      nil ->
        {:ok, nil}

      state ->
        update = Keyword.get(opts, :update_issue_state, &Client.update_issue_state/3)

        case call_update_fun(update, client, issue.id, state) do
          {:ok, %Client.Issue{} = moved} -> {:ok, moved}
          {:ok, moved} -> {:error, "update_issue_state", {:unexpected_issue, moved}}
          {:error, reason} -> {:error, "update_issue_state", reason}
        end
    end
  end

  defp target_state(%Client.Issue{state: state}, %Decision{decision: "proceed_to_merging"}, opts) do
    proceed_state = Keyword.get(opts, :proceed_state)
    if present?(proceed_state) and proceed_state != state, do: proceed_state
  end

  defp target_state(
         %Client.Issue{state: state},
         %Decision{decision: "require_human_review"},
         opts
       ) do
    review_state = Keyword.get(opts, :review_state)
    if present?(review_state) and review_state != state, do: review_state
  end

  defp target_state(_issue, _decision, _opts), do: nil

  defp call_issue_fun(fun, client, issue_id) when is_function(fun, 2), do: fun.(client, issue_id)
  defp call_issue_fun(fun, _client, issue_id) when is_function(fun, 1), do: fun.(issue_id)

  defp call_comment_fun(fun, client, issue_id, body) when is_function(fun, 3),
    do: fun.(client, issue_id, body)

  defp call_comment_fun(fun, _client, issue_id, body) when is_function(fun, 2),
    do: fun.(issue_id, body)

  defp call_update_fun(fun, client, issue_id, state) when is_function(fun, 3),
    do: fun.(client, issue_id, state)

  defp call_update_fun(fun, _client, issue_id, state) when is_function(fun, 2),
    do: fun.(issue_id, state)

  defp comment_body(%Decision{} = decision, evidence_hash) do
    [
      "## Cycle Review Judge",
      "",
      "Decision: #{decision.decision}",
      maybe_line("Confidence", decision.confidence),
      maybe_line("Human review value", decision.human_review_value),
      maybe_line("Reason", decision.reason),
      evidence_line(decision.evidence),
      hard_stops_line(decision.hard_stops),
      "",
      EvidenceHash.marker_line(evidence_hash)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(label, value), do: "#{label}: #{trim_text(value, 300)}"

  defp evidence_line([]), do: nil
  defp evidence_line(nil), do: nil

  defp evidence_line(evidence) when is_list(evidence) do
    "Evidence: " <> (evidence |> Enum.map(&trim_text(&1, 160)) |> Enum.join("; "))
  end

  defp hard_stops_line([]), do: nil
  defp hard_stops_line(nil), do: nil

  defp hard_stops_line(stops) when is_list(stops) do
    codes =
      stops
      |> Enum.map(fn stop -> stop |> Map.get(:code) |> to_string() end)
      |> Enum.reject(&(&1 == ""))

    if codes == [], do: nil, else: "Hard stops: " <> Enum.join(codes, ", ")
  end

  defp trim_text(value, max) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max)
  end

  defp written(original, refreshed, comment, moved_issue, decision) do
    %Result{
      status: :written,
      reason_code: nil,
      message: "review judge decision was posted",
      issue: refreshed,
      comment: comment,
      moved_issue: moved_issue,
      details: %{
        "identifier" => original.identifier,
        "decision" => decision.decision,
        "moved" => not is_nil(moved_issue)
      }
    }
  end

  defp skipped(issue, reason_code, message, details) do
    Logger.info("Cycle review judge routing skipped",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      reason_code: reason_code,
      details: details
    )

    %Result{
      status: :skipped,
      reason_code: reason_code,
      message: message,
      issue: issue,
      details: details
    }
  end

  defp failed(issue, stage, reason) do
    Logger.error("Cycle review judge routing failed",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: stage,
      error: inspect(reason)
    )

    %Result{
      status: :failed,
      reason_code: "linear_write_failed",
      message: "review judge Linear write failed during #{stage}",
      issue: issue,
      error: reason,
      details: %{"stage" => stage, "error" => inspect(reason)}
    }
  end

  defp present?(value), do: is_binary(value) and value != ""
end
