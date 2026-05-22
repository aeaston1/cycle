defmodule Cycle.RunStore do
  @moduledoc """
  Versioned schema for Cycle run registry files.
  """

  alias Cycle.Registry.Schema

  @records_key "runs"
  @known_run_keys [
    "id",
    "issue",
    "project",
    "engine",
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
    "blocked",
    "human_review",
    "merging",
    "done",
    "failed",
    "canceled"
  ]

  defstruct schema_version: Schema.schema_version(), runs: [], extra: %{}

  defmodule Run do
    @moduledoc false
    defstruct id: nil,
              issue: %{},
              project: %{},
              engine: %{},
              workflow_hash: nil,
              workspace_path: nil,
              state: nil,
              timestamps: %{},
              retry: %{},
              last_event: nil,
              evidence: [],
              extra: %{}
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

  defp validate_run(run, path) do
    [
      Schema.required_string(run, "id", path),
      Schema.optional_map(run, "issue", path),
      Schema.optional_map(run, "project", path),
      Schema.optional_map(run, "engine", path),
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
