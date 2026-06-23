defmodule Cycle.ReviewJudgeRegistry do
  @moduledoc """
  Durable, summarized review judge status records.
  """

  alias Cycle.Registry.Schema
  alias Cycle.Registry.Store

  @records_key "records"
  @external_review_key "external_review"
  @external_review_atom :external_review
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
  @statuses ["active", "completed", "written", "skipped", "failed"]

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

  @doc false
  def sanitize_details(details) when is_map(details) do
    raw_external_review = external_review_value(details)
    details = Map.drop(details, [@external_review_key, @external_review_atom])

    case external_review_summary(raw_external_review) do
      nil -> details
      summary -> Map.put(details, @external_review_key, summary)
    end
  end

  def sanitize_details(details), do: details

  @doc false
  def external_review_summary(raw) when is_map(raw) do
    severity_breakdown = severity_breakdown(raw)

    summary =
      %{}
      |> put_present("provider", summary_string(raw, ["provider", :provider], 120))
      |> put_present("status", summary_string(raw, ["status", :status], 120))
      |> put_present("reason_code", summary_string(raw, ["reason_code", :reason_code], 160))
      |> put_present("findings_count", findings_count(raw, severity_breakdown))
      |> put_present("severity_breakdown", severity_breakdown)
      |> put_present("artifact_path", summary_string(raw, ["artifact_path", :artifact_path], 300))
      |> put_present("log_path", summary_string(raw, ["log_path", :log_path], 300))
      |> put_present("fingerprint", summary_string(raw, ["fingerprint", :fingerprint], 120))
      |> Cycle.Log.redact()

    if map_size(summary) == 0, do: nil, else: summary
  end

  def external_review_summary(_raw), do: nil

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
      details: sanitize_details(Map.get(attrs, "details") || Map.get(attrs, :details) || %{}),
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
      details: sanitize_details(Map.get(map, "details", %{})),
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
      "details" => sanitize_details(record.details || %{}),
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

  defp external_review_value(details) when is_map(details) do
    Map.get(details, @external_review_key) || Map.get(details, @external_review_atom)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp summary_string(map, keys, max) do
    case fetch_any(map, keys) do
      nil ->
        nil

      value when is_binary(value) or is_atom(value) or is_number(value) ->
        value
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> empty_to_nil()
        |> slice(max)

      _value ->
        nil
    end
  end

  defp findings_count(raw, severity_breakdown) do
    cond do
      count = integer_value(fetch_any(raw, ["findings_count", :findings_count])) ->
        count

      count = integer_value(fetch_any(raw, ["finding_count", :finding_count])) ->
        count

      findings = findings(raw) ->
        length(findings)

      is_map(severity_breakdown) and map_size(severity_breakdown) > 0 ->
        severity_breakdown |> Map.values() |> Enum.sum()

      true ->
        nil
    end
  end

  defp severity_breakdown(raw) do
    cond do
      counts = fetch_any(raw, ["severity_breakdown", :severity_breakdown]) ->
        normalize_severity_counts(counts)

      counts = fetch_any(raw, ["severity_counts", :severity_counts]) ->
        normalize_severity_counts(counts)

      findings = findings(raw) ->
        findings
        |> Enum.map(&summary_string(&1, ["severity", :severity], 80))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      true ->
        nil
    end
  end

  defp normalize_severity_counts(counts) when is_map(counts) do
    counts
    |> Enum.reduce(%{}, fn {severity, count}, acc ->
      with severity when is_binary(severity) <- severity_key(severity),
           count when is_integer(count) <- integer_value(count) do
        Map.put(acc, severity, count)
      else
        _ -> acc
      end
    end)
  end

  defp normalize_severity_counts(_counts), do: nil

  defp findings(raw) do
    case fetch_any(raw, ["findings", :findings]) do
      findings when is_list(findings) -> Enum.filter(findings, &is_map/1)
      _ -> nil
    end
  end

  defp fetch_any(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  defp integer_value(value) when is_integer(value) and value >= 0, do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> count
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp severity_key(value) when is_atom(value), do: value |> Atom.to_string() |> severity_key()

  defp severity_key(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> empty_to_nil()
  end

  defp severity_key(_value), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp slice(nil, _max), do: nil
  defp slice(value, max), do: String.slice(value, 0, max)
end
