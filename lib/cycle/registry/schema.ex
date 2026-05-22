defmodule Cycle.Registry.Schema do
  @moduledoc false

  @schema_version 1
  @secret_key_pattern ~r/(^|_)(api_)?(key|secret|token|password|credential)s?$/i

  def schema_version, do: @schema_version

  def validate_document(raw, records_key, record_validator) when is_binary(records_key) do
    with {:ok, map} <- require_map(raw, "$"),
         {:ok, version} <- validate_schema_version(map),
         {:ok, records} <- require_list(map, records_key) do
      errors =
        map
        |> secret_key_errors("$")
        |> Kernel.++(validate_records(records, records_key, record_validator))

      if errors == [] do
        extra = Map.drop(map, ["schema_version", records_key])
        {:ok, %{schema_version: version, records: records, extra: extra}}
      else
        {:error, errors}
      end
    end
  end

  def validate_schema_version(map) do
    case Map.get(map, "schema_version") do
      @schema_version ->
        {:ok, @schema_version}

      nil ->
        {:error, [error("$.schema_version", "is required")]}

      version when is_integer(version) and version > @schema_version ->
        {:error,
         [
           error(
             "$.schema_version",
             "unsupported future schema version #{version}; upgrade Cycle"
           )
         ]}

      version when is_integer(version) ->
        {:error, [error("$.schema_version", "unsupported schema version #{version}")]}

      _ ->
        {:error, [error("$.schema_version", "must be an integer")]}
    end
  end

  def require_map(value, _path) when is_map(value), do: {:ok, value}
  def require_map(_value, path), do: {:error, [error(path, "must be a mapping")]}

  def require_list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> {:ok, value}
      nil -> {:error, [error("$.#{key}", "is required")]}
      _ -> {:error, [error("$.#{key}", "must be a list")]}
    end
  end

  def required_string(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> []
      nil -> [error("#{path}.#{key}", "is required")]
      _ -> [error("#{path}.#{key}", "must be a non-empty string")]
    end
  end

  def optional_string(map, key, path) do
    case Map.get(map, key) do
      nil -> []
      value when is_binary(value) -> []
      _ -> [error("#{path}.#{key}", "must be a string")]
    end
  end

  def optional_integer(map, key, path) do
    case Map.get(map, key) do
      nil -> []
      value when is_integer(value) -> []
      _ -> [error("#{path}.#{key}", "must be an integer")]
    end
  end

  def optional_map(map, key, path) do
    case Map.get(map, key) do
      nil -> []
      value when is_map(value) -> []
      _ -> [error("#{path}.#{key}", "must be a mapping")]
    end
  end

  def optional_list(map, key, path) do
    case Map.get(map, key) do
      nil -> []
      value when is_list(value) -> []
      _ -> [error("#{path}.#{key}", "must be a list")]
    end
  end

  def enum(map, key, allowed, path) do
    case Map.get(map, key) do
      nil -> [error("#{path}.#{key}", "is required")]
      value -> enum_value_errors(value, allowed, "#{path}.#{key}")
    end
  end

  def optional_enum(map, key, allowed, path) do
    case Map.get(map, key) do
      nil -> []
      value -> enum_value_errors(value, allowed, "#{path}.#{key}")
    end
  end

  def iso8601_utc(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) -> validate_utc_timestamp(value, "#{path}.#{key}")
      nil -> [error("#{path}.#{key}", "is required")]
      _ -> [error("#{path}.#{key}", "must be an ISO 8601 UTC timestamp")]
    end
  end

  def optional_iso8601_utc(map, key, path) do
    case Map.get(map, key) do
      nil -> []
      value when is_binary(value) -> validate_utc_timestamp(value, "#{path}.#{key}")
      _ -> [error("#{path}.#{key}", "must be an ISO 8601 UTC timestamp")]
    end
  end

  def preserve_extra(map, known_keys), do: Map.drop(map, known_keys)

  def put_extra(map, extra) when map_size(extra) == 0, do: map
  def put_extra(map, extra), do: Map.merge(extra, map)

  def secret_key_errors(value, path), do: do_secret_key_errors(value, path)

  def error(path, reason), do: %{path: path, reason: reason}

  defp validate_records(records, records_key, record_validator) do
    records
    |> Enum.with_index()
    |> Enum.flat_map(fn {record, index} ->
      path = "$.#{records_key}[#{index}]"

      case require_map(record, path) do
        {:ok, map} -> record_validator.(map, path) ++ secret_key_errors(map, path)
        {:error, errors} -> errors
      end
    end)
  end

  defp validate_utc_timestamp(value, path) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{time_zone: "Etc/UTC"}, 0} -> []
      {:ok, _datetime, _offset} -> [error(path, "must be in UTC")]
      {:error, _reason} -> [error(path, "must be an ISO 8601 UTC timestamp")]
    end
  end

  defp enum_value_errors(value, allowed, path) do
    if value in allowed do
      []
    else
      [error(path, "must be one of: #{Enum.join(allowed, ", ")}")]
    end
  end

  defp do_secret_key_errors(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      key = to_string(key)
      child_path = "#{path}.#{key}"

      key_errors =
        if Regex.match?(@secret_key_pattern, key),
          do: [error(child_path, "secret fields are not allowed")],
          else: []

      key_errors ++ do_secret_key_errors(value, child_path)
    end)
  end

  defp do_secret_key_errors(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> do_secret_key_errors(value, "#{path}[#{index}]") end)
  end

  defp do_secret_key_errors(_value, _path), do: []
end
