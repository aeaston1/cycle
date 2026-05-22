defmodule Cycle.Registry.Store do
  @moduledoc """
  Generic YAML-backed registry persistence for Cycle-owned local state.

  Registry files are operator-inspectable YAML files under Cycle state paths by
  default. Writes are atomic within the target directory: encode the full
  payload, write and sync a temporary file, then rename it over the destination.
  """

  alias Cycle.Config.Paths

  @type registry :: :projects | :engines | :engine_locks | :runs
  @type read_error :: {:invalid_yaml, Path.t(), String.t()} | {:read_failed, Path.t(), term()}
  @type write_error ::
          {:encode_failed, String.t()}
          | {:mkdir_failed, Path.t(), term()}
          | {:write_failed, Path.t(), term()}
          | {:rename_failed, Path.t(), Path.t(), term()}

  @doc """
  Returns the default Cycle-owned path for a registry.
  """
  @spec path(registry(), keyword()) :: Path.t()
  def path(registry, opts \\ []) do
    env = Map.new(Keyword.get(opts, :env, System.get_env()))
    home = Keyword.get(opts, :home, System.user_home!())
    cycle_home = Paths.cycle_home(env, home)

    registry_file =
      case registry do
        :projects -> "projects.yaml"
        :engines -> "engines.yaml"
        :engine_locks -> "engines.lock.yaml"
        :runs -> "runs.yaml"
      end

    Path.join(cycle_home, registry_file)
  end

  @doc """
  Reads a YAML registry file, returning `default` when the file does not exist.
  """
  @spec read(Path.t(), term()) :: {:ok, term()} | {:error, read_error()}
  def read(path, default) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, nil} -> {:ok, default}
      {:ok, data} -> {:ok, stringify_keys(data)}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:ok, default}
      {:error, reason} -> {:error, {:invalid_yaml, path, format_error(reason)}}
    end
  rescue
    error in File.Error -> {:error, {:read_failed, path, error.reason}}
  end

  @doc """
  Atomically writes `data` as YAML to `path`.

  Parent directories are created with owner-only permissions. Registry files are
  written with owner read/write permissions.
  """
  @spec write(Path.t(), term(), keyword()) :: :ok | {:error, write_error()}
  def write(path, data, _opts \\ []) when is_binary(path) do
    with {:ok, yaml} <- encode_yaml(data),
         :ok <- ensure_parent(path),
         :ok <- atomic_write(path, yaml) do
      :ok
    end
  end

  defp ensure_parent(path) do
    parent = Path.dirname(path)

    case File.mkdir_p(parent) do
      :ok ->
        _ = File.chmod(parent, 0o700)
        :ok

      {:error, reason} ->
        {:error, {:mkdir_failed, parent, reason}}
    end
  end

  defp atomic_write(path, contents) do
    parent = Path.dirname(path)

    temp_path =
      Path.join(parent, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    case write_temp(temp_path, contents) do
      :ok ->
        case File.rename(temp_path, path) do
          :ok ->
            _ = File.chmod(path, 0o600)
            sync_parent(parent)
            :ok

          {:error, reason} ->
            _ = File.rm(temp_path)
            {:error, {:rename_failed, temp_path, path, reason}}
        end

      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, {:write_failed, temp_path, reason}}
    end
  end

  defp write_temp(path, contents) do
    with {:ok, file} <- File.open(path, [:write, :exclusive]),
         :ok <- IO.binwrite(file, contents),
         :ok <- :file.sync(file),
         :ok <- File.close(file) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  defp sync_parent(parent) do
    case :file.open(String.to_charlist(parent), [:read, :raw]) do
      {:ok, dir} ->
        _ = :file.sync(dir)
        _ = :file.close(dir)
        :ok

      _ ->
        :ok
    end
  end

  defp encode_yaml(data) do
    {:ok, [encode_value(stringify_keys(data), 0), "\n"] |> IO.iodata_to_binary()}
  rescue
    error in ArgumentError -> {:error, {:encode_failed, Exception.message(error)}}
  end

  defp encode_value(map, indent) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} ->
      key = encode_key(key)

      case value do
        nested when is_map(nested) and map_size(nested) > 0 ->
          [spaces(indent), key, ":\n", encode_value(nested, indent + 2)]

        nested when is_list(nested) and nested != [] ->
          [spaces(indent), key, ":\n", encode_value(nested, indent + 2)]

        nested ->
          [spaces(indent), key, ": ", encode_scalar(nested), "\n"]
      end
    end)
  end

  defp encode_value(list, indent) when is_list(list) do
    Enum.map(list, fn
      value when is_map(value) and map_size(value) > 0 ->
        [spaces(indent), "-\n", encode_value(value, indent + 2)]

      value when is_list(value) and value != [] ->
        [spaces(indent), "-\n", encode_value(value, indent + 2)]

      value ->
        [spaces(indent), "- ", encode_scalar(value), "\n"]
    end)
  end

  defp encode_value(value, _indent), do: encode_scalar(value)

  defp encode_key(key) when is_binary(key) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, key), do: key, else: encode_scalar(key)
  end

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
    raise ArgumentError, "unsupported registry value: #{inspect(value)}"
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp spaces(count), do: String.duplicate(" ", count)

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
