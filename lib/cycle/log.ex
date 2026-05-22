defmodule Cycle.Log do
  @moduledoc """
  Redacted Cycle runtime logging helpers.
  """

  require Logger

  @tokenish_key ~r/(authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret)/i
  @bearer ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]+/i
  @basic ~r/\bBasic\s+[A-Za-z0-9._~+\/=-]+/i
  @assignment ~r/\b([A-Za-z0-9_.-]*(?:token|secret|api[_-]?key)[A-Za-z0-9_.-]*)=([^\s]+)/i
  @long_token ~r/\b(?=[A-Za-z0-9._~+=-]{32,}\b)(?=[A-Za-z0-9._~+=-]*[0-9])[A-Za-z0-9._~+=-]{32,}\b/

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

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if tokenish_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(nested)}
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_binary(value) do
    value
    |> then(&Regex.replace(@bearer, &1, "Bearer [REDACTED]"))
    |> then(&Regex.replace(@basic, &1, "Basic [REDACTED]"))
    |> then(&Regex.replace(@assignment, &1, "\\1=[REDACTED]"))
    |> then(&Regex.replace(@long_token, &1, "[REDACTED]"))
  end

  def redact(value), do: value

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

  defp tokenish_key?(key), do: Regex.match?(@tokenish_key, to_string(key))
end
