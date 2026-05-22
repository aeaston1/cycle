defmodule Cycle.ReviewJudgeRegistry do
  @moduledoc """
  Durable, summarized review judge status records.
  """

  alias Cycle.Registry.Schema
  alias Cycle.Registry.Store

  @records_key "records"
  @known_record_keys [
    "id",
    "issue",
    "project",
    "status",
    "decision",
    "reason_code",
    "message",
    "hard_stops",
    "details",
    "timestamps"
  ]
  @statuses ["active", "written", "skipped", "failed"]

  defstruct schema_version: Schema.schema_version(), records: [], extra: %{}

  defmodule Record do
    @moduledoc false
    defstruct id: nil,
              issue: %{},
              project: %{},
              status: nil,
              decision: nil,
              reason_code: nil,
              message: nil,
              hard_stops: [],
              details: %{},
              timestamps: %{},
              extra: %{}
  end

  def path(state_dir), do: Path.join(state_dir, "review_judge.yaml")

  def load(path) do
    with {:ok, raw} <- Store.read(path, empty_map()) do
      from_map(raw)
    end
  end

  def record(path, attrs, opts \\ []) when is_binary(path) and is_map(attrs) do
    with {:ok, registry} <- load(path),
         {:ok, record} <- build_record(attrs, opts),
         :ok <- Store.write(path, to_map(%{registry | records: upsert(registry.records, record)})) do
      {:ok, record}
    end
  end

  def from_map(raw) do
    with {:ok, document} <- Schema.validate_document(raw, @records_key, &validate_record/2) do
      {:ok,
       %__MODULE__{
         schema_version: document.schema_version,
         records: Enum.map(document.records, &record_from_map/1),
         extra: document.extra
       }}
    end
  end

  def to_map(%__MODULE__{} = registry) do
    %{
      "schema_version" => registry.schema_version,
      @records_key => Enum.map(registry.records, &record_to_map/1)
    }
    |> Schema.put_extra(registry.extra)
  end

  defp empty_map, do: %{"schema_version" => Schema.schema_version(), @records_key => []}

  defp build_record(attrs, opts) do
    now = timestamp(opts)

    record = %Record{
      id: Map.get(attrs, "id") || Map.get(attrs, :id) || generate_id(attrs),
      issue: Map.get(attrs, "issue") || Map.get(attrs, :issue) || %{},
      project: Map.get(attrs, "project") || Map.get(attrs, :project) || %{},
      status: Map.get(attrs, "status") || Map.get(attrs, :status),
      decision: Map.get(attrs, "decision") || Map.get(attrs, :decision),
      reason_code: Map.get(attrs, "reason_code") || Map.get(attrs, :reason_code),
      message: Map.get(attrs, "message") || Map.get(attrs, :message),
      hard_stops: Map.get(attrs, "hard_stops") || Map.get(attrs, :hard_stops) || [],
      details: Map.get(attrs, "details") || Map.get(attrs, :details) || %{},
      timestamps:
        Map.get(attrs, "timestamps") || Map.get(attrs, :timestamps) || %{"updated_at" => now}
    }

    case from_map(%{
           "schema_version" => Schema.schema_version(),
           @records_key => [record_to_map(record)]
         }) do
      {:ok, _registry} -> {:ok, record}
      {:error, errors} -> {:error, {:invalid_review_judge_record, errors}}
    end
  end

  defp upsert(records, %Record{} = record) do
    records
    |> Enum.reject(&(&1.id == record.id))
    |> Kernel.++([record])
  end

  defp generate_id(attrs) do
    issue =
      get_in(Map.get(attrs, "issue") || Map.get(attrs, :issue) || %{}, ["identifier"]) || "issue"

    "#{issue}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp validate_record(record, path) do
    [
      Schema.required_string(record, "id", path),
      Schema.optional_map(record, "issue", path),
      Schema.optional_map(record, "project", path),
      Schema.enum(record, "status", @statuses, path),
      Schema.optional_string(record, "decision", path),
      Schema.optional_string(record, "reason_code", path),
      Schema.optional_string(record, "message", path),
      Schema.optional_list(record, "hard_stops", path),
      Schema.optional_map(record, "details", path),
      Schema.optional_map(record, "timestamps", path)
    ]
    |> List.flatten()
  end

  defp record_from_map(map) do
    %Record{
      id: map["id"],
      issue: Map.get(map, "issue", %{}),
      project: Map.get(map, "project", %{}),
      status: map["status"],
      decision: map["decision"],
      reason_code: map["reason_code"],
      message: map["message"],
      hard_stops: Map.get(map, "hard_stops", []),
      details: Map.get(map, "details", %{}),
      timestamps: Map.get(map, "timestamps", %{}),
      extra: Schema.preserve_extra(map, @known_record_keys)
    }
  end

  defp record_to_map(%Record{} = record) do
    %{
      "id" => record.id,
      "issue" => record.issue || %{},
      "project" => record.project || %{},
      "status" => record.status,
      "decision" => record.decision,
      "reason_code" => record.reason_code,
      "message" => record.message,
      "hard_stops" => record.hard_stops || [],
      "details" => record.details || %{},
      "timestamps" => record.timestamps || %{}
    }
    |> Schema.put_extra(record.extra)
  end

  defp timestamp(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = datetime -> DateTime.to_iso8601(DateTime.truncate(datetime, :second))
      value when is_binary(value) -> value
      nil -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end
end
