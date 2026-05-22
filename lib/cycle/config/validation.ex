defmodule Cycle.Config.Validation do
  @moduledoc """
  User-readable, machine-testable validation for Cycle config.
  """

  alias Cycle.Config

  @type error :: %{path: String.t(), reason: String.t()}

  @spec validate(Config.t()) :: {:ok, Config.t()} | {:error, [error()]}
  def validate(%Config{} = config) do
    []
    |> require_string("paths.config_dir", config.paths.config_dir)
    |> require_string("paths.config_file", config.paths.config_file)
    |> require_string("paths.state_dir", config.paths.state_dir)
    |> require_string("paths.logs_dir", config.paths.logs_dir)
    |> require_string("paths.engines_dir", config.paths.engines_dir)
    |> require_url("linear.endpoint", get_in(config.linear, ["endpoint"]))
    |> require_string("linear.api_key_env", get_in(config.linear, ["api_key_env"]))
    |> require_non_empty_list("linear.active_states", get_in(config.linear, ["active_states"]))
    |> require_non_empty_list(
      "linear.terminal_states",
      get_in(config.linear, ["terminal_states"])
    )
    |> require_positive_integer("polling.interval_ms", get_in(config.polling, ["interval_ms"]))
    |> require_string("projects.registry_path", get_in(config.projects, ["registry_path"]))
    |> require_string(
      "projects.workflow_cache_path",
      get_in(config.projects, ["workflow_cache_path"])
    )
    |> require_string("engines.registry_path", get_in(config.engines, ["registry_path"]))
    |> require_string("engines.lock_path", get_in(config.engines, ["lock_path"]))
    |> require_string("engines.default", get_in(config.engines, ["default"]))
    |> require_string("engines.install_root", get_in(config.engines, ["install_root"]))
    |> require_git_repository(
      "engines.managed.openai-symphony.repo",
      get_in(config.engines, ["managed", "openai-symphony", "repo"])
    )
    |> require_string(
      "engines.managed.openai-symphony.default_ref",
      get_in(config.engines, ["managed", "openai-symphony", "default_ref"])
    )
    |> require_positive_integer(
      "scheduler.max_concurrent_runs",
      get_in(config.scheduler, ["max_concurrent_runs"])
    )
    |> require_mode("scheduler.budget.mode", get_in(config.scheduler, ["budget", "mode"]))
    |> require_mode("scheduler.rate_limit.mode", get_in(config.scheduler, ["rate_limit", "mode"]))
    |> require_boolean("service.api.enabled", get_in(config.service, ["api", "enabled"]))
    |> require_string("service.api.bind", get_in(config.service, ["api", "bind"]))
    |> require_positive_integer("service.api.port", get_in(config.service, ["api", "port"]))
    |> require_local_bind_or_explicit_config(config)
    |> require_string("service.logs.path", get_in(config.service, ["logs", "path"]))
    |> then(fn
      [] -> {:ok, config}
      errors -> {:error, Enum.reverse(errors)}
    end)
  end

  defp require_string(errors, _path, value) when is_binary(value) and value != "", do: errors

  defp require_string(errors, path, _value),
    do: [%{path: path, reason: "must be a non-empty string"} | errors]

  defp require_url(errors, path, value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      errors
    else
      [%{path: path, reason: "must be an http or https URL"} | errors]
    end
  end

  defp require_url(errors, path, _value),
    do: [%{path: path, reason: "must be an http or https URL"} | errors]

  defp require_git_repository(errors, path, value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      uri.scheme in ["http", "https", "git", "ssh"] and is_binary(uri.host) ->
        errors

      uri.scheme == "file" and is_binary(uri.path) and uri.path != "" ->
        errors

      Path.type(value) == :absolute ->
        errors

      true ->
        [%{path: path, reason: "must be a git repository URL or absolute path"} | errors]
    end
  end

  defp require_git_repository(errors, path, _value),
    do: [%{path: path, reason: "must be a git repository URL or absolute path"} | errors]

  defp require_non_empty_list(errors, path, [_ | _] = values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      errors
    else
      [%{path: path, reason: "must contain only non-empty strings"} | errors]
    end
  end

  defp require_non_empty_list(errors, path, _value),
    do: [%{path: path, reason: "must be a non-empty list"} | errors]

  defp require_positive_integer(errors, _path, value) when is_integer(value) and value > 0,
    do: errors

  defp require_positive_integer(errors, path, _value),
    do: [%{path: path, reason: "must be a positive integer"} | errors]

  defp require_mode(errors, _path, value) when value in ["off", "warn", "block"], do: errors

  defp require_mode(errors, path, _value),
    do: [%{path: path, reason: "must be one of: off, warn, block"} | errors]

  defp require_boolean(errors, _path, value) when is_boolean(value), do: errors

  defp require_boolean(errors, path, _value),
    do: [%{path: path, reason: "must be a boolean"} | errors]

  defp require_local_bind_or_explicit_config(errors, %Config{} = config) do
    bind = get_in(config.service, ["api", "bind"])
    allow_non_local? = get_in(config.service, ["api", "allow_non_local"]) == true

    if local_bind?(bind) or allow_non_local? do
      errors
    else
      [
        %{
          path: "service.api.allow_non_local",
          reason: "must be true when service.api.bind is not localhost"
        }
        | errors
      ]
    end
  end

  defp local_bind?("127.0.0.1"), do: true
  defp local_bind?("::1"), do: true
  defp local_bind?("localhost"), do: true
  defp local_bind?(_bind), do: false
end
