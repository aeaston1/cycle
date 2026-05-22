defmodule Cycle.CLI do
  @moduledoc """
  Command-line entrypoint for Cycle.
  """

  @version Mix.Project.config()[:version]
  @default_symphony_repo "https://github.com/openai/symphony.git"
  @default_symphony_ref "main"
  @default_state_url "http://127.0.0.1:4000/api/v1/state"

  @usage """
  Cycle manages OpenAI Symphony engines across Linear projects.

  Usage:
    cycle --version
    cycle help
    cycle doctor
    cycle status [--state-url URL]
    cycle start --workflow PATH [--port PORT] [--version REF] [--dry-run]
    cycle linear configure [--from-env | --api-key TOKEN | --print]
    cycle symphony install [--repo URL] [--version REF]
    cycle symphony path [--version REF]
    cycle project opt-in --repo URL
    cycle project discover [--limit N] [--raw]
    cycle service install
    cycle service status [--json]

  Environment:
    CYCLE_HOME        State directory. Defaults to ~/.local/share/cycle
    XDG_CONFIG_HOME   Config parent. Defaults to ~/.config
    LINEAR_API_KEY    Linear API token used by discovery and Symphony workflows

  Notes:
    cycle project discover --raw prints normalized discovery records as JSON.
  """

  def usage, do: @usage

  def main(args) do
    case run(args) do
      :ok -> :ok
      {:error, message, code} -> halt_error(message, code)
    end
  end

  def run(args) do
    case args do
      [] -> print_usage()
      ["--version"] -> puts("cycle #{@version}")
      ["version"] -> puts("cycle #{@version}")
      ["help"] -> print_usage()
      ["--help"] -> print_usage()
      ["-h"] -> print_usage()
      ["doctor" | rest] -> doctor(rest)
      ["status" | rest] -> status(rest)
      ["start" | rest] -> start(rest)
      ["linear" | rest] -> linear(rest)
      ["symphony" | rest] -> symphony(rest)
      ["project" | rest] -> project(rest)
      ["service" | rest] -> service(rest)
      [command | _] -> {:error, "unknown command: #{command}", 1}
    end
  end

  defp print_usage do
    IO.write(@usage)
    :ok
  end

  defp doctor([]) do
    key = linear_api_key()
    required = ["git", "codex", "mise"]

    puts("Cycle doctor")
    puts("  config: #{config_home()}")
    puts("  state:  #{cycle_home()}")

    failed =
      Enum.reduce(required, false, fn command, failed ->
        case System.find_executable(command) do
          nil ->
            puts("  miss:  #{command}")
            true

          path ->
            puts("  ok:    #{command} (#{path})")
            failed
        end
      end)

    optional("curl", "project discovery and status API checks will be limited")

    if present?(key),
      do: puts("  ok:    LINEAR_API_KEY is configured"),
      else: puts("  warn:  LINEAR_API_KEY is not configured")

    if failed, do: {:error, "doctor found missing required commands", 2}, else: :ok
  end

  defp doctor([arg | _]), do: {:error, "unknown option for doctor: #{arg}", 1}

  defp optional(command, warning) do
    case System.find_executable(command) do
      nil -> puts("  warn:  #{command} is not installed; #{warning}")
      path -> puts("  ok:    #{command} (#{path})")
    end
  end

  defp linear(["configure" | rest]), do: linear_configure(rest)
  defp linear([]), do: {:error, "missing linear subcommand", 1}
  defp linear([sub | _]), do: {:error, "unknown linear subcommand: #{sub}", 1}

  defp linear_configure(args) do
    with {:ok, opts} <-
           parse_options(args, %{}, %{
             "--api-key" => :token,
             "--from-env" => :from_env,
             "--print" => :print
           }) do
      cond do
        Map.get(opts, :print) ->
          puts("config file: #{config_file()}")

          if present?(linear_api_key()),
            do: puts("LINEAR_API_KEY: configured"),
            else: puts("LINEAR_API_KEY: missing")

          :ok

        true ->
          token =
            opts[:token] ||
              if(opts[:from_env],
                do: System.get_env("LINEAR_API_KEY"),
                else: System.get_env("LINEAR_API_KEY")
              )

          cond do
            !present?(token) ->
              {:error,
               "provide --api-key TOKEN or export LINEAR_API_KEY before running configure", 1}

            String.match?(token, ~r/\s/) ->
              {:error, "LINEAR_API_KEY contains whitespace; refusing to write it", 3}

            true ->
              source = if opts[:token], do: :token, else: :env
              write_linear_config(token, source)
          end
      end
    end
  end

  defp write_linear_config(token, source) do
    File.mkdir_p!(config_home())

    content =
      case source do
        :token -> "linear:\n  api_key: #{Jason.encode!(token)}\n"
        :env -> "linear:\n  api_key_env: LINEAR_API_KEY\n"
      end

    File.write!(config_file(), content)
    File.chmod(config_file(), 0o600)
    puts("Saved Linear configuration to #{config_file()}")
  end

  defp symphony(["install" | rest]), do: symphony_install(rest)
  defp symphony(["path" | rest]), do: symphony_path(rest)
  defp symphony([]), do: {:error, "missing symphony subcommand", 1}
  defp symphony([sub | _]), do: {:error, "unknown symphony subcommand: #{sub}", 1}

  defp symphony_install(args) do
    with {:ok, opts} <-
           parse_options(args, %{repo: @default_symphony_repo, ref: @default_symphony_ref}, %{
             "--repo" => :repo,
             "--version" => :ref,
             "--ref" => :ref
           }),
         {:ok, config} <- Cycle.Config.load(cli: engine_cli(opts.repo, opts.ref)),
         {:ok, engine_id} <- engine_id_for(config, opts.ref),
         :ok <- require_command("git") do
      target = Cycle.EngineRegistry.install_path(config, engine_id)
      File.mkdir_p!(Path.dirname(target))

      cond do
        File.dir?(Path.join(target, ".git")) ->
          puts("Symphony engine already exists: #{target}")
          puts("Updating with git fetch and checkout...")

          with :ok <- cmd("git", ["-C", target, "fetch", "--tags", "origin"], 2),
               :ok <- cmd("git", ["-C", target, "checkout", opts.ref], 2) do
            _ =
              System.cmd("git", ["-C", target, "pull", "--ff-only", "origin", opts.ref],
                stderr_to_stdout: true
              )

            verify_symphony_checkout(config, engine_id, target)
          end

        File.exists?(target) ->
          {:error, "target exists but is not a git checkout: #{target}", 3}

        true ->
          puts("Cloning Symphony from #{opts.repo}")

          with :ok <- cmd("git", ["clone", opts.repo, target], 2),
               :ok <- cmd("git", ["-C", target, "checkout", opts.ref], 2) do
            verify_symphony_checkout(config, engine_id, target)
          end
      end
    end
  end

  defp verify_symphony_checkout(config, engine_id, target) do
    if File.exists?(Path.join(target, "elixir/WORKFLOW.md")) do
      with :ok <- record_engine_install(config, engine_id, target) do
        puts("Symphony installed at: #{target}")
        :ok
      end
    else
      {:error, "installed Symphony checkout did not contain elixir/WORKFLOW.md", 3}
    end
  end

  defp symphony_path(args) do
    with {:ok, opts} <-
           parse_options(args, %{ref: @default_symphony_ref}, %{
             "--version" => :ref,
             "--ref" => :ref
           }),
         {:ok, config} <- Cycle.Config.load(),
         {:ok, engine_id} <- engine_id_for(config, opts.ref) do
      registry_path = get_in(config.engines, ["registry_path"])

      engine =
        case Cycle.EngineRegistry.read(registry_path) do
          {:ok, registry} ->
            Cycle.EngineRegistry.find(registry, engine_id) ||
              Cycle.EngineRegistry.default_record(config, engine_id)

          {:error, _error} ->
            Cycle.EngineRegistry.default_record(config, engine_id)
        end

      puts(engine.install_path)
    end
  end

  defp project(["opt-in" | rest]), do: project_opt_in(rest)
  defp project(["discover" | rest]), do: project_discover(rest)
  defp project([]), do: {:error, "missing project subcommand", 1}
  defp project([sub | _]), do: {:error, "unknown project subcommand: #{sub}", 1}

  defp project_opt_in(args) do
    with {:ok, opts} <- parse_options(args, %{}, %{"--repo" => :repo}) do
      if present?(opts[:repo]) do
        puts("cycle:\n  enabled: true\n  repo: #{opts.repo}")
      else
        {:error, "project opt-in requires --repo", 1}
      end
    end
  end

  defp project_discover(args) do
    with {:ok, opts} <-
           parse_options(args, %{limit: "50"}, %{"--limit" => :limit, "--raw" => :raw}),
         :ok <- validate_limit(opts.limit),
         {:ok, config} <- load_config(),
         :ok <- require_configured_linear_key(config) do
      client = Cycle.Linear.Client.new(config)

      case Cycle.ProjectDiscovery.discover(client,
             limit: String.to_integer(opts.limit),
             registry_path: config.projects["registry_path"],
             workflow_resolver: [
               cache_root: config.projects["workflow_cache_path"],
               local_checkout_roots: [File.cwd!()]
             ]
           ) do
        {:ok, result} ->
          if opts[:raw],
            do: print_raw_discovery(result),
            else: print_discovered_projects(result)

        {:error, reason} ->
          {:error, discovery_error(reason), 2}
      end
    end
  end

  defp print_discovered_projects(%Cycle.ProjectDiscovery.Result{records: records} = result) do
    if records == [] do
      puts("No opted-in Linear projects found.")
    else
      puts("NAMESPACE\tNAME\tSLUG\tREPO\tWORKFLOW\tSTATUS\tLAST_ERROR")
      Enum.each(records, fn record -> puts(Enum.join(project_row(record), "\t")) end)
      puts("Wrote #{length(records)} project records to #{result.registry_path}")
    end
  end

  defp print_raw_discovery(%Cycle.ProjectDiscovery.Result{records: records}) do
    records
    |> Enum.map(&Cycle.ProjectRegistry.to_map(%Cycle.ProjectRegistry{projects: [&1]}))
    |> Enum.map(&List.first(&1["projects"]))
    |> Jason.encode!(pretty: true)
    |> puts()
  end

  defp project_row(record) do
    [
      record.metadata_namespace || record.namespace || "",
      get_in(record.linear_project, ["name"]) || "",
      get_in(record.linear_project, ["slug"]) || "",
      get_in(record.repo || %{}, ["url"]) || "",
      get_in(record.workflow || %{}, ["path"]) || "",
      record.status || "",
      record.error || ""
    ]
  end

  defp status(args) do
    with {:ok, opts} <-
           parse_options(args, %{state_url: @default_state_url}, %{"--state-url" => :state_url}),
         {:ok, config} <- Cycle.Config.load(),
         {:ok, engine_id} <- default_engine_id(config) do
      default_engine = Cycle.EngineRegistry.install_path(config, engine_id)
      puts("Cycle status")
      puts("  config: #{config_home()}")
      puts("  state:  #{cycle_home()}")

      if File.dir?(Path.join(default_engine, ".git")),
        do: puts("  engine: installed at #{default_engine}"),
        else: puts("  engine: missing at #{default_engine}")

      if present?(linear_api_key()),
        do: puts("  linear: configured"),
        else: puts("  linear: missing LINEAR_API_KEY")

      case System.find_executable("curl") do
        nil -> puts("  symphony: curl unavailable; skipping status API check")
        _ -> status_api(opts.state_url)
      end
    end
  end

  defp status_api(state_url) do
    case Req.get(state_url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        print_status_payload(payload, state_url)

      _ ->
        puts("  symphony: no status response from #{state_url}")
    end
  end

  defp print_status_payload(payload, _state_url) when is_map(payload) do
    running = payload["running"] || get_in(payload, ["counts", "running"]) || []
    retrying = payload["retrying"] || []
    projects = payload["projects"] || []

    puts("  symphony: reachable")
    puts("  running: #{countish(running)}")
    puts("  retries: #{countish(retrying)}")
    puts("  projects: #{countish(projects)}")
  end

  defp print_status_payload(_payload, state_url),
    do: puts("  symphony: reachable at #{state_url}")

  defp countish(value) when is_list(value), do: length(value)
  defp countish(value), do: value

  defp start(args) do
    with {:ok, opts} <-
           parse_options(args, %{port: "4000", ref: @default_symphony_ref}, %{
             "--workflow" => :workflow,
             "--port" => :port,
             "--version" => :ref,
             "--ref" => :ref,
             "--dry-run" => :dry_run
           }),
         {:ok, config} <- Cycle.Config.load(),
         {:ok, engine_id} <- engine_id_for(config, opts.ref) do
      cond do
        !present?(opts[:workflow]) ->
          {:error, "cycle start requires --workflow PATH", 1}

        true ->
          symphony_bin =
            Path.join([
              Cycle.EngineRegistry.install_path(config, engine_id),
              "elixir",
              "bin",
              "symphony"
            ])

          command = [
            symphony_bin,
            "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
            "--port",
            opts.port,
            opts.workflow
          ]

          cond do
            !File.exists?(symphony_bin) ->
              {:error,
               "missing executable Symphony engine at #{symphony_bin}; run cycle symphony install first",
               2}

            !File.exists?(opts.workflow) ->
              {:error, "workflow file not found: #{opts.workflow}", 1}

            opts[:dry_run] ->
              puts(Enum.join(command, " "))

            true ->
              case System.cmd(symphony_bin, tl(command), into: IO.stream(:stdio, :line)) do
                {_output, 0} -> :ok
                {_output, _status} -> {:error, "Symphony engine exited unsuccessfully", 2}
              end
          end
      end
    end
  end

  defp service(["install"]), do: puts(service_install_text())
  defp service(["status" | rest]), do: service_status(rest)
  defp service([]), do: {:error, "missing service subcommand", 1}
  defp service([sub | _]), do: {:error, "unknown service subcommand: #{sub}", 1}

  defp service_install_text do
    """
    Service installation is not implemented yet.

    Planned backing behavior:
      - generate a launchd plist on macOS
      - generate a systemd unit on Linux
      - point the service at a Cycle-managed Symphony engine
      - require explicit operator confirmation before replacing an existing service
    """
  end

  defp service_status(args) do
    with {:ok, opts} <- parse_options(args, %{}, %{"--json" => :json}) do
      snapshot = Cycle.Service.Status.snapshot()

      if opts[:json] do
        puts(Jason.encode!(snapshot, pretty: true))
      else
        print_service_status(snapshot)
      end
    end
  end

  defp print_service_status(snapshot) do
    service = snapshot["service"]

    puts("Cycle service status")
    puts("  service: #{service["name"]}")
    puts("  manager: #{service["manager"]}")
    puts("  installed: #{service["installed"]}")
    puts("  state: #{service["state"]}")
    puts("  pid: #{service["pid"] || "unknown"}")
    puts("  service file: #{service["file_path"] || "unknown"}")
    puts("  config: #{snapshot["config_path"]}")
    puts("  state path: #{snapshot["state_path"]}")
    puts("  logs: #{snapshot["logs"]}")
    puts("  api: #{snapshot["api_health"]["state"]} #{snapshot["api_health"]["url"] || ""}")
    puts("  engine: #{snapshot["engine_health"]["state"]} #{snapshot["engine_health"]["path"]}")
    puts("  drift: #{snapshot["drift_summary"]["state"]}")

    if service["guidance"], do: puts("  guidance: #{service["guidance"]}")
  end

  defp parse_options([], opts, _spec), do: {:ok, opts}

  defp parse_options([arg | rest], opts, spec) do
    case Map.fetch(spec, arg) do
      {:ok, key} when key in [:from_env, :print, :raw, :dry_run, :json] ->
        parse_options(rest, Map.put(opts, key, true), spec)

      {:ok, key} ->
        case rest do
          [value | tail] -> parse_options(tail, Map.put(opts, key, value), spec)
          [] -> {:error, "#{arg} requires a #{option_value_name(key)}", 1}
        end

      :error ->
        {:error, "unknown option: #{arg}", 1}
    end
  end

  defp option_value_name(:repo), do: "URL"
  defp option_value_name(:token), do: "token"
  defp option_value_name(:ref), do: "ref"
  defp option_value_name(:limit), do: "number"
  defp option_value_name(:state_url), do: "URL"
  defp option_value_name(:workflow), do: "path"
  defp option_value_name(:port), do: "port"
  defp option_value_name(_), do: "value"

  defp require_command(command) do
    if System.find_executable(command),
      do: :ok,
      else: {:error, "missing required command: #{command}", 2}
  end

  defp require_configured_linear_key(%Cycle.Config{} = config) do
    if present?(config.secrets["linear_api_key"]),
      do: :ok,
      else:
        {:error,
         "#{get_in(config.linear, ["api_key_env"]) || "LINEAR_API_KEY"} is not configured", 1}
  end

  defp load_config do
    case Cycle.Config.load() do
      {:ok, config} -> {:ok, config}
      {:error, errors} -> {:error, format_config_errors(errors), 1}
    end
  end

  defp format_config_errors(errors) do
    errors
    |> Enum.map(fn %{path: path, reason: reason} -> "#{path}: #{reason}" end)
    |> Enum.join("; ")
  end

  defp discovery_error({:auth, :missing_token, token_env}), do: "#{token_env} is not configured"

  defp discovery_error({:http, status, _body}),
    do: "Linear API request failed with status #{status}"

  defp discovery_error({:transport, message}), do: "Linear API request failed: #{message}"

  defp discovery_error({:graphql, errors}),
    do: "Linear API returned errors: #{Jason.encode!(errors)}"

  defp discovery_error({:decode, message}), do: "Linear API response decode failed: #{message}"

  defp discovery_error({:rate_limit, status, _body}),
    do: "Linear API request failed with status #{status}"

  defp discovery_error({:encode_failed, message}),
    do: "project registry encode failed: #{message}"

  defp discovery_error({:mkdir_failed, path, reason}), do: "could not create #{path}: #{reason}"
  defp discovery_error({:write_failed, path, reason}), do: "could not write #{path}: #{reason}"

  defp discovery_error({:rename_failed, temp, path, reason}),
    do: "could not replace #{path} from #{temp}: #{reason}"

  defp discovery_error(reason), do: inspect(reason)

  defp validate_limit(limit) do
    if String.match?(to_string(limit), ~r/^[0-9]+$/),
      do: :ok,
      else: {:error, "--limit must be a positive integer", 1}
  end

  defp cmd(command, args, error_code) do
    case System.cmd(command, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _} -> {:error, "#{command} failed", error_code}
    end
  end

  defp cycle_home,
    do: System.get_env("CYCLE_HOME") || Path.join(System.user_home!(), ".local/share/cycle")

  defp config_home,
    do:
      Path.join(
        System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config"),
        "cycle"
      )

  defp config_file, do: Path.join(config_home(), "config.yaml")
  defp legacy_config_file, do: Path.join(config_home(), "config.env")

  defp engine_cli(repo, ref) do
    %{
      "engines" => %{"managed" => %{"openai-symphony" => %{"repo" => repo, "default_ref" => ref}}}
    }
  end

  defp default_engine_id(config) do
    config.engines
    |> Map.get("default", "openai-symphony@main")
    |> Cycle.EngineId.parse()
    |> only_supported_engine()
  end

  defp engine_id_for(config, ref) do
    with {:ok, default} <- default_engine_id(config) do
      Cycle.EngineId.format(default.name, ref)
      |> Cycle.EngineId.parse()
      |> only_supported_engine()
    end
  end

  defp only_supported_engine({:ok, %{name: "openai-symphony"} = engine_id}), do: {:ok, engine_id}

  defp only_supported_engine({:ok, engine_id}),
    do: {:error, "unsupported engine: #{engine_id.name}", 1}

  defp only_supported_engine({:error, reason}), do: {:error, reason, 1}

  defp record_engine_install(config, engine_id, target) do
    registry_path = get_in(config.engines, ["registry_path"])
    lock_path = get_in(config.engines, ["lock_path"])

    with {:ok, registry} <- Cycle.EngineRegistry.read(registry_path),
         {:ok, lock_registry} <- Cycle.EngineRegistry.read_lock(lock_path),
         {:ok, revision} <- resolved_revision(target),
         :ok <-
           Cycle.EngineRegistry.write(
             registry_path,
             Cycle.EngineRegistry.upsert(
               registry,
               %{
                 Cycle.EngineRegistry.default_record(config, engine_id)
                 | health: %{"state" => "healthy"}
               }
             )
           ),
         :ok <-
           Cycle.EngineRegistry.write_lock(
             lock_path,
             Cycle.EngineRegistry.upsert_lock(lock_registry, %Cycle.EngineRegistry.Lock{
               name: engine_id.name,
               ref: engine_id.ref,
               resolved_revision: revision,
               installed_at:
                 DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
             })
           ) do
      :ok
    else
      {:error, {:invalid_yaml, path, reason}} ->
        {:error, "invalid registry YAML at #{path}: #{reason}", 3}

      {:error, {:read_failed, path, reason}} ->
        {:error, "could not read registry #{path}: #{reason}", 3}

      {:error, {:encode_failed, reason}} ->
        {:error, "could not encode engine registry: #{reason}", 3}

      {:error, reason} when is_binary(reason) ->
        {:error, reason, 3}

      {:error, errors} when is_list(errors) ->
        {:error, "invalid engine registry: #{inspect(errors)}", 3}

      other ->
        other
    end
  end

  defp resolved_revision(target) do
    case System.cmd("git", ["-C", target, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> {:ok, String.trim(revision)}
      {_output, _status} -> {:error, "could not resolve installed engine revision"}
    end
  end

  defp linear_api_key do
    System.get_env("LINEAR_API_KEY") || config_linear_api_key_env() ||
      legacy_config_linear_api_key()
  end

  defp config_linear_api_key_env do
    with {:ok, %{"linear" => linear}} <- YamlElixir.read_from_file(config_file()) do
      cond do
        present?(linear["api_key"]) -> linear["api_key"]
        present?(linear["api_key_env"]) -> System.get_env(linear["api_key_env"])
        true -> nil
      end
    else
      _ -> nil
    end
  end

  defp legacy_config_linear_api_key do
    with true <- File.exists?(legacy_config_file()),
         {:ok, content} <- File.read(legacy_config_file()),
         [_, token] <- Regex.run(~r/^LINEAR_API_KEY=['"]?([^'"\n]*)['"]?$/m, content) do
      token
    else
      _ -> nil
    end
  end

  defp present?(value), do: is_binary(value) && value != ""
  defp puts(value), do: IO.puts(value)

  defp halt_error(message, code) do
    IO.puts(:stderr, "cycle: #{message}")
    System.halt(code)
  end
end
