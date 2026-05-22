defmodule Cycle.Service.Install do
  @moduledoc """
  Conservative installer for the Cycle background service.
  """

  alias Cycle.Config
  alias Cycle.EngineRegistry
  alias Cycle.Service.Template

  @systemd_service "cycle.service"
  @launchd_label "dev.cycle.agent"
  @valid_platforms [:systemd, :launchd]

  defstruct dry_run: false,
            yes: false,
            platform: nil,
            service_path: nil,
            executable_path: nil,
            command_runner: nil,
            command_finder: nil,
            input_reader: nil,
            env: nil,
            home: nil

  @type result :: %{
          platform: atom(),
          service_path: Path.t(),
          env_file_path: Path.t(),
          rendered_service: String.t(),
          commands: [[String.t()]],
          dry_run: boolean()
        }

  @spec install(keyword()) :: {:ok, result()} | {:error, String.t(), non_neg_integer()}
  def install(opts \\ []) do
    install = struct(__MODULE__, opts)
    env = install.env || System.get_env()
    home = install.home || System.user_home!()
    command_runner = install.command_runner || (&System.cmd/3)
    command_finder = install.command_finder || (&System.find_executable/1)

    with {:ok, config} <- load_config(env, home),
         :ok <- require_linear_auth(config),
         :ok <- require_policy(config),
         {:ok, engine} <- default_engine(config),
         :ok <- require_engine(engine, command_runner, command_finder),
         {:ok, platform} <- platform(install.platform),
         {:ok, executable_path} <- executable_path(install.executable_path),
         paths <- paths(config, platform, install.service_path, home),
         {:ok, rendered} <- render(config, platform, executable_path, paths),
         :ok <- refuse_unrelated_service(paths.service_path, rendered),
         commands <- manager_commands(platform, paths.service_path),
         :ok <- maybe_confirm(install, paths.service_path),
         result <- result(platform, paths, rendered, commands, install.dry_run),
         :ok <- maybe_write(install.dry_run, paths, rendered),
         :ok <- maybe_enable(install.dry_run, commands, command_runner) do
      {:ok, result}
    end
  end

  @spec detect_platform(keyword()) :: {:ok, atom()} | {:error, String.t(), non_neg_integer()}
  def detect_platform(opts \\ []) do
    os_type = Keyword.get(opts, :os_type, :os.type())
    command_finder = Keyword.get(opts, :command_finder, &System.find_executable/1)

    case os_type do
      {:unix, :darwin} ->
        {:ok, :launchd}

      {:unix, :linux} ->
        if command_finder.("systemctl") do
          {:ok, :systemd}
        else
          {:error, "systemd service install requires systemctl", 2}
        end

      other ->
        {:error, "unsupported service platform: #{inspect(other)}", 2}
    end
  end

  defp load_config(env, home) do
    case Config.load(env: env, home: home) do
      {:ok, config} -> {:ok, config}
      {:error, errors} -> {:error, format_errors(errors), 1}
    end
  end

  defp require_linear_auth(%Config{} = config) do
    if present?(config.secrets["linear_api_key"]) do
      :ok
    else
      env = get_in(config.linear, ["api_key_env"]) || "LINEAR_API_KEY"
      {:error, "#{env} is not configured; run cycle linear configure before service install", 1}
    end
  end

  defp require_policy(%Config{} = config) do
    case Cycle.GlobalPolicy.from_config(config) do
      {:ok, _policy} -> :ok
      {:error, errors} -> {:error, "invalid policy config: #{format_errors(errors)}", 3}
    end
  end

  defp default_engine(%Config{} = config) do
    default = get_in(config.engines, ["default"]) || "openai-symphony@main"

    with {:ok, engine_id} <- Cycle.EngineId.parse(default) do
      {:ok, EngineRegistry.default_record(config, engine_id)}
    else
      {:error, reason} -> {:error, "invalid default engine #{default}: #{reason}", 3}
    end
  end

  defp require_engine(engine, command_runner, command_finder) do
    health =
      Cycle.Engine.Health.check(engine,
        command_runner: command_runner,
        command_finder: command_finder,
        status_get: fn _url, _opts -> {:error, :not_checked} end
      )

    case health["state"] do
      "healthy" ->
        :ok

      "missing" ->
        {:error,
         "default engine #{engine.id} is missing at #{engine.install_path}; run cycle symphony install",
         2}

      state ->
        reason = health["reason"] || "engine health check failed"
        {:error, "default engine #{engine.id} is #{state}: #{reason}", 2}
    end
  end

  defp platform(nil), do: detect_platform()
  defp platform(platform) when platform in @valid_platforms, do: {:ok, platform}
  defp platform(platform), do: {:error, "unsupported service platform: #{inspect(platform)}", 2}

  defp executable_path(nil) do
    case System.find_executable("cycle") do
      nil -> {:error, "missing cycle executable; install Cycle before service install", 2}
      path -> {:ok, path}
    end
  end

  defp executable_path(path) when is_binary(path) do
    if File.exists?(path) do
      {:ok, Path.expand(path)}
    else
      {:error, "missing cycle executable: #{path}", 2}
    end
  end

  defp paths(%Config{} = config, platform, service_path, home) do
    env_file_path = Path.join(config.paths.config_dir, "cycle.env")

    %{
      config_path: config.paths.config_file,
      state_path: config.paths.state_dir,
      log_path:
        get_in(config.service, ["logs", "path"]) || Path.join(config.paths.logs_dir, "cycle.log"),
      env_file_path: env_file_path,
      service_path: service_path || default_service_path(platform, home)
    }
  end

  defp default_service_path(:systemd, home),
    do: Path.join([home, ".config", "systemd", "user", @systemd_service])

  defp default_service_path(:launchd, home),
    do: Path.join([home, "Library", "LaunchAgents", "#{@launchd_label}.plist"])

  defp render(config, platform, executable_path, paths) do
    Template.render(
      platform,
      %{
        executable_path: executable_path,
        config_path: paths.config_path,
        state_path: paths.state_path,
        log_path: paths.log_path,
        env_file_path: paths.env_file_path
      }, secrets: [config.secrets["linear_api_key"]])
  end

  defp refuse_unrelated_service(path, rendered) do
    cond do
      !File.exists?(path) ->
        :ok

      File.read!(path) == rendered ->
        :ok

      true ->
        {:error, "refusing to overwrite unrelated existing service file: #{path}", 3}
    end
  end

  defp maybe_confirm(%__MODULE__{dry_run: true}, _path), do: :ok
  defp maybe_confirm(%__MODULE__{yes: true}, _path), do: :ok

  defp maybe_confirm(%__MODULE__{} = install, path) do
    reader = install.input_reader || (&IO.gets/1)

    case reader.("Install Cycle service to #{path}? [y/N] ") do
      input when is_binary(input) ->
        if String.downcase(String.trim(input)) in ["y", "yes"] do
          :ok
        else
          {:error, "service install was not confirmed", 1}
        end

      _ ->
        {:error, "non-interactive service install requires --yes", 1}
    end
  end

  defp maybe_write(true, _paths, _rendered), do: :ok

  defp maybe_write(false, paths, rendered) do
    with :ok <- mkdir_p(Path.dirname(paths.service_path)),
         :ok <- mkdir_p(Path.dirname(paths.env_file_path)),
         :ok <- mkdir_p(Path.dirname(paths.log_path)),
         :ok <- write_file(paths.service_path, rendered),
         :ok <- write_file(paths.env_file_path, env_file(paths)) do
      :ok
    end
  end

  defp maybe_enable(true, _commands, _command_runner), do: :ok

  defp maybe_enable(false, commands, command_runner) do
    Enum.reduce_while(commands, :ok, fn [command | args], :ok ->
      case command_runner.(command, args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:cont, :ok}

        {output, status} ->
          {:halt,
           {:error,
            "service manager command failed: #{Enum.join([command | args], " ")} exited #{status}: #{String.trim(output)}",
            2}}
      end
    end)
  end

  defp manager_commands(:systemd, _path) do
    [
      ["systemctl", "--user", "daemon-reload"],
      ["systemctl", "--user", "enable", @systemd_service]
    ]
  end

  defp manager_commands(:launchd, path) do
    uid = System.get_env("UID") || "501"
    [["launchctl", "bootstrap", "gui/#{uid}", path]]
  end

  defp result(platform, paths, rendered, commands, dry_run) do
    %{
      platform: platform,
      service_path: paths.service_path,
      env_file_path: paths.env_file_path,
      rendered_service: rendered,
      commands: commands,
      dry_run: dry_run
    }
  end

  defp env_file(paths) do
    xdg_config_home = paths.config_path |> Path.dirname() |> Path.dirname()

    """
    CYCLE_HOME=#{paths.state_path}
    XDG_CONFIG_HOME=#{xdg_config_home}
    """
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not create #{path}: #{reason}", 3}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{path}: #{reason}", 3}
    end
  end

  defp format_errors(errors) do
    errors
    |> Enum.map(fn %{path: path, reason: reason} -> "#{path}: #{reason}" end)
    |> Enum.join("; ")
  end

  defp present?(value), do: is_binary(value) && String.trim(value) != ""
end
