defmodule Cycle.Config do
  @moduledoc """
  Loads operator config from defaults, repo workflow defaults, config.yaml,
  environment, and explicit CLI overrides.
  """

  alias Cycle.Config.Paths
  alias Cycle.Config.Validation

  defstruct paths: %Paths{},
            linear: %{},
            polling: %{},
            projects: %{},
            engines: %{},
            scheduler: %{},
            review_judge: %{},
            policy: %{},
            service: %{},
            secrets: %{}

  @type load_option ::
          {:env, map()}
          | {:cli, map()}
          | {:workflow, map()}
          | {:config_path, Path.t()}
          | {:home, Path.t()}

  @doc """
  Loads and validates the effective Cycle config.

  Precedence, lowest to highest:

    * built-in defaults
    * repo-owned workflow defaults
    * config file
    * environment variables
    * CLI overrides
  """
  @spec load([load_option()]) :: {:ok, %__MODULE__{}} | {:error, [Validation.error()]}
  def load(opts \\ []) do
    raw_env = Map.new(Keyword.get(opts, :env, System.get_env()))
    home = Keyword.get(opts, :home, System.user_home!())

    with {:ok, env} <- merge_cycle_env_file(raw_env),
         config_path <- Keyword.get(opts, :config_path, Paths.config_file(env, home)),
         workflow <- Keyword.get(opts, :workflow, %{}) || %{},
         cli <- Keyword.get(opts, :cli, %{}) || %{},
         {:ok, file_config} <- read_config_file(config_path),
         {:ok, legacy_key} <- read_legacy_linear_key(Paths.legacy_config_file(env, home)),
         {:ok, merged} <-
           merge_layers(
             defaults(env, home),
             workflow,
             file_config,
             env_layer(env, legacy_key),
             cli
           ),
         {:ok, interpolated} <- interpolate(merged, env, home),
         config_with_secrets <- resolve_secrets(interpolated, env, legacy_key),
         config <- to_struct(config_with_secrets),
         {:ok, validated} <- Validation.validate(config) do
      {:ok, validated}
    end
  end

  @doc """
  Returns a map suitable for display, with secrets redacted.
  """
  def redacted(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.update!(:paths, &Map.from_struct/1)
    |> redact_secrets()
  end

  defp read_config_file(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, nil} ->
          {:ok, %{}}

        {:ok, map} when is_map(map) ->
          {:ok, stringify_keys(map)}

        {:ok, _other} ->
          {:error, [%{path: "config", reason: "must be a YAML mapping"}]}

        {:error, reason} ->
          {:error, [%{path: "config", reason: "invalid YAML: #{format_yaml_error(reason)}"}]}
      end
    else
      {:ok, %{}}
    end
  end

  defp merge_cycle_env_file(env) do
    case Map.get(env, "CYCLE_ENV_FILE") do
      path when is_binary(path) and path != "" ->
        with {:ok, file_env} <- read_env_file(path) do
          {:ok, Map.merge(file_env, env)}
        end

      _ ->
        {:ok, env}
    end
  end

  defp read_env_file(path) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, parse_env_file(text)}

      {:error, reason} ->
        {:error, [%{path: "CYCLE_ENV_FILE", reason: "could not read #{path}: #{reason}"}]}
    end
  end

  defp parse_env_file(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          acc

        String.contains?(line, "=") ->
          [key, value] = String.split(line, "=", parts: 2)
          Map.put(acc, key, value)

        true ->
          acc
      end
    end)
  end

  defp read_legacy_linear_key(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, text} ->
          key =
            text
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.find_value(fn line ->
              case Regex.run(~r/^LINEAR_API_KEY=(?:['"]?)([^'"]+)(?:['"]?)$/, line) do
                [_, value] -> value
                _ -> nil
              end
            end)

          {:ok, key}

        {:error, reason} ->
          {:error,
           [%{path: "linear.api_key", reason: "legacy config.env could not be read: #{reason}"}]}
      end
    else
      {:ok, nil}
    end
  end

  defp merge_layers(defaults, workflow, file_config, env_config, cli) do
    {:ok,
     Enum.reduce(
       [workflow, file_config, env_config, cli],
       defaults,
       &deep_merge(&2, stringify_keys(&1))
     )}
  end

  defp resolve_secrets(config, env, legacy_key) do
    linear = Map.get(config, "linear", %{})
    configured_env = Map.get(linear, "api_key_env") || "LINEAR_API_KEY"

    token =
      first_present([
        get_in(config, ["secrets", "linear_api_key"]),
        Map.get(env, configured_env),
        Map.get(linear, "api_key"),
        legacy_key
      ])

    config
    |> put_secret(token)
    |> drop_linear_api_key()
  end

  defp first_present(values) do
    Enum.find(values, fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  defp put_secret(config, nil), do: config

  defp put_secret(config, token) do
    put_in_path(config, ["secrets", "linear_api_key"], token)
  end

  defp drop_linear_api_key(config) do
    Map.update(config, "linear", %{}, &Map.delete(&1 || %{}, "api_key"))
  end

  defp defaults(env, home) do
    cycle_home = Paths.cycle_home(env, home)

    %{
      "paths" => %{
        "config_dir" => Paths.config_dir(env, home),
        "config_file" => Paths.config_file(env, home),
        "state_dir" => cycle_home,
        "logs_dir" => Path.join(cycle_home, "logs"),
        "engines_dir" => Path.join(cycle_home, "engines")
      },
      "linear" => %{
        "endpoint" => "https://api.linear.app/graphql",
        "api_key_env" => "LINEAR_API_KEY",
        "discovery" => %{
          "mode" => "opt_in_descriptions",
          "preferred_namespace" => "cycle"
        },
        "active_states" => ["Todo", "In Progress", "Rework", "Merging"],
        "terminal_states" => ["Done", "Canceled", "Cancelled", "Duplicate", "Closed"]
      },
      "polling" => %{"interval_ms" => 30_000},
      "projects" => %{
        "registry_path" => "${CYCLE_HOME}/projects.yaml",
        "workflow_cache_path" => "${CYCLE_HOME}/workflow-cache"
      },
      "engines" => %{
        "registry_path" => "${CYCLE_HOME}/engines.yaml",
        "lock_path" => "${CYCLE_HOME}/engines.lock.yaml",
        "default" => "openai-symphony@main",
        "install_root" => "${CYCLE_HOME}/engines",
        "managed" => %{
          "openai-symphony" => %{
            "repo" => "https://github.com/openai/symphony.git",
            "default_ref" => "main",
            "foreground_unattended" => false
          }
        }
      },
      "scheduler" => %{
        "max_concurrent_runs" => 10,
        "max_retry_backoff_ms" => 300_000,
        "stale_run_timeout_ms" => 300_000,
        "budget" => %{"mode" => "warn", "pressure" => false},
        "rate_limit" => %{"mode" => "warn", "pressure" => false}
      },
      "review_judge" => %{
        "enabled" => false,
        "source_state" => "Human Review",
        "review_state" => "Human Review",
        "proceed_state" => "Merging",
        "policy" => "standard",
        "minimum_skip_confidence" => "medium",
        "hard_require_human_review" => %{"paths" => [], "labels" => []}
      },
      "policy" => %{
        "enforcement" => "report",
        "drift" => %{"report_in_status" => true, "propagation" => "manual"}
      },
      "service" => %{
        "api" => %{"enabled" => true, "bind" => "127.0.0.1", "port" => 4765},
        "external_symphony_status_url" => nil,
        "logs" => %{"path" => "${CYCLE_HOME}/logs/cycle.log"}
      },
      "secrets" => %{}
    }
  end

  defp env_layer(env, _legacy_key) do
    %{}
    |> put_if_present(["paths", "state_dir"], Map.get(env, "CYCLE_HOME"))
    |> put_if_present(["paths", "logs_dir"], env_path(env, "CYCLE_HOME", "logs"))
    |> put_if_present(["paths", "engines_dir"], env_path(env, "CYCLE_HOME", "engines"))
    |> put_if_present(["service", "status_url"], Map.get(env, "CYCLE_STATUS_URL"))
    |> put_if_present(
      ["service", "external_symphony_status_url"],
      Map.get(env, "CYCLE_EXTERNAL_SYMPHONY_STATUS_URL")
    )
    |> put_if_present(
      ["engines", "managed", "openai-symphony", "repo"],
      Map.get(env, "CYCLE_SYMPHONY_REPO")
    )
    |> put_if_present(
      ["engines", "managed", "openai-symphony", "default_ref"],
      Map.get(env, "CYCLE_SYMPHONY_REF")
    )
  end

  defp env_path(env, key, suffix) do
    case Map.get(env, key) do
      nil -> nil
      value -> Path.join(value, suffix)
    end
  end

  defp put_if_present(map, _path, nil), do: map
  defp put_if_present(map, path, value), do: put_in_path(map, path, value)

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value) do
    Map.put(map, key, put_in_path(Map.get(map, key, %{}), rest, value))
  end

  defp interpolate(value, env, home) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      case interpolate(nested, env, home) do
        {:ok, result} -> {:cont, {:ok, Map.put(acc, key, result)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp interpolate(value, env, home) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested, {:ok, acc} ->
      case interpolate(nested, env, home) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp interpolate(value, env, home) when is_binary(value) do
    known_env =
      env
      |> Map.put_new("CYCLE_HOME", Paths.cycle_home(env, home))
      |> Map.put_new(
        "XDG_CONFIG_HOME",
        Map.get(env, "XDG_CONFIG_HOME") || Path.join(home, ".config")
      )

    interpolated =
      Regex.replace(~r/\$\{([A-Z0-9_]+)(:-([^}]+))?\}/, value, fn _match,
                                                                  name,
                                                                  _default_expr,
                                                                  default ->
        Map.get(known_env, name) || default || ""
      end)

    {:ok, expand_path(interpolated, home)}
  end

  defp interpolate(value, _env, _home), do: {:ok, value}

  defp expand_path("~/" <> rest, home), do: Path.expand(rest, home)
  defp expand_path(value, _home), do: value

  defp to_struct(config) do
    %__MODULE__{
      paths: struct(Paths, Map.get(config, "paths", %{}) |> atomize_path_keys()),
      linear: Map.get(config, "linear", %{}),
      polling: Map.get(config, "polling", %{}),
      projects: normalize_path_map(Map.get(config, "projects", %{})),
      engines: normalize_engine_paths(Map.get(config, "engines", %{})),
      scheduler: Map.get(config, "scheduler", %{}),
      review_judge: Map.get(config, "review_judge", %{}),
      policy: Map.get(config, "policy", %{}),
      service: normalize_service_paths(Map.get(config, "service", %{})),
      secrets: Map.get(config, "secrets", %{})
    }
    |> normalize_paths()
  end

  defp normalize_paths(%__MODULE__{} = config) do
    paths = %Paths{
      config_dir: Paths.normalize(config.paths.config_dir),
      config_file: Paths.normalize(config.paths.config_file),
      state_dir: Paths.normalize(config.paths.state_dir),
      logs_dir: Paths.normalize(config.paths.logs_dir),
      engines_dir: Paths.normalize(config.paths.engines_dir)
    }

    %{config | paths: paths}
  end

  defp normalize_path_map(map) do
    Map.new(map, fn
      {key, value} when key in ["registry_path", "workflow_cache_path"] and is_binary(value) ->
        {key, Paths.normalize(value)}

      pair ->
        pair
    end)
  end

  defp normalize_engine_paths(map) do
    map
    |> Map.update("registry_path", nil, &maybe_normalize/1)
    |> Map.update("lock_path", nil, &maybe_normalize/1)
    |> Map.update("install_root", nil, &maybe_normalize/1)
  end

  defp normalize_service_paths(map) do
    update_in(map, ["logs", "path"], &maybe_normalize/1)
  rescue
    ArgumentError -> map
  end

  defp maybe_normalize(value) when is_binary(value), do: Paths.normalize(value)
  defp maybe_normalize(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l_value, r_value -> deep_merge(l_value, r_value) end)
  end

  defp deep_merge(_left, right), do: right

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp atomize_path_keys(map) do
    allowed = %{
      "config_dir" => :config_dir,
      "config_file" => :config_file,
      "state_dir" => :state_dir,
      "logs_dir" => :logs_dir,
      "engines_dir" => :engines_dir
    }

    map
    |> Enum.filter(fn {key, _value} -> Map.has_key?(allowed, key) end)
    |> Map.new(fn {key, value} -> {Map.fetch!(allowed, key), value} end)
  end

  defp redact_secrets(value) when is_map(value) do
    Map.new(value, fn
      {key, value} when key in [:secrets, "secrets"] -> {key, redact_secrets(value)}
      {key, value} when key in [:linear_api_key, "linear_api_key"] -> {key, redact_value(value)}
      {key, value} -> {key, redact_secrets(value)}
    end)
  end

  defp redact_secrets(value) when is_list(value), do: Enum.map(value, &redact_secrets/1)
  defp redact_secrets(value), do: value

  defp redact_value(value) when is_binary(value) and value != "", do: "[REDACTED]"
  defp redact_value(value), do: value

  defp format_yaml_error(reason) when is_binary(reason), do: reason
  defp format_yaml_error(reason), do: inspect(reason)
end
