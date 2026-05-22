defmodule Cycle.Log do
  @moduledoc """
  Redacted Cycle runtime logging helpers.
  """

  require Logger

  @doc """
  Creates the configured log directory and stores the active log path.
  """
  def configure(%Cycle.Config{} = config) do
    path = path(config)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      Application.put_env(:cycle, :log_path, path)
      :ok
    end
  end

  def path(%Cycle.Config{} = config) do
    get_in(config.service, ["logs", "path"]) || Path.join(config.paths.logs_dir, "cycle.log")
  end

  def log_event(%Cycle.Config{} = config, level, summary, attrs \\ %{}) do
    event = event(summary, attrs)
    message = format_event(event)

    Logger.log(level, message)
    append(path(config), level, message)

    event
  end

  def event(summary, attrs \\ %{}) do
    attrs
    |> stringify_keys()
    |> redact()
    |> Map.put("summary", redact(summary))
  end

  defdelegate redact(value), to: Cycle.Security

  defp append(path, level, message) do
    line =
      "#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()} #{level} #{message}\n"

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, line, [:append])
    end
  end

  defp format_event(event), do: Jason.encode!(event)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
