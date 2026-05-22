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
    cycle service status

  Environment:
    CYCLE_HOME        State directory. Defaults to ~/.local/share/cycle
    XDG_CONFIG_HOME   Config parent. Defaults to ~/.config
    LINEAR_API_KEY    Linear API token used by discovery and Symphony workflows
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
    optional("ruby", "JSON formatting for discovery/status will be limited")

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
              write_linear_config(token)
          end
      end
    end
  end

  defp write_linear_config(token) do
    File.mkdir_p!(config_home())
    File.write!(config_file(), "LINEAR_API_KEY=#{token}\n")
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
         :ok <- require_command("git") do
      target = engine_dir(opts.ref)
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

            verify_symphony_checkout(target)
          end

        File.exists?(target) ->
          {:error, "target exists but is not a git checkout: #{target}", 3}

        true ->
          puts("Cloning Symphony from #{opts.repo}")

          with :ok <- cmd("git", ["clone", opts.repo, target], 2),
               :ok <- cmd("git", ["-C", target, "checkout", opts.ref], 2) do
            verify_symphony_checkout(target)
          end
      end
    end
  end

  defp verify_symphony_checkout(target) do
    if File.exists?(Path.join(target, "elixir/WORKFLOW.md")) do
      puts("Symphony installed at: #{target}")
      :ok
    else
      {:error, "installed Symphony checkout did not contain elixir/WORKFLOW.md", 3}
    end
  end

  defp symphony_path(args) do
    with {:ok, opts} <-
           parse_options(args, %{ref: @default_symphony_ref}, %{
             "--version" => :ref,
             "--ref" => :ref
           }) do
      puts(engine_dir(opts.ref))
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
         :ok <- require_linear_key(),
         :ok <- require_command("curl"),
         :ok <- require_command("ruby") do
      query =
        "query CycleProjectDiscovery($first: Int!) { projects(first: $first) { nodes { id name slugId url description content } } }"

      variables = ~s({"first":#{opts.limit}})
      body = Jason.encode!(%{query: query, variables: Jason.decode!(variables)})

      case Req.post("https://api.linear.app/graphql",
             headers: [{"authorization", linear_api_key()}, {"content-type", "application/json"}],
             body: body
           ) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          if opts[:raw],
            do: IO.puts(response_body(response)),
            else: print_discovered_projects(response)

        {:ok, %{status: status}} ->
          {:error, "Linear API request failed with status #{status}", 2}

        {:error, error} ->
          {:error, "Linear API request failed: #{Exception.message(error)}", 2}
      end
    end
  end

  defp print_discovered_projects(response) do
    payload = response_payload(response)

    if payload["errors"] do
      IO.puts(:stderr, Jason.encode!(payload["errors"], pretty: true))
      {:error, "Linear API returned errors", 2}
    else
      matches =
        payload
        |> get_in(["data", "projects", "nodes"])
        |> List.wrap()
        |> Enum.flat_map(&project_metadata_row/1)

      if matches == [] do
        puts("No opted-in Linear projects found.")
      else
        puts("NAME\tSLUG\tREPO\tURL")
        Enum.each(matches, fn row -> puts(Enum.join(row, "\t")) end)
      end
    end
  end

  defp response_payload(response) when is_map(response), do: response
  defp response_payload(response) when is_binary(response), do: Jason.decode!(response)
  defp response_body(response) when is_binary(response), do: response
  defp response_body(response), do: Jason.encode!(response)

  defp project_metadata_row(project) do
    source =
      Enum.join(Enum.filter([project["description"], project["content"]], &present?/1), "\n")

    with [block] <- Regex.run(~r/^cycle:\s*\n(?:[ \t]+.*\n?)*/m, source),
         true <- Regex.match?(~r/^[ \t]+enabled:\s*true\b/im, block) do
      repo = Regex.run(~r/^[ \t]+repo:\s*(.+?)\s*$/im, block) |> repo_from_match()
      [[project["name"], project["slugId"], repo, project["url"]]]
    else
      _ -> []
    end
  end

  defp repo_from_match([_, repo]), do: repo
  defp repo_from_match(_), do: ""

  defp status(args) do
    with {:ok, opts} <-
           parse_options(args, %{state_url: @default_state_url}, %{"--state-url" => :state_url}) do
      default_engine = engine_dir(@default_symphony_ref)
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
           }) do
      cond do
        !present?(opts[:workflow]) ->
          {:error, "cycle start requires --workflow PATH", 1}

        true ->
          symphony_bin = Path.join([engine_dir(opts.ref), "elixir", "bin", "symphony"])

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
  defp service(["status"]), do: puts(service_status_text())
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

  defp service_status_text do
    """
    Service status is not implemented yet.

    Use `cycle status` for the current local Cycle/Symphony status checks.
    """
  end

  defp parse_options([], opts, _spec), do: {:ok, opts}

  defp parse_options([arg | rest], opts, spec) do
    case Map.fetch(spec, arg) do
      {:ok, key} when key in [:from_env, :print, :raw, :dry_run] ->
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

  defp require_linear_key do
    if present?(linear_api_key()), do: :ok, else: {:error, "LINEAR_API_KEY is not configured", 1}
  end

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

  defp config_file, do: Path.join(config_home(), "config.env")
  defp engine_dir(ref), do: Path.join([cycle_home(), "engines/openai-symphony", ref])

  defp linear_api_key do
    System.get_env("LINEAR_API_KEY") || config_linear_api_key()
  end

  defp config_linear_api_key do
    with true <- File.exists?(config_file()),
         {:ok, content} <- File.read(config_file()),
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
