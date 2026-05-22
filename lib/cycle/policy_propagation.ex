defmodule Cycle.PolicyPropagation do
  @moduledoc """
  Prepares narrow workflow policy patches from persisted drift records.
  """

  alias Cycle.ProjectRegistry.Project

  defmodule Patch do
    @moduledoc false
    defstruct project: nil, workflow_path: nil, original: nil, updated: nil, diff: nil
  end

  @spec prepare(Project.t()) :: {:ok, Patch.t()} | {:error, String.t()}
  def prepare(%Project{} = project) do
    with {:ok, records} <- drift_records(project),
         {:ok, workflow_path} <- workflow_path(project),
         {:ok, original} <- File.read(workflow_path),
         {:ok, updated} <- update_workflow(original, records) do
      {:ok,
       %Patch{
         project: project,
         workflow_path: workflow_path,
         original: original,
         updated: updated,
         diff: unified_diff(workflow_path, original, updated)
       }}
    else
      {:error, %File.Error{reason: reason, path: path}} ->
        {:error, "cannot read workflow #{path}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec apply(Patch.t(), keyword()) :: :ok | {:error, String.t()}
  def apply(%Patch{} = patch, opts \\ []) do
    with :ok <- require_clean_worktree(patch.workflow_path, opts) do
      File.write(patch.workflow_path, patch.updated)
    end
  end

  def find_project(projects, selector) when is_list(projects) and is_binary(selector) do
    normalized = normalize(selector)

    Enum.find(projects, fn project ->
      [
        project.namespace,
        project.metadata_namespace,
        get_in(project.linear_project || %{}, ["id"]),
        get_in(project.linear_project || %{}, ["name"]),
        get_in(project.linear_project || %{}, ["slug"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize/1)
      |> Enum.member?(normalized)
    end)
  end

  defp drift_records(%Project{} = project) do
    records = get_in(project.policy_drift || %{}, ["records"]) || []
    records = Enum.filter(records, &(Map.get(&1, "propagation_available") == true))

    if records == [] do
      {:error, "project has no propagation-available policy drift records"}
    else
      {:ok, records}
    end
  end

  defp workflow_path(%Project{workflow: workflow}) when is_map(workflow) do
    case Map.get(workflow, "resolved_path") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, "project workflow resolved_path is missing"}
    end
  end

  defp update_workflow(content, records) do
    with {:ok, yaml, body} <- split_front_matter(content),
         {:ok, data} <- parse_yaml(yaml),
         {:ok, updated_yaml} <- apply_records(yaml, data, records) do
      {:ok, ["---\n", updated_yaml, "---", body] |> IO.iodata_to_binary()}
    end
  end

  defp split_front_matter(content) do
    case String.split(content, "\n", parts: 2) do
      ["---", rest] ->
        case String.split(rest, "\n---", parts: 2) do
          [yaml, body] -> {:ok, yaml, body}
          [_] -> {:error, "workflow is missing closing YAML front matter marker"}
        end

      _ ->
        {:error, "workflow is missing YAML front matter"}
    end
  end

  defp parse_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _data} -> {:error, "workflow YAML front matter must be a mapping"}
      {:error, reason} -> {:error, "workflow YAML is invalid: #{format_yaml_error(reason)}"}
    end
  end

  defp apply_records(yaml, data, records) do
    Enum.reduce_while(records, {:ok, yaml, data}, fn record, {:ok, yaml_acc, data_acc} ->
      case drift_path(record) do
        {:ok, path} ->
          updated_data = put_in_path(data_acc, path, Map.get(record, "desired"))
          {:cont, {:ok, edit_yaml(yaml_acc, path, Map.get(record, "desired")), updated_data}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, yaml, _data} -> {:ok, yaml}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drift_path(%{"path" => "agent." <> rest}), do: {:ok, ["agent" | String.split(rest, ".")]}

  defp drift_path(%{"path" => "review_judge." <> rest}),
    do: {:ok, ["review_judge" | String.split(rest, ".")]}

  defp drift_path(%{"path" => "codex." <> rest}), do: {:ok, ["codex" | String.split(rest, ".")]}
  defp drift_path(%{"path" => "engine." <> rest}), do: {:ok, ["engine" | String.split(rest, ".")]}

  defp drift_path(%{"path" => path}),
    do: {:error, "policy drift path is not eligible for propagation: #{path}"}

  defp drift_path(_record), do: {:error, "policy drift record is missing path"}

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value) do
    nested =
      case Map.get(map, key) do
        existing when is_map(existing) -> existing
        _ -> %{}
      end

    Map.put(map, key, put_in_path(nested, rest, value))
  end

  defp edit_yaml(yaml, [section, key], value) do
    lines = String.split(yaml, "\n", trim: false)
    scalar = encode_scalar(value)

    case section_bounds(lines, section) do
      nil ->
        append_section(lines, section, key, scalar)

      {start_index, end_index} ->
        case find_key(lines, start_index + 1, end_index, key) do
          nil -> insert_key(lines, end_index, key, scalar)
          key_index -> List.replace_at(lines, key_index, "  #{key}: #{scalar}")
        end
    end
    |> Enum.join("\n")
  end

  defp edit_yaml(yaml, _path, _value), do: yaml

  defp section_bounds(lines, section) do
    start_index = Enum.find_index(lines, &(&1 == "#{section}:"))

    if start_index do
      end_index =
        lines
        |> Enum.with_index()
        |> Enum.drop(start_index + 1)
        |> Enum.find_value(length(lines), fn {line, index} ->
          if top_level_key?(line), do: index, else: nil
        end)

      {start_index, end_index}
    end
  end

  defp find_key(lines, start_index, end_index, key) do
    start_index..(end_index - 1)
    |> Enum.find(fn index -> Enum.at(lines, index) =~ ~r/^  #{Regex.escape(key)}:/ end)
  end

  defp insert_key(lines, index, key, scalar),
    do: List.insert_at(lines, index, "  #{key}: #{scalar}")

  defp append_section(lines, section, key, scalar) do
    lines
    |> trim_trailing_blank()
    |> Kernel.++(["#{section}:", "  #{key}: #{scalar}", ""])
  end

  defp trim_trailing_blank(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp top_level_key?(line), do: Regex.match?(~r/^[A-Za-z0-9_-]+:/, line)

  defp encode_scalar(nil), do: "null"
  defp encode_scalar(true), do: "true"
  defp encode_scalar(false), do: "false"
  defp encode_scalar([]), do: "[]"
  defp encode_scalar(map) when is_map(map) and map_size(map) == 0, do: "{}"
  defp encode_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)

  defp encode_scalar(value) when is_binary(value) do
    cond do
      value == "" -> ~s("")
      Regex.match?(~r/^[A-Za-z0-9_@.\/:-]+$/, value) -> value
      true -> inspect(value)
    end
  end

  defp encode_scalar(value) do
    raise ArgumentError, "unsupported workflow policy value: #{inspect(value)}"
  end

  defp unified_diff(_path, original, original), do: ""

  defp unified_diff(path, original, updated) do
    original_lines = String.split(original, "\n")
    updated_lines = String.split(updated, "\n")

    [
      "--- a/#{Path.basename(path)}\n",
      "+++ b/#{Path.basename(path)}\n",
      "@@ -1,#{length(original_lines)} +1,#{length(updated_lines)} @@\n",
      Enum.map(original_lines, &["-", &1, "\n"]),
      Enum.map(updated_lines, &["+", &1, "\n"])
    ]
    |> IO.iodata_to_binary()
  end

  defp require_clean_worktree(path, opts) do
    if Keyword.get(opts, :allow_dirty, false) do
      :ok
    else
      repo = repo_root(path)

      case System.cmd("git", ["-C", repo, "status", "--porcelain"], stderr_to_stdout: true) do
        {"", 0} ->
          :ok

        {_output, 0} ->
          {:error, "refusing to apply policy propagation in dirty worktree"}

        {output, _status} ->
          {:error, "cannot inspect workflow git status: #{String.trim(output)}"}
      end
    end
  end

  defp repo_root(path) do
    case System.cmd("git", ["-C", Path.dirname(path), "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {root, 0} -> String.trim(root)
      _ -> Path.dirname(path)
    end
  end

  defp normalize(value), do: value |> String.downcase() |> String.trim()
  defp format_yaml_error(reason) when is_binary(reason), do: reason
  defp format_yaml_error(reason), do: inspect(reason)
end
