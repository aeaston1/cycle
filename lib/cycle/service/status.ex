defmodule Cycle.Service.Status do
  @moduledoc """
  Read-only service status snapshot for the Cycle background service.
  """

  alias Cycle.Config

  @service_name "cycle.service"
  @launchd_label "homebrew.mxcl.cycle"
  @mutating_verbs ~w(start stop restart reload enable disable bootout bootstrap kickstart unload load)

  @type snapshot :: map()

  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    home = Keyword.get(opts, :home, System.user_home!())
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    api_get = Keyword.get(opts, :api_get, &Req.get/2)

    config =
      case Config.load(env: env, home: home) do
        {:ok, config} -> config
        {:error, errors} -> {:error, errors}
      end

    paths = paths(config, env, home)
    service = service_status(command_runner)

    %{
      "service" => %{
        "name" => service.name,
        "manager" => service.manager,
        "installed" => service.installed,
        "state" => service.state,
        "pid" => service.pid,
        "file_path" => service.file_path,
        "guidance" => service.guidance
      },
      "config_path" => paths.config_path,
      "state_path" => paths.state_path,
      "logs" => log_pointer(config, paths.state_path),
      "api_health" => api_health(config, api_get),
      "engine_health" => engine_health(config, paths.state_path),
      "drift_summary" => drift_summary(config),
      "commands_checked" => service.commands_checked
    }
  end

  @spec mutating_verbs :: [String.t()]
  def mutating_verbs, do: @mutating_verbs

  defp service_status(command_runner) do
    cond do
      System.find_executable("systemctl") ->
        systemd_status(command_runner)

      System.find_executable("launchctl") ->
        launchd_status(command_runner)

      true ->
        %{
          name: @service_name,
          manager: "unknown",
          installed: "unknown",
          state: "unknown",
          pid: nil,
          file_path: nil,
          guidance: "systemctl or launchctl is required for service-manager status",
          commands_checked: []
        }
    end
  end

  defp systemd_status(command_runner) do
    args = [
      "show",
      @service_name,
      "--property=LoadState,ActiveState,SubState,MainPID,FragmentPath",
      "--no-page"
    ]

    {output, exit_status} = command_runner.("systemctl", args, stderr_to_stdout: true)
    fields = key_values(output)
    load_state = Map.get(fields, "LoadState")
    active_state = Map.get(fields, "ActiveState")
    pid = fields |> Map.get("MainPID") |> pid()
    file_path = blank_to_nil(Map.get(fields, "FragmentPath"))

    %{
      name: @service_name,
      manager: "systemd",
      installed: installed?(load_state, exit_status, file_path),
      state: systemd_state(load_state, active_state, exit_status),
      pid: pid,
      file_path: file_path,
      guidance: systemd_guidance(load_state, exit_status),
      commands_checked: [["systemctl" | args]]
    }
  end

  defp launchd_status(command_runner) do
    target = "gui/#{System.get_env("UID") || "501"}/#{@launchd_label}"
    args = ["print", target]
    {output, exit_status} = command_runner.("launchctl", args, stderr_to_stdout: true)

    %{
      name: @launchd_label,
      manager: "launchd",
      installed: if(exit_status == 0, do: true, else: false),
      state: launchd_state(output, exit_status),
      pid: launchd_pid(output),
      file_path: launchd_plist_path(),
      guidance: if(exit_status == 0, do: nil, else: "Cycle launchd service is not loaded"),
      commands_checked: [["launchctl" | args]]
    }
  end

  defp installed?("not-found", _exit_status, _file_path), do: false
  defp installed?(_, 0, file_path) when is_binary(file_path), do: true
  defp installed?(_, 0, _file_path), do: "unknown"
  defp installed?(_, _exit_status, _file_path), do: false

  defp systemd_state("not-found", _active_state, _exit_status), do: "missing"
  defp systemd_state(_load_state, "active", _exit_status), do: "running"
  defp systemd_state(_load_state, "failed", _exit_status), do: "failed"
  defp systemd_state(_load_state, "inactive", _exit_status), do: "inactive"
  defp systemd_state(_load_state, active_state, 0) when is_binary(active_state), do: active_state
  defp systemd_state(_load_state, _active_state, _exit_status), do: "unknown"

  defp systemd_guidance("not-found", _exit_status), do: "Cycle systemd service is not installed"
  defp systemd_guidance(_load_state, 0), do: nil

  defp systemd_guidance(_load_state, _exit_status),
    do: "systemctl show did not return service status"

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

  defp launchd_plist_path do
    homebrew = System.find_executable("brew")

    if homebrew do
      {prefix, 0} = System.cmd(homebrew, ["--prefix"], stderr_to_stdout: true)
      Path.join([String.trim(prefix), "opt", "cycle", "homebrew.mxcl.cycle.plist"])
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp paths(%Config{} = config, _env, _home) do
    %{config_path: config.paths.config_file, state_path: config.paths.state_dir}
  end

  defp paths({:error, _errors}, env, home) do
    %{
      config_path: Cycle.Config.Paths.config_file(env, home),
      state_path: Cycle.Config.Paths.cycle_home(env, home)
    }
  end

  defp log_pointer(%Config{} = config, _state_path) do
    get_in(config.service, ["logs", "path"]) || Path.join(config.paths.logs_dir, "cycle.log")
  end

  defp log_pointer(_config_error, state_path), do: Path.join([state_path, "logs", "cycle.log"])

  defp api_health(%Config{} = config, api_get) do
    url = api_url(config)

    case api_get.(url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> %{"url" => url, "state" => "healthy"}
      {:ok, %{status: status}} -> %{"url" => url, "state" => "unhealthy", "status" => status}
      {:error, _error} -> %{"url" => url, "state" => "unreachable"}
      _ -> %{"url" => url, "state" => "unknown"}
    end
  end

  defp api_health(_config_error, _api_get), do: %{"url" => nil, "state" => "unknown"}

  defp api_url(config) do
    get_in(config.service, ["status_url"]) ||
      "http://#{get_in(config.service, ["api", "bind"]) || "127.0.0.1"}:#{get_in(config.service, ["api", "port"]) || 4765}/health"
  end

  defp engine_health(%Config{} = config, _state_path) do
    default = get_in(config.engines, ["default"]) || "openai-symphony@main"

    case Cycle.EngineId.parse(default) do
      {:ok, engine_id} ->
        path = Cycle.EngineRegistry.install_path(config, engine_id)
        state = if File.dir?(Path.join(path, ".git")), do: "installed", else: "missing"
        %{"default" => default, "path" => path, "state" => state}

      {:error, reason} ->
        %{"default" => default, "path" => nil, "state" => "unknown", "error" => reason}
    end
  end

  defp engine_health(_config_error, state_path) do
    %{"default" => nil, "path" => Path.join(state_path, "engines"), "state" => "unknown"}
  end

  defp drift_summary(%Config{} = config) do
    enabled = get_in(config.policy, ["drift", "report_in_status"])
    %{"state" => if(enabled == false, do: "disabled", else: "not_checked")}
  end

  defp drift_summary(_config_error), do: %{"state" => "unknown"}

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
