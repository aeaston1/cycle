defmodule Cycle.WorkflowPolicy do
  @moduledoc """
  Extracts the Cycle-readable scheduling policy from repo WORKFLOW.md content.
  """

  @type error :: %{path: String.t(), reason: String.t()}

  defstruct [
    :hash,
    agent: %{},
    tracker: %{},
    review_judge: %{},
    worker: %{},
    hooks: nil
  ]

  @type t :: %__MODULE__{
          hash: String.t(),
          agent: map(),
          tracker: map(),
          review_judge: map(),
          worker: map(),
          hooks: term()
        }

  @spec parse(String.t()) :: {:ok, t()} | {:error, [error()]}
  def parse(content) when is_binary(content) do
    with {:ok, yaml} <- front_matter(content),
         {:ok, data} <- parse_yaml(yaml),
         :ok <- require_map(data) do
      extract(data, yaml)
    else
      {:error, reason} when is_binary(reason) -> {:error, [%{path: "workflow", reason: reason}]}
      {:error, errors} when is_list(errors) -> {:error, errors}
    end
  end

  defp front_matter(content) do
    case String.split(content, "\n", parts: 2) do
      ["---", rest] ->
        case String.split(rest, "\n---", parts: 2) do
          [yaml, _body] -> {:ok, yaml}
          [_] -> {:error, "missing YAML front matter"}
        end

      _ ->
        {:error, "missing YAML front matter"}
    end
  end

  defp parse_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        {:error, [%{path: "workflow", reason: "invalid YAML: #{format_yaml_error(reason)}"}]}
    end
  end

  defp require_map(data) when is_map(data), do: :ok
  defp require_map(_data), do: {:error, "YAML front matter must be a mapping"}

  defp extract(data, yaml) do
    errors =
      []
      |> validate_agent(data)
      |> validate_tracker(data)
      |> validate_review_judge(data)
      |> validate_worker(data)

    if errors == [] do
      {:ok,
       %__MODULE__{
         hash: hash(yaml),
         agent: extract_agent(data),
         tracker: extract_tracker(data),
         review_judge: extract_review_judge(data),
         worker: extract_worker(data),
         hooks: Map.get(data, "hooks")
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp validate_agent(errors, %{"agent" => agent}) when is_map(agent) do
    errors
    |> validate_positive_integer(agent, "max_concurrent_agents", "agent.max_concurrent_agents")
    |> validate_positive_integer(agent, "max_turns", "agent.max_turns")
    |> validate_state_capacity(agent)
  end

  defp validate_agent(errors, %{"agent" => _}),
    do: [%{path: "agent", reason: "must be a mapping"} | errors]

  defp validate_agent(errors, _data), do: errors

  defp validate_state_capacity(errors, %{"max_concurrent_agents_by_state" => capacity})
       when is_map(capacity) do
    Enum.reduce(capacity, errors, fn {state, value}, acc ->
      cond do
        not is_binary(state) or String.trim(state) == "" ->
          [
            %{
              path: "agent.max_concurrent_agents_by_state",
              reason: "state names must be non-empty strings"
            }
            | acc
          ]

        is_integer(value) and value > 0 ->
          acc

        true ->
          [
            %{
              path: "agent.max_concurrent_agents_by_state.#{state}",
              reason: "must be a positive integer"
            }
            | acc
          ]
      end
    end)
  end

  defp validate_state_capacity(errors, %{"max_concurrent_agents_by_state" => _}),
    do: [%{path: "agent.max_concurrent_agents_by_state", reason: "must be a mapping"} | errors]

  defp validate_state_capacity(errors, _agent), do: errors

  defp validate_tracker(errors, %{"tracker" => tracker}) when is_map(tracker) do
    errors
    |> validate_string_list(tracker, "active_states", "tracker.active_states")
    |> validate_string_list(tracker, "terminal_states", "tracker.terminal_states")
  end

  defp validate_tracker(errors, %{"tracker" => _}),
    do: [%{path: "tracker", reason: "must be a mapping"} | errors]

  defp validate_tracker(errors, _data), do: errors

  defp validate_review_judge(errors, %{"review_judge" => review_judge})
       when is_map(review_judge) do
    errors
    |> validate_boolean(review_judge, "enabled", "review_judge.enabled")
    |> validate_string(review_judge, "source_state", "review_judge.source_state")
    |> validate_string(review_judge, "review_state", "review_judge.review_state")
    |> validate_string(review_judge, "proceed_state", "review_judge.proceed_state")
    |> validate_string(review_judge, "policy", "review_judge.policy")
    |> validate_number(
      review_judge,
      "minimum_skip_confidence",
      "review_judge.minimum_skip_confidence"
    )
    |> validate_boolean(
      review_judge,
      "hard_require_human_review",
      "review_judge.hard_require_human_review"
    )
  end

  defp validate_review_judge(errors, %{"review_judge" => _}),
    do: [%{path: "review_judge", reason: "must be a mapping"} | errors]

  defp validate_review_judge(errors, _data), do: errors

  defp validate_worker(errors, %{"worker" => worker}) when is_map(worker) do
    errors
    |> validate_string_list(worker, "ssh_hosts", "worker.ssh_hosts")
    |> validate_positive_integer(
      worker,
      "max_concurrent_agents_per_host",
      "worker.max_concurrent_agents_per_host"
    )
  end

  defp validate_worker(errors, %{"worker" => _}),
    do: [%{path: "worker", reason: "must be a mapping"} | errors]

  defp validate_worker(errors, _data), do: errors

  defp extract_agent(data) do
    case Map.get(data, "agent") do
      agent when is_map(agent) ->
        %{}
        |> maybe_put(agent, "max_concurrent_agents")
        |> maybe_put(agent, "max_turns")
        |> maybe_put_capacity(agent)

      _ ->
        %{}
    end
  end

  defp maybe_put_capacity(result, %{"max_concurrent_agents_by_state" => capacity})
       when is_map(capacity) do
    Map.put(
      result,
      "max_concurrent_agents_by_state",
      Map.new(capacity, fn {state, value} -> {normalize_state_name(state), value} end)
    )
  end

  defp maybe_put_capacity(result, _agent), do: result

  defp extract_tracker(data) do
    case Map.get(data, "tracker") do
      tracker when is_map(tracker) ->
        %{}
        |> maybe_put(tracker, "active_states")
        |> maybe_put(tracker, "terminal_states")

      _ ->
        %{}
    end
  end

  defp extract_review_judge(data) do
    case Map.get(data, "review_judge") do
      review_judge when is_map(review_judge) ->
        copy_keys(review_judge, [
          "enabled",
          "source_state",
          "review_state",
          "proceed_state",
          "policy",
          "minimum_skip_confidence",
          "hard_require_human_review"
        ])

      _ ->
        %{}
    end
  end

  defp extract_worker(data) do
    case Map.get(data, "worker") do
      worker when is_map(worker) ->
        copy_keys(worker, ["ssh_hosts", "max_concurrent_agents_per_host"])

      _ ->
        %{}
    end
  end

  defp maybe_put(result, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(result, key, value)
      :error -> result
    end
  end

  defp copy_keys(source, keys) do
    Enum.reduce(keys, %{}, &maybe_put(&2, source, &1))
  end

  defp validate_positive_integer(errors, map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 -> errors
      {:ok, _value} -> [%{path: path, reason: "must be a positive integer"} | errors]
      :error -> errors
    end
  end

  defp validate_string_list(errors, map, key, path) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          errors
        else
          [%{path: path, reason: "must contain only non-empty strings"} | errors]
        end

      {:ok, _value} ->
        [%{path: path, reason: "must be a list of strings"} | errors]

      :error ->
        errors
    end
  end

  defp validate_string(errors, map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> errors
      {:ok, _value} -> [%{path: path, reason: "must be a non-empty string"} | errors]
      :error -> errors
    end
  end

  defp validate_boolean(errors, map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> errors
      {:ok, _value} -> [%{path: path, reason: "must be a boolean"} | errors]
      :error -> errors
    end
  end

  defp validate_number(errors, map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_number(value) -> errors
      {:ok, _value} -> [%{path: path, reason: "must be a number"} | errors]
      :error -> errors
    end
  end

  defp normalize_state_name(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp hash(yaml), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, yaml), case: :lower)

  defp format_yaml_error(reason) when is_binary(reason), do: reason
  defp format_yaml_error(reason), do: inspect(reason)
end
