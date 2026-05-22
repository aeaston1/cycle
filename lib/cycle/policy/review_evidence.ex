defmodule Cycle.Policy.ReviewEvidence do
  @moduledoc """
  Builds the stable evidence bundle used by Cycle review policy.

  This module only gathers and normalizes evidence. It does not run model
  judgement, write Linear comments, or move issues between states.
  """

  alias Cycle.Linear.Client
  alias Cycle.RunStore
  alias Cycle.RunStore.Run

  defmodule MissingEvidence do
    @moduledoc "Structured reason for evidence that could not be collected."
    defstruct [:code, :message, :required, details: %{}]
  end

  defmodule Evidence do
    @moduledoc "Review evidence collected for one Linear issue."
    defstruct [
      :issue,
      :labels,
      :comments,
      :workpad,
      :run,
      :git,
      :workflow_policy_version,
      :global_policy_version,
      missing: [],
      stable_hash_input: %{}
    ]
  end

  @workpad_heading "## Codex Workpad"

  @doc """
  Builds review evidence for an issue.

  Options:

    * `:run_store_path` - path to the Cycle run registry.
    * `:workspace_path` - explicit workspace path. Falls back to latest run.
    * `:workflow_policy_version` - caller supplied workflow/policy version.
    * `:global_policy_version` - caller supplied global policy version.
    * `:code_changing?` - when true, missing run/git evidence is required.
  """
  def build(issue, %Client{} = client, opts \\ []) when is_map(issue) do
    code_changing? = Keyword.get(opts, :code_changing?, true)

    {comments, comment_missing} = fetch_comments(client, issue)
    workpad = latest_workpad(comments)
    {run, run_missing} = load_run(issue, Keyword.get(opts, :run_store_path), code_changing?)
    workspace_path = Keyword.get(opts, :workspace_path) || run_workspace_path(run)
    {git, git_missing} = inspect_workspace(workspace_path, code_changing?)

    evidence = %Evidence{
      issue: normalize_issue(issue),
      labels: normalize_labels(issue),
      comments: summarize_comments(comments),
      workpad: summarize_workpad(workpad),
      run: summarize_run(run),
      git: git,
      workflow_policy_version: Keyword.get(opts, :workflow_policy_version),
      global_policy_version: Keyword.get(opts, :global_policy_version),
      missing: comment_missing ++ run_missing ++ git_missing
    }

    %{evidence | stable_hash_input: stable_hash_input(evidence)}
  end

  @doc """
  Returns the latest `## Codex Workpad` comment, when present.
  """
  def latest_workpad(comments) when is_list(comments) do
    comments
    |> Enum.filter(&workpad_comment?/1)
    |> Enum.max_by(&comment_sort_key/1, fn -> nil end)
  end

  @doc """
  Inspects a workspace git checkout with safe git arguments.
  """
  def inspect_workspace(nil, required?) do
    {nil, maybe_required_missing(:missing_workspace, "workspace path is missing", required?)}
  end

  def inspect_workspace(path, required?) when is_binary(path) do
    cond do
      Path.type(path) != :absolute ->
        {nil,
         maybe_required_missing(
           :invalid_workspace_path,
           "workspace path must be absolute",
           required?,
           %{
             "path" => path
           }
         )}

      not File.dir?(path) ->
        {nil,
         maybe_required_missing(:missing_workspace, "workspace path does not exist", required?, %{
           "path" => path
         })}

      true ->
        inspect_git(path, required?)
    end
  end

  def stable_hash_input(%Evidence{} = evidence) do
    %{
      "issue" => evidence.issue,
      "labels" => evidence.labels,
      "comments" => evidence.comments,
      "workpad" => evidence.workpad,
      "run" => evidence.run,
      "git" => evidence.git,
      "workflow_policy_version" => evidence.workflow_policy_version,
      "global_policy_version" => evidence.global_policy_version,
      "missing" => Enum.map(evidence.missing, &missing_to_map/1)
    }
  end

  defp fetch_comments(client, issue) do
    case Client.list_comments(client, issue_id(issue)) do
      {:ok, comments} ->
        {comments, []}

      {:error, reason} ->
        {[],
         [
           missing(
             :linear_comments_unavailable,
             "Linear comments could not be fetched",
             true,
             %{"reason" => inspect(reason)}
           )
         ]}
    end
  end

  defp load_run(_issue, nil, required?) do
    {nil, maybe_required_missing(:missing_run_store, "run store path is missing", required?)}
  end

  defp load_run(issue, path, required?) when is_binary(path) do
    case RunStore.load(path) do
      {:ok, registry} ->
        case latest_run_for_issue(registry.runs, issue) do
          nil ->
            {nil,
             maybe_required_missing(
               :missing_run_evidence,
               "no run evidence found for issue",
               required?
             )}

          %Run{} = run ->
            {run, []}
        end

      {:error, reason} ->
        {nil,
         maybe_required_missing(
           :run_store_unavailable,
           "run store could not be loaded",
           required?,
           %{
             "reason" => inspect(reason)
           }
         )}
    end
  end

  defp latest_run_for_issue(runs, issue) do
    runs
    |> Enum.filter(&run_matches_issue?(&1, issue))
    |> Enum.max_by(&run_sort_key/1, fn -> nil end)
  end

  defp run_matches_issue?(%Run{} = run, issue) do
    run.issue["id"] == issue_id(issue) or run.issue["identifier"] == issue_identifier(issue)
  end

  defp inspect_git(path, required?) do
    with {:ok, _inside} <- git(path, ["rev-parse", "--is-inside-work-tree"]),
         {:ok, branch} <- git(path, ["branch", "--show-current"]),
         {:ok, head} <- git(path, ["rev-parse", "--short", "HEAD"]),
         {:ok, tracked} <- git(path, ["diff", "--name-only", "HEAD", "--"]),
         {:ok, untracked} <- git(path, ["ls-files", "--others", "--exclude-standard"]) do
      changed_files =
        (lines(tracked) ++ lines(untracked))
        |> Enum.uniq()
        |> Enum.sort()

      {%{
         "workspace_path" => path,
         "branch" => String.trim(branch),
         "head" => String.trim(head),
         "changed_files" => changed_files,
         "has_changes" => changed_files != []
       }, []}
    else
      {:error, {args, output}} ->
        {nil,
         maybe_required_missing(
           :git_state_unavailable,
           "workspace git state could not be inspected",
           required?,
           %{
             "args" => args,
             "output" => String.trim(output)
           }
         )}
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {args, output}}
    end
  end

  defp normalize_issue(issue) do
    %{
      "id" => issue_id(issue),
      "identifier" => issue_identifier(issue),
      "title" => get_value(issue, :title, "title"),
      "state" => get_value(issue, :state, "state")
    }
  end

  defp normalize_labels(issue), do: get_value(issue, :labels, "labels") || []

  defp summarize_comments(comments) do
    comments
    |> Enum.map(fn comment ->
      %{
        "id" => get_value(comment, :id, "id"),
        "body_hash" => hash(get_value(comment, :body, "body") || ""),
        "user_name" => get_value(comment, :user_name, "user_name")
      }
    end)
  end

  defp summarize_workpad(nil), do: nil

  defp summarize_workpad(comment) do
    %{
      "id" => get_value(comment, :id, "id"),
      "body_hash" => hash(get_value(comment, :body, "body") || ""),
      "url" => get_value(comment, :url, "url")
    }
  end

  defp summarize_run(nil), do: nil

  defp summarize_run(%Run{} = run) do
    %{
      "id" => run.id,
      "state" => run.state,
      "issue" => Map.take(run.issue, ["id", "identifier"]),
      "project" => Map.take(run.project, ["id", "name"]),
      "engine" => Map.take(run.engine, ["id", "name"]),
      "workflow_path" => run.workflow_path,
      "workflow_hash" => run.workflow_hash,
      "workspace_path" => run.workspace_path,
      "retry" => run.retry,
      "last_event" => run.last_event,
      "evidence" => run.evidence
    }
  end

  defp workpad_comment?(comment) do
    body = get_value(comment, :body, "body") || ""
    String.contains?(body, @workpad_heading)
  end

  defp comment_sort_key(comment) do
    get_value(comment, :updated_at, "updated_at") ||
      get_value(comment, :created_at, "created_at") ||
      get_value(comment, :id, "id") ||
      ""
  end

  defp run_sort_key(%Run{} = run) do
    run.timestamps["updated_at"] || run.timestamps["created_at"] || run.id
  end

  defp run_workspace_path(nil), do: nil
  defp run_workspace_path(%Run{} = run), do: run.workspace_path

  defp issue_id(issue), do: get_value(issue, :id, "id")
  defp issue_identifier(issue), do: get_value(issue, :identifier, "identifier")

  defp get_value(%struct{} = value, atom_key, _string_key) when is_atom(struct),
    do: Map.get(value, atom_key)

  defp get_value(map, atom_key, string_key) when is_map(map),
    do: Map.get(map, atom_key) || Map.get(map, string_key)

  defp maybe_required_missing(_code, _message, false), do: []

  defp maybe_required_missing(code, message, true, details \\ %{}),
    do: [missing(code, message, true, details)]

  defp missing(code, message, required, details) do
    %MissingEvidence{
      code: code,
      message: message,
      required: required,
      details: details
    }
  end

  defp missing_to_map(%MissingEvidence{} = missing) do
    %{
      "code" => Atom.to_string(missing.code),
      "message" => missing.message,
      "required" => missing.required,
      "details" => missing.details
    }
  end

  defp lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp hash(body) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end
end
