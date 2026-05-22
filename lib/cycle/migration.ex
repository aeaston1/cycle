defmodule Cycle.Migration do
  @moduledoc """
  Read-only helpers for migrating beside an existing Symphony service.
  """

  alias Cycle.Config

  @systemd_service "symphony.service"
  @launchd_label "symphony"

  @type external_symphony :: map()

  @spec external_symphony(Config.t(), keyword()) :: external_symphony()
  def external_symphony(%Config{} = config, opts \\ []) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    api_get = Keyword.get(opts, :api_get, &Req.get/2)
    status_url = get_in(config.service, ["external_symphony_status_url"])

    service =
      case Keyword.get(opts, :service) do
        nil -> detect_service(command_runner)
        service -> service
      end

    %{
      "configured_status_url" => status_url,
      "api" => api_status(status_url, api_get),
      "service_hint" => service
    }
  end

  @spec detect_service((String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})) ::
          map()
  def detect_service(command_runner \\ &System.cmd/3) do
    cond do
      System.find_executable("systemctl") ->
        systemd_hint(command_runner)

      System.find_executable("launchctl") ->
        launchd_hint(command_runner)

      true ->
        %{
          "manager" => "unknown",
          "name" => nil,
          "state" => "unknown",
          "pid" => nil,
          "file_path" => nil,
          "guidance" => "systemctl or launchctl is required for Symphony service detection"
        }
    end
  end

  defp systemd_hint(command_runner) do
    args = [
      "show",
      @systemd_service,
      "--property=LoadState,ActiveState,MainPID,FragmentPath",
      "--no-page"
    ]

    {output, exit_status} = command_runner.("systemctl", args, stderr_to_stdout: true)
    fields = key_values(output)
    load_state = Map.get(fields, "LoadState")
    active_state = Map.get(fields, "ActiveState")
    pid = fields |> Map.get("MainPID") |> pid()
    file_path = blank_to_nil(Map.get(fields, "FragmentPath"))

    %{
      "manager" => "systemd",
      "name" => @systemd_service,
      "state" => systemd_state(load_state, active_state, exit_status),
      "pid" => pid,
      "file_path" => file_path,
      "guidance" => systemd_guidance(load_state, exit_status)
    }
  end

  defp launchd_hint(command_runner) do
    target = "gui/#{System.get_env("UID") || "501"}/#{@launchd_label}"
    args = ["print", target]
    {output, exit_status} = command_runner.("launchctl", args, stderr_to_stdout: true)

    %{
      "manager" => "launchd",
      "name" => @launchd_label,
      "state" => launchd_state(output, exit_status),
      "pid" => launchd_pid(output),
      "file_path" => nil,
      "guidance" => if(exit_status == 0, do: nil, else: "Symphony launchd service was not found")
    }
  end

  defp api_status(nil, _api_get), do: %{"state" => "not_configured", "url" => nil}
  defp api_status("", _api_get), do: %{"state" => "not_configured", "url" => nil}

  defp api_status(url, api_get) do
    case api_get.(url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> %{"url" => url, "state" => "healthy"}
      {:ok, %{status: status}} -> %{"url" => url, "state" => "unhealthy", "status" => status}
      {:error, _reason} -> %{"url" => url, "state" => "unreachable"}
      _ -> %{"url" => url, "state" => "unknown"}
    end
  end

  defp systemd_state("not-found", _active_state, _exit_status), do: "missing"
  defp systemd_state(_load_state, "active", _exit_status), do: "running"
  defp systemd_state(_load_state, "failed", _exit_status), do: "failed"
  defp systemd_state(_load_state, "inactive", _exit_status), do: "inactive"
  defp systemd_state(_load_state, active_state, 0) when is_binary(active_state), do: active_state
  defp systemd_state(_load_state, _active_state, _exit_status), do: "unknown"

  defp systemd_guidance("not-found", _exit_status), do: "Symphony systemd service was not found"
  defp systemd_guidance(_load_state, 0), do: nil
  defp systemd_guidance(_load_state, _exit_status), do: "systemctl show did not return status"

  defp launchd_state(_output, exit_status) when exit_status != 0, do: "missing"

  defp launchd_state(output, _exit_status) do
    cond do
      output =~ ~r/last exit code = [1-9]/ -> "failed"
      launchd_pid(output) -> "running"
      true -> "inactive"
    end
  end

  defp launchd_pid(output) do
    case Regex.run(~r/\bpid = (\d+)/, output) do
      [_, value] -> pid(value)
      _ -> nil
    end
  end

  defp key_values(output) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  defp pid(nil), do: nil
  defp pid("0"), do: nil

  defp pid(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
