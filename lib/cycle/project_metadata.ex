defmodule Cycle.ProjectMetadata do
  @moduledoc """
  Parser and validator for Cycle Linear project metadata.
  """

  @default_workflow "WORKFLOW.md"

  @type error :: %{path: String.t(), reason: String.t()}

  defstruct [
    :repo_url,
    :repo_full_name,
    :workflow_path,
    :policy_profile,
    :source,
    allowed_engines: [],
    capacity: %{},
    unknown_fields: %{},
    warnings: []
  ]

  @type t :: %__MODULE__{
          repo_url: String.t(),
          repo_full_name: String.t(),
          workflow_path: String.t(),
          allowed_engines: [String.t()],
          policy_profile: String.t() | nil,
          capacity: map(),
          unknown_fields: map(),
          source: %{namespace: String.t(), field: String.t(), line: pos_integer()},
          warnings: [String.t()]
        }

  @spec parse(String.t(), keyword()) ::
          {:ok, t()} | :not_opted_in | {:error, [error()]}
  def parse(source, opts \\ []) when is_binary(source) do
    field = opts[:field] || "metadata"

    case extract_cycle_block(source) do
      nil ->
        :not_opted_in

      %{yaml: yaml, line: line} ->
        parse_block(yaml, field, line)
    end
  end

  defp extract_cycle_block(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while(nil, fn {line, line_number}, _acc ->
      if Regex.match?(~r/^cycle:\s*(?:#.*)?$/, line) do
        {:halt, block_from(source, line_number)}
      else
        {:cont, nil}
      end
    end)
  end

  defp block_from(source, start_line) do
    lines = String.split(source, "\n")

    yaml =
      lines
      |> Enum.drop(start_line - 1)
      |> Enum.reduce_while([], fn line, acc ->
        cond do
          acc == [] ->
            {:cont, [line | acc]}

          String.trim(line) == "" ->
            {:cont, [line | acc]}

          String.match?(line, ~r/^[ \t]+/) ->
            {:cont, [line | acc]}

          true ->
            {:halt, acc}
        end
      end)
      |> Enum.reverse()
      |> Enum.join("\n")

    %{yaml: yaml, line: start_line}
  end

  defp parse_block(yaml, field, line) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"cycle" => metadata}} when is_map(metadata) ->
        validate(metadata, field, line)

      {:ok, %{"cycle" => _}} ->
        {:error, [%{path: "cycle", reason: "must be a YAML mapping"}]}

      {:ok, _} ->
        :not_opted_in

      {:error, reason} ->
        {:error, [%{path: "cycle", reason: "invalid YAML: #{format_yaml_error(reason)}"}]}
    end
  end

  defp validate(metadata, field, line) do
    errors =
      []
      |> require_enabled(metadata)
      |> require_repo(metadata)
      |> validate_workflow(metadata)
      |> validate_engines(metadata)
      |> validate_policy(metadata)
      |> validate_capacity(metadata)
      |> reject_token_fields(metadata)

    if errors == [] do
      repo_url = normalize_repo_url(metadata["repo"])

      {:ok,
       %__MODULE__{
         repo_url: repo_url,
         repo_full_name: repo_full_name(repo_url),
         workflow_path: metadata["workflow"] || @default_workflow,
         allowed_engines: metadata["engines"] || [],
         policy_profile: get_in(metadata, ["policy", "review_judge"]),
         capacity: metadata["capacity"] || %{},
         unknown_fields: Map.drop(metadata, known_fields()),
         source: %{namespace: "cycle", field: field, line: line}
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp require_enabled(errors, %{"enabled" => true}), do: errors

  defp require_enabled(errors, %{"enabled" => false}),
    do: [%{path: "cycle.enabled", reason: "must be true to opt in"} | errors]

  defp require_enabled(errors, _),
    do: [%{path: "cycle.enabled", reason: "must be true to opt in"} | errors]

  defp require_repo(errors, %{"repo" => repo}) when is_binary(repo) do
    case normalize_repo_url(repo) do
      nil -> [%{path: "cycle.repo", reason: "must be an HTTPS GitHub repo URL"} | errors]
      _ -> errors
    end
  end

  defp require_repo(errors, _),
    do: [%{path: "cycle.repo", reason: "must be an HTTPS GitHub repo URL"} | errors]

  defp validate_workflow(errors, %{"workflow" => workflow})
       when is_binary(workflow) and workflow != "" do
    if String.starts_with?(workflow, "/") or String.contains?(workflow, "..") do
      [%{path: "cycle.workflow", reason: "must be a repo-relative path"} | errors]
    else
      errors
    end
  end

  defp validate_workflow(errors, %{"workflow" => _}),
    do: [%{path: "cycle.workflow", reason: "must be a non-empty string"} | errors]

  defp validate_workflow(errors, _), do: errors

  defp validate_engines(errors, %{"engines" => engines}) when is_list(engines) do
    if Enum.all?(engines, &(is_binary(&1) and &1 != "")) do
      errors
    else
      [%{path: "cycle.engines", reason: "must contain only non-empty strings"} | errors]
    end
  end

  defp validate_engines(errors, %{"engines" => _}),
    do: [%{path: "cycle.engines", reason: "must be a list of strings"} | errors]

  defp validate_engines(errors, _), do: errors

  defp validate_policy(errors, %{"policy" => policy}) when is_map(policy) do
    case Map.fetch(policy, "review_judge") do
      {:ok, value} when is_binary(value) and value != "" ->
        errors

      {:ok, _} ->
        [%{path: "cycle.policy.review_judge", reason: "must be a non-empty string"} | errors]

      :error ->
        errors
    end
  end

  defp validate_policy(errors, %{"policy" => _}),
    do: [%{path: "cycle.policy", reason: "must be a mapping"} | errors]

  defp validate_policy(errors, _), do: errors

  defp validate_capacity(errors, %{"capacity" => capacity}) when is_map(capacity) do
    errors
    |> validate_positive_integer(
      capacity,
      "max_concurrent_agents",
      "cycle.capacity.max_concurrent_agents"
    )
    |> validate_state_capacity(capacity)
  end

  defp validate_capacity(errors, %{"capacity" => _}),
    do: [%{path: "cycle.capacity", reason: "must be a mapping"} | errors]

  defp validate_capacity(errors, _), do: errors

  defp validate_state_capacity(errors, %{"max_concurrent_agents_by_state" => caps})
       when is_map(caps) do
    Enum.reduce(caps, errors, fn {state, value}, acc ->
      if is_integer(value) and value > 0 do
        acc
      else
        [
          %{
            path: "cycle.capacity.max_concurrent_agents_by_state.#{state}",
            reason: "must be a positive integer"
          }
          | acc
        ]
      end
    end)
  end

  defp validate_state_capacity(errors, %{"max_concurrent_agents_by_state" => _}),
    do: [
      %{path: "cycle.capacity.max_concurrent_agents_by_state", reason: "must be a mapping"}
      | errors
    ]

  defp validate_state_capacity(errors, _), do: errors

  defp validate_positive_integer(errors, map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 -> errors
      {:ok, _} -> [%{path: path, reason: "must be a positive integer"} | errors]
      :error -> errors
    end
  end

  defp reject_token_fields(errors, metadata) do
    metadata
    |> token_field_paths(["cycle"])
    |> Enum.reduce(errors, fn path, acc ->
      [%{path: Enum.join(path, "."), reason: "must not contain secrets or tokens"} | acc]
    end)
  end

  defp token_field_paths(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      key_path = path ++ [to_string(key)]

      nested =
        if is_map(value), do: token_field_paths(value, key_path), else: []

      if Regex.match?(~r/(token|secret|password|api[_-]?key)/i, to_string(key)) do
        [key_path | nested]
      else
        nested
      end
    end)
  end

  defp normalize_repo_url(repo) do
    uri = URI.parse(repo)

    cond do
      uri.scheme != "https" -> nil
      uri.host != "github.com" -> nil
      uri.query || uri.fragment -> nil
      is_nil(uri.path) -> nil
      true -> normalize_github_path(uri.path)
    end
  end

  defp normalize_github_path(path) do
    case String.split(String.trim_leading(path, "/"), "/", trim: true) do
      [owner, repo] ->
        repo = String.trim_trailing(repo, ".git")

        if valid_repo_part?(owner) and valid_repo_part?(repo) do
          "https://github.com/#{owner}/#{repo}.git"
        end

      _ ->
        nil
    end
  end

  defp valid_repo_part?(part), do: Regex.match?(~r/^[A-Za-z0-9_.-]+$/, part)

  defp repo_full_name("https://github.com/" <> rest),
    do: String.trim_trailing(rest, ".git")

  defp known_fields do
    ["enabled", "repo", "workflow", "engines", "policy", "capacity"]
  end

  defp format_yaml_error(reason) when is_binary(reason), do: reason
  defp format_yaml_error(reason), do: inspect(reason)
end
