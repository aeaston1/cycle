defmodule Cycle.RunStore do
  @moduledoc """
  Versioned schema for Cycle run registry files.
  """

  alias Cycle.Registry.Store
  alias Cycle.Registry.Schema

  @records_key "runs"
  @known_run_keys [
    "id",
    "issue",
    "project",
    "engine",
    "workflow_path",
    "workflow_hash",
    "workspace_path",
    "state",
    "timestamps",
    "retry",
    "last_event",
    "evidence"
  ]
  @states [
    "queued",
    "running",
    "retrying",
    "judging",
    "blocked",
    "completed",
    "failed",
    "cancelled",
    "stale"
  ]
  @terminal_states ["completed", "failed", "cancelled", "stale"]
  @transitions %{
    "queued" => ["running", "blocked", "cancelled", "stale"],
    "running" => ["retrying", "judging", "blocked", "completed", "failed", "cancelled", "stale"],
    "retrying" => ["queued", "running", "failed", "cancelled", "stale"],
    "judging" => ["blocked", "completed", "failed", "cancelled", "stale"],
    "blocked" => ["queued", "retrying", "failed", "cancelled", "stale"],
    "completed" => [],
    "failed" => [],
    "cancelled" => [],
    "stale" => []
  }

  defstruct schema_version: Schema.schema_version(), runs: [], extra: %{}

  defmodule Run do
    @moduledoc false
    defstruct id: nil,
              issue: %{},
              project: %{},
              engine: %{},
              workflow_path: nil,
              workflow_hash: nil,
              workspace_path: nil,
              state: nil,
              timestamps: %{},
              retry: %{},
              last_event: nil,
              evidence: [],
              extra: %{}
  end

  @doc """
  Loads the run registry from `path`.
  """
  def load(path) do
    with {:ok, raw} <- Store.read(path, empty_map()) do
      from_map(raw)
    end
  end

  @doc """
  Creates and persists a queued run record.
  """
  def create_queued(path, attrs, opts \\ []) when is_binary(path) and is_map(attrs) do
    with {:ok, registry} <- load(path),
         {:ok, run} <- build_queued_run(attrs, opts),
         {:ok, registry} <- add_run(registry, run),
         :ok <- persist(path, registry) do
      {:ok, run}
    end
  end

  @doc """
  Transitions a run to a new state and persists the registry.
  """
  def transition(path, run_id, next_state, attrs \\ %{}, opts \\ [])
      when is_binary(path) and is_binary(run_id) and is_binary(next_state) and is_map(attrs) do
    with true <- next_state in @states || {:error, {:invalid_state, next_state}},
         {:ok, registry} <- load(path),
         {:ok, run, before, after_runs} <- take_run(registry.runs, run_id),
         :ok <- validate_transition(run.state, next_state),
         updated <- apply_transition(run, next_state, attrs, opts),
         registry <- %{registry | runs: before ++ [updated | after_runs]},
         :ok <- persist(path, registry) do
      {:ok, updated}
    end
  end

  def from_map(raw) do
    with {:ok, document} <- Schema.validate_document(raw, @records_key, &validate_run/2) do
      {:ok,
       %__MODULE__{
         schema_version: document.schema_version,
         runs: Enum.map(document.records, &run_from_map/1),
         extra: document.extra
       }}
    end
  end

  def validate(raw) do
    case from_map(raw) do
      {:ok, _registry} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  def to_map(%__MODULE__{} = registry) do
    %{
      "schema_version" => registry.schema_version,
      @records_key => Enum.map(registry.runs, &run_to_map/1)
    }
    |> Schema.put_extra(registry.extra)
  end

  def states, do: @states
  def terminal_states, do: @terminal_states

  defp empty_map do
    %{"schema_version" => Schema.schema_version(), @records_key => []}
  end

  defp build_queued_run(attrs, opts) do
    now = timestamp(opts)

    run = %Run{
      id: Map.get(attrs, "id") || Map.get(attrs, :id) || generate_id(),
      issue: required_attr(attrs, "issue"),
      project: required_attr(attrs, "project"),
      engine: required_attr(attrs, "engine"),
      workflow_path: required_attr(attrs, "workflow_path"),
      workflow_hash: required_attr(attrs, "workflow_hash"),
      workspace_path: required_attr(attrs, "workspace_path"),
      state: "queued",
      timestamps: %{"created_at" => now, "updated_at" => now},
      retry: Map.get(attrs, "retry") || Map.get(attrs, :retry) || %{"attempt" => 0},
      last_event: Map.get(attrs, "last_event") || Map.get(attrs, :last_event),
      evidence: Map.get(attrs, "evidence") || Map.get(attrs, :evidence) || []
    }

    case validate(to_map(%__MODULE__{runs: [run]})) do
      :ok -> {:ok, run}
      {:error, errors} -> {:error, {:invalid_run, errors}}
    end
  end

  defp add_run(%__MODULE__{} = registry, %Run{} = run) do
    if Enum.any?(registry.runs, &(&1.id == run.id)) do
      {:error, {:duplicate_run_id, run.id}}
    else
      {:ok, %{registry | runs: registry.runs ++ [run]}}
    end
  end

  defp take_run(runs, run_id) do
    case Enum.split_with(runs, &(&1.id != run_id)) do
      {_before, []} ->
        {:error, {:run_not_found, run_id}}

      {before, [run | after_runs]} ->
        {:ok, run, before, after_runs}
    end
  end

  defp validate_transition(state, next_state) do
    if next_state in Map.fetch!(@transitions, state) do
      :ok
    else
      {:error, {:invalid_transition, state, next_state}}
    end
  end

  defp apply_transition(%Run{} = run, next_state, attrs, opts) do
    now = timestamp(opts)

    timestamps =
      run.timestamps
      |> Map.put("updated_at", now)
      |> maybe_put_timestamp(next_state, now)

    %{
      run
      | state: next_state,
        timestamps: timestamps,
        retry: Map.get(attrs, "retry") || Map.get(attrs, :retry) || run.retry,
        last_event: Map.get(attrs, "last_event") || Map.get(attrs, :last_event) || run.last_event,
        evidence: Map.get(attrs, "evidence") || Map.get(attrs, :evidence) || run.evidence
    }
  end

  defp maybe_put_timestamp(timestamps, "running", now),
    do: Map.put_new(timestamps, "started_at", now)

  defp maybe_put_timestamp(timestamps, state, now) when state in @terminal_states,
    do: Map.put(timestamps, "finished_at", now)

  defp maybe_put_timestamp(timestamps, _state, _now), do: timestamps

  defp persist(path, %__MODULE__{} = registry), do: Store.write(path, to_map(registry))

  defp required_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp timestamp(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = datetime -> DateTime.to_iso8601(DateTime.truncate(datetime, :second))
      value when is_binary(value) -> value
      nil -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  defp generate_id, do: "run-#{System.unique_integer([:positive, :monotonic])}"

  defp validate_run(run, path) do
    [
      Schema.required_string(run, "id", path),
      Schema.optional_map(run, "issue", path),
      Schema.optional_map(run, "project", path),
      Schema.optional_map(run, "engine", path),
      Schema.required_string(run, "workflow_path", path),
      Schema.required_string(run, "workflow_hash", path),
      Schema.required_string(run, "workspace_path", path),
      Schema.enum(run, "state", @states, path),
      Schema.optional_map(run, "timestamps", path),
      Schema.optional_map(run, "retry", path),
      Schema.optional_map(run, "last_event", path),
      Schema.optional_list(run, "evidence", path)
    ]
    |> List.flatten()
    |> Kernel.++(validate_required_id_map(run["issue"], "#{path}.issue", ["id", "identifier"]))
    |> Kernel.++(validate_required_id_map(run["project"], "#{path}.project", ["id", "name"]))
    |> Kernel.++(validate_required_id_map(run["engine"], "#{path}.engine", ["id", "name"]))
    |> Kernel.++(validate_timestamps(run["timestamps"], "#{path}.timestamps"))
  end

  defp validate_required_id_map(nil, path, _keys), do: [Schema.error(path, "is required")]

  defp validate_required_id_map(map, path, keys) when is_map(map) do
    Enum.flat_map(keys, &Schema.required_string(map, &1, path))
  end

  defp validate_required_id_map(_value, _path, _keys), do: []

  defp validate_timestamps(nil, path), do: [Schema.error(path, "is required")]

  defp validate_timestamps(map, path) when is_map(map) do
    [
      Schema.iso8601_utc(map, "created_at", path),
      Schema.optional_iso8601_utc(map, "updated_at", path),
      Schema.optional_iso8601_utc(map, "started_at", path),
      Schema.optional_iso8601_utc(map, "finished_at", path)
    ]
    |> List.flatten()
  end

  defp validate_timestamps(_value, _path), do: []

  defp run_from_map(map) do
    %Run{
      id: map["id"],
      issue: map["issue"],
      project: map["project"],
      engine: map["engine"],
      workflow_path: map["workflow_path"],
      workflow_hash: map["workflow_hash"],
      workspace_path: map["workspace_path"],
      state: map["state"],
      timestamps: map["timestamps"],
      retry: Map.get(map, "retry", %{}),
      last_event: map["last_event"],
      evidence: Map.get(map, "evidence", []),
      extra: Schema.preserve_extra(map, @known_run_keys)
    }
  end

  defp run_to_map(%Run{} = run) do
    %{
      "id" => run.id,
      "issue" => run.issue,
      "project" => run.project,
      "engine" => run.engine,
      "workflow_path" => run.workflow_path,
      "workflow_hash" => run.workflow_hash,
      "workspace_path" => run.workspace_path,
      "state" => run.state,
      "timestamps" => run.timestamps,
      "retry" => run.retry,
      "last_event" => run.last_event,
      "evidence" => run.evidence
    }
    |> Schema.put_extra(run.extra)
  end
end
