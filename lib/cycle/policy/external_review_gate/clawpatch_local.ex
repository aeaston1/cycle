defmodule Cycle.Policy.ExternalReviewGate.ClawpatchLocal do
  @moduledoc """
  Read-only local workspace Clawpatch provider.

  The provider runs a configured executable with configured args from the
  workspace directory and normalizes the JSON report into Cycle gate structs.
  """

  @behaviour Cycle.Policy.ExternalReviewGate

  alias Cycle.Policy.ExternalReviewGate
  alias Cycle.Policy.ExternalReviewGate.Artifact
  alias Cycle.Policy.ExternalReviewGate.Command
  alias Cycle.Policy.ExternalReviewGate.Finding
  alias Cycle.Policy.ExternalReviewGate.Report

  @provider "clawpatch"
  @default_timeout_ms 120_000
  @max_summary_length 500
  @max_finding_summary_length 300
  @clawpatch_config_paths [
    ".clawpatch/config.json",
    ".clawpatch/config.yaml",
    ".clawpatch/config.yml",
    "clawpatch.json",
    "clawpatch.yaml",
    "clawpatch.yml",
    ".clawpatchrc",
    ".clawpatchrc.json",
    ".clawpatchrc.yaml",
    ".clawpatchrc.yml"
  ]
  @crabbox_config_paths [
    ".crabbox/config.json",
    ".crabbox/config.yaml",
    ".crabbox/config.yml",
    ".crabbox/config.toml",
    "crabbox.json",
    "crabbox.yaml",
    "crabbox.yml",
    "crabbox.toml",
    "crabbox.config.toml"
  ]

  @impl true
  def review(workspace, config, opts \\ [])

  def review(workspace, config, opts) when is_binary(workspace) and is_map(config) do
    config = stringify_keys(config)

    with :ok <- require_workspace(workspace),
         {:ok, artifact_dir} <- prepare_artifact_dir(config),
         {:ok, report_path} <- configured_report_path(config, artifact_dir),
         {:ok, provider_config} <- discover_provider_config(workspace, artifact_dir, config),
         {:ok, command} <-
           build_command(workspace, config, artifact_dir, report_path, provider_config),
         {:ok, output} <- run_command(command, config, provider_config, opts),
         {:ok, report_payload, report_artifact} <- read_report(output, command.report_path),
         {:ok, result} <-
           normalize_report(report_payload, command, report_artifact, provider_config) do
      result
    else
      {:error, code, message, details, command} ->
        ExternalReviewGate.failure(code, message, details,
          command: command,
          provider: @provider,
          metadata: %{"provider" => @provider}
        )

      {:error, code, message, details} ->
        ExternalReviewGate.failure(code, message, details,
          provider: @provider,
          metadata: %{"provider" => @provider}
        )
    end
  rescue
    error ->
      ExternalReviewGate.failure(
        :provider_exception,
        "Clawpatch local review failed",
        %{"error" => Exception.message(error)},
        provider: @provider,
        metadata: %{"provider" => @provider}
      )
  end

  def review(_workspace, _config, _opts) do
    ExternalReviewGate.failure(
      :invalid_config,
      "Clawpatch local review requires a workspace path and config map",
      %{},
      provider: @provider,
      metadata: %{"provider" => @provider}
    )
  end

  defp require_workspace(workspace) do
    if File.dir?(workspace) do
      :ok
    else
      {:error, :missing_workspace, "external review workspace is missing",
       %{"workspace" => workspace}}
    end
  end

  defp prepare_artifact_dir(config) do
    case text_value(Map.get(config, "artifact_dir")) do
      nil ->
        {:ok, nil}

      path ->
        expanded = Path.expand(path)

        case File.mkdir_p(expanded) do
          :ok ->
            {:ok, expanded}

          {:error, reason} ->
            {:error, :artifact_dir_unavailable, "external review artifact dir is unavailable",
             %{"artifact_dir" => expanded, "reason" => inspect(reason)}}
        end
    end
  end

  defp configured_report_path(config, artifact_dir) do
    case text_value(Map.get(config, "report_path")) do
      nil ->
        {:ok, nil}

      _path when is_nil(artifact_dir) ->
        {:error, :invalid_config, "external review report_path requires artifact_dir", %{}}

      path ->
        artifact_path(path, artifact_dir, "report")
    end
  end

  defp discover_provider_config(workspace, artifact_dir, config) do
    with {:ok, clawpatch_config_path, clawpatch_config_source} <-
           configured_or_existing_path(
             workspace,
             config,
             "clawpatch_config_path",
             @clawpatch_config_paths
           ),
         {:ok, crabbox_config_path, crabbox_config_source} <-
           crabbox_config_path(workspace, artifact_dir, config) do
      {:ok,
       %{
         "clawpatch_config_path" => clawpatch_config_path,
         "clawpatch_config_source" => clawpatch_config_source,
         "crabbox_config_path" => crabbox_config_path,
         "crabbox_config_source" => crabbox_config_source
       }}
    end
  end

  defp configured_or_existing_path(workspace, config, config_key, candidates) do
    case text_value(Map.get(config, config_key)) do
      nil ->
        case existing_workspace_path(workspace, candidates) do
          nil -> {:ok, nil, nil}
          path -> {:ok, path, "workspace"}
        end

      path ->
        path = resolve_config_path(workspace, path)

        if File.regular?(path) do
          {:ok, path, "configured"}
        else
          {:error, :missing_config, "external review configured file is missing",
           %{"config_key" => config_key, "path" => path}}
        end
    end
  end

  defp crabbox_config_path(workspace, artifact_dir, config) do
    case configured_or_existing_path(
           workspace,
           config,
           "crabbox_config_path",
           @crabbox_config_paths
         ) do
      {:ok, nil, nil} -> default_crabbox_config(artifact_dir)
      other -> other
    end
  end

  defp default_crabbox_config(nil), do: {:ok, nil, nil}

  defp default_crabbox_config(artifact_dir) do
    path = Path.join(artifact_dir, "cycle-crabbox.cloudflare-workers.json")

    body =
      Jason.encode!(%{
        "schema" => "cycle.external_review.crabbox.v1",
        "provider" => "cloudflare_workers",
        "runtime" => "cloudflare_workers",
        "mode" => "review",
        "managed_by" => "cycle",
        "credentials" => "external_plugin"
      })

    case File.write(path, body <> "\n") do
      :ok ->
        {:ok, path, "cycle_cloudflare_workers_default"}

      {:error, reason} ->
        {:error, :artifact_dir_unavailable,
         "external review default Crabbox config could not be written",
         %{"artifact_dir" => artifact_dir, "reason" => inspect(reason)}}
    end
  end

  defp existing_workspace_path(workspace, candidates) do
    Enum.find_value(candidates, fn candidate ->
      path = Path.expand(candidate, workspace)
      if File.regular?(path), do: path
    end)
  end

  defp resolve_config_path(workspace, path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, workspace)
    end
  end

  defp build_command(workspace, config, artifact_dir, report_path, provider_config) do
    with {:ok, executable} <- executable(config),
         {:ok, args} <- args(config),
         {:ok, timeout_ms} <- timeout_ms(config),
         {:ok, rendered_args} <-
           render_args(args, workspace, artifact_dir, report_path, provider_config) do
      {:ok,
       %Command{
         executable: executable,
         args: rendered_args,
         cd: workspace,
         timeout_ms: timeout_ms,
         artifact_dir: artifact_dir,
         report_path: report_path
       }}
    end
  end

  defp executable(%{"executable" => executable}) do
    case text_value(executable) do
      nil -> {:error, :invalid_config, "external review executable is required", %{}}
      executable -> {:ok, executable}
    end
  end

  defp executable(%{"command" => command}) when is_binary(command) do
    case text_value(command) do
      nil ->
        {:error, :invalid_config, "external review executable is required", %{}}

      command ->
        if Regex.match?(~r/\s/, command) do
          {:error, :invalid_config,
           "external review config must use command as one executable and args separately",
           %{"command" => command}}
        else
          {:ok, command}
        end
    end
  end

  defp executable(config) do
    case text_value(Map.get(config, "executable")) do
      nil -> {:error, :invalid_config, "external review executable is required", %{}}
      executable -> {:ok, executable}
    end
  end

  defp args(config) do
    case Map.get(config, "args", []) do
      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1) do
          {:ok, args}
        else
          {:error, :invalid_config, "external review args must be a list of strings", %{}}
        end

      _other ->
        {:error, :invalid_config, "external review args must be a list of strings", %{}}
    end
  end

  defp timeout_ms(config) do
    case Map.get(config, "timeout_ms", @default_timeout_ms) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      _other ->
        {:error, :invalid_config, "external review timeout_ms must be a positive integer", %{}}
    end
  end

  defp render_args(args, workspace, artifact_dir, report_path, provider_config) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, rendered} ->
      case render_arg(arg, workspace, artifact_dir, report_path, provider_config) do
        {:ok, value} -> {:cont, {:ok, [value | rendered]}}
        {:error, code, message, details} -> {:halt, {:error, code, message, details}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  defp render_arg(arg, workspace, artifact_dir, report_path, provider_config) do
    clawpatch_config_path = Map.get(provider_config, "clawpatch_config_path")
    crabbox_config_path = Map.get(provider_config, "crabbox_config_path")

    cond do
      String.contains?(arg, "${artifact_dir}") and is_nil(artifact_dir) ->
        {:error, :invalid_config,
         "external review args reference artifact_dir without artifact_dir", %{"arg" => arg}}

      String.contains?(arg, "${report_path}") and is_nil(report_path) ->
        {:error, :invalid_config,
         "external review args reference report_path without report_path", %{"arg" => arg}}

      String.contains?(arg, "${clawpatch_config_path}") and is_nil(clawpatch_config_path) ->
        {:error, :missing_config,
         "external review args reference clawpatch_config_path without an available config",
         %{"arg" => arg}}

      String.contains?(arg, "${crabbox_config_path}") and is_nil(crabbox_config_path) ->
        {:error, :missing_config,
         "external review args reference crabbox_config_path without an available config",
         %{"arg" => arg}}

      true ->
        {:ok,
         arg
         |> String.replace("${workspace}", workspace)
         |> String.replace("${artifact_dir}", artifact_dir || "")
         |> String.replace("${report_path}", report_path || "")
         |> String.replace("${clawpatch_config_path}", clawpatch_config_path || "")
         |> String.replace("${crabbox_config_path}", crabbox_config_path || "")}
    end
  end

  defp run_command(%Command{} = command, config, provider_config, opts) do
    command_runner = Keyword.get(opts, :command_runner) || (&default_command_runner/3)
    command_opts = command_opts(command, config, provider_config)

    task =
      Task.async(fn ->
        command_runner.(command.executable, command.args, command_opts)
      end)

    case Task.yield(task, command.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        normalize_command_result(result, command)

      nil ->
        {:error, :provider_timeout, "external review provider timed out",
         %{"timeout_ms" => command.timeout_ms}, command}
    end
  end

  defp command_opts(%Command{} = command, config, provider_config) do
    [cd: command.cd, stderr_to_stdout: true]
    |> maybe_put_env(Map.get(config, "env"))
    |> maybe_put_provider_config_env(provider_config)
  end

  defp maybe_put_env(opts, env) when is_map(env), do: Keyword.put(opts, :env, Map.to_list(env))
  defp maybe_put_env(opts, _env), do: opts

  defp maybe_put_provider_config_env(opts, provider_config) do
    env =
      opts
      |> Keyword.get(:env, [])
      |> put_env("CYCLE_CLAWPATCH_CONFIG_PATH", Map.get(provider_config, "clawpatch_config_path"))
      |> put_env(
        "CYCLE_CLAW_PATCH_CONFIG_PATH",
        Map.get(provider_config, "clawpatch_config_path")
      )
      |> put_env("CYCLE_CRABBOX_CONFIG_PATH", Map.get(provider_config, "crabbox_config_path"))
      |> put_env("CYCLE_CRABBOX_CONFIG_SOURCE", Map.get(provider_config, "crabbox_config_source"))

    Keyword.put(opts, :env, env)
  end

  defp put_env(env, _key, nil), do: env

  defp put_env(env, key, value) do
    [
      {key, to_string(value)}
      | Enum.reject(env, fn {env_key, _value} -> to_string(env_key) == key end)
    ]
  end

  defp default_command_runner(executable, args, opts) do
    System.cmd(executable, args, opts)
  end

  defp normalize_command_result({output, 0}, _command) when is_binary(output), do: {:ok, output}

  defp normalize_command_result({output, status}, command) when is_integer(status) do
    {:error, :provider_exit, "external review provider exited with non-zero status",
     %{"exit_status" => status, "output" => trim(output, @max_summary_length)}, command}
  end

  defp normalize_command_result({:ok, output}, _command) when is_binary(output), do: {:ok, output}

  defp normalize_command_result({:error, reason}, command) do
    {:error, :provider_error, "external review provider failed", %{"reason" => inspect(reason)},
     command}
  end

  defp normalize_command_result(other, command) do
    {:error, :provider_error, "external review provider returned an unexpected result",
     %{"result" => inspect(other)}, command}
  end

  defp read_report(output, report_path) do
    case decode_output(output) do
      {:ok, report} ->
        {:ok, report, nil}

      :empty when is_binary(report_path) ->
        read_report_file(report_path)

      :error when is_binary(report_path) ->
        read_report_file(report_path)

      :empty ->
        {:error, :missing_report, "external review provider did not return a JSON report", %{}}

      :error ->
        {:error, :malformed_report, "external review provider returned malformed JSON", %{}}
    end
  end

  defp decode_output(output) when is_binary(output) do
    trimmed = String.trim(output)

    cond do
      trimmed == "" ->
        :empty

      true ->
        decode_json(trimmed)
    end
  end

  defp decode_output(_output), do: :error

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, report} when is_map(report) ->
        {:ok, stringify_keys(report)}

      _ ->
        decode_embedded_json(text)
    end
  end

  defp decode_embedded_json(text) do
    with first when is_integer(first) <- :binary.match(text, "{") |> match_index(),
         last when is_integer(last) <- last_index(text, "}"),
         true <- last >= first,
         candidate <- String.slice(text, first, last - first + 1),
         {:ok, report} when is_map(report) <- Jason.decode(candidate) do
      {:ok, stringify_keys(report)}
    else
      _ -> :error
    end
  end

  defp match_index({index, _length}), do: index
  defp match_index(:nomatch), do: nil

  defp last_index(text, pattern) do
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {^pattern, index}, _last -> index
      _other, last -> last
    end)
  end

  defp read_report_file(report_path) do
    case File.read(report_path) do
      {:ok, text} ->
        case decode_json(String.trim(text)) do
          {:ok, report} ->
            {:ok, report,
             %Artifact{
               path: report_path,
               relative_path: Path.basename(report_path),
               kind: "report",
               exists: true
             }}

          _ ->
            {:error, :malformed_report, "external review report artifact contains malformed JSON",
             %{"report_path" => report_path}}
        end

      {:error, reason} ->
        {:error, :missing_report, "external review report artifact is missing",
         %{"report_path" => report_path, "reason" => inspect(reason)}}
    end
  end

  defp normalize_report(payload, %Command{} = command, report_artifact, provider_config) do
    raw = stringify_keys(payload)
    findings = normalize_findings(raw, command.artifact_dir)
    report = report(raw, report_artifact)
    artifacts = [report_artifact | Enum.map(findings, & &1.artifact)] |> Enum.reject(&is_nil/1)
    status = result_status(raw, findings)
    summary = report.summary || default_summary(status)

    result =
      case status do
        :passed ->
          ExternalReviewGate.passed(
            provider: @provider,
            summary: summary,
            report: report,
            command: command,
            findings: findings,
            artifacts: artifacts,
            metadata: provider_metadata(provider_config)
          )

        :review_required ->
          ExternalReviewGate.review_required(
            provider: @provider,
            summary: summary,
            report: report,
            command: command,
            findings: findings,
            artifacts: artifacts,
            metadata: provider_metadata(provider_config)
          )

        :failure ->
          ExternalReviewGate.failure(
            :provider_report_failure,
            summary,
            %{"status" => report.status},
            provider: @provider,
            report: report,
            command: command,
            findings: findings,
            artifacts: artifacts,
            metadata: provider_metadata(provider_config)
          )
      end

    {:ok, result}
  end

  defp provider_metadata(provider_config) do
    %{
      "provider" => @provider,
      "clawpatch_config_source" => Map.get(provider_config, "clawpatch_config_source"),
      "crabbox_config_source" => Map.get(provider_config, "crabbox_config_source")
    }
  end

  defp report(raw, artifact) do
    %Report{
      status: raw |> first_present(["status", "result", "decision"]) |> normalize_status(),
      summary:
        raw |> first_present(["summary", "message", "review_summary", "result_summary"]) |> text(),
      artifact: artifact,
      raw: raw
    }
  end

  defp result_status(raw, findings) do
    status = raw |> first_present(["status", "result"]) |> normalize_status()
    decision = raw |> first_present(["decision", "verdict"]) |> normalize_status()

    cond do
      status in ["error", "failure", "provider_error"] ->
        :failure

      truthy?(first_present(raw, ["review_required", "requires_review", "human_review_required"])) ->
        :review_required

      decision in ["require_human_review", "review_required", "requires_review"] ->
        :review_required

      status in ["fail", "failed", "blocked", "review_required", "requires_review"] ->
        :review_required

      findings != [] ->
        :review_required

      true ->
        :passed
    end
  end

  defp normalize_findings(raw, artifact_dir) do
    raw
    |> findings_payload()
    |> Enum.map(&normalize_finding(&1, artifact_dir))
    |> Enum.reject(&is_nil/1)
  end

  defp findings_payload(raw) do
    cond do
      is_list(Map.get(raw, "findings")) -> Map.get(raw, "findings")
      is_list(Map.get(raw, "issues")) -> Map.get(raw, "issues")
      is_list(Map.get(raw, "comments")) -> Map.get(raw, "comments")
      is_list(get_in(raw, ["report", "findings"])) -> get_in(raw, ["report", "findings"])
      true -> []
    end
  end

  defp normalize_finding(value, _artifact_dir) when is_binary(value) do
    %Finding{summary: trim(value, @max_finding_summary_length)}
  end

  defp normalize_finding(value, artifact_dir) when is_map(value) do
    value = stringify_keys(value)

    %Finding{
      severity: value |> first_present(["severity", "level", "priority"]) |> normalize_status(),
      title: value |> first_present(["title", "name", "check"]) |> text(),
      summary:
        value
        |> first_present(["summary", "message", "description", "body", "recommendation"])
        |> text(@max_finding_summary_length),
      path: value |> first_present(["path", "file", "source_path"]) |> text(),
      line: value |> first_present(["line", "line_number"]) |> positive_integer(),
      rule_id: value |> first_present(["rule_id", "rule", "code"]) |> text(),
      artifact: finding_artifact(value, artifact_dir)
    }
  end

  defp normalize_finding(_value, _artifact_dir), do: nil

  defp finding_artifact(value, nil) when is_map(value) do
    case first_present(value, ["artifact_path", "artifact"]) do
      nil -> nil
      _path -> %Artifact{kind: "finding", exists: false}
    end
  end

  defp finding_artifact(value, artifact_dir) when is_map(value) do
    with path when is_binary(path) <- artifact_path_value(value),
         {:ok, artifact_path} <- artifact_path(path, artifact_dir, "finding") do
      %Artifact{
        path: artifact_path,
        relative_path: Path.relative_to(artifact_path, artifact_dir),
        kind: "finding",
        exists: File.exists?(artifact_path)
      }
    else
      _ -> nil
    end
  end

  defp artifact_path_value(value) do
    case first_present(value, ["artifact_path", "artifact_file"]) do
      path when is_binary(path) ->
        path

      nil ->
        case Map.get(value, "artifact") do
          %{"path" => path} when is_binary(path) -> path
          path when is_binary(path) -> path
          _other -> nil
        end
    end
  end

  defp artifact_path(path, artifact_dir, _kind) do
    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(Path.join(artifact_dir, path))
      end

    if under_dir?(expanded, artifact_dir) do
      {:ok, expanded}
    else
      {:error, :invalid_artifact_path, "external review artifact path escapes artifact_dir",
       %{"artifact_dir" => artifact_dir, "path" => path}}
    end
  end

  defp under_dir?(path, dir) do
    relative = Path.relative_to(path, dir)
    Path.type(relative) == :relative and List.first(Path.split(relative)) != ".."
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp text_value(nil), do: nil
  defp text_value(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp text_value(value), do: value |> to_string() |> String.trim() |> blank_to_nil()

  defp text(value, max \\ @max_summary_length)
  defp text(nil, _max), do: nil
  defp text(value, max) when is_binary(value), do: trim(value, max)
  defp text(value, max), do: value |> Jason.encode!() |> trim(max)

  defp trim(value, max) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max)
    |> blank_to_nil()
  end

  defp trim(value, max), do: value |> inspect() |> trim(max)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_status(nil), do: nil

  defp normalize_status(value) do
    value
    |> text()
    |> case do
      nil -> nil
      status -> status |> String.downcase() |> String.replace(~r/[^a-z0-9_]+/, "_")
    end
  end

  defp truthy?(value) when value in [true, "true", "yes", "1", 1], do: true
  defp truthy?(_value), do: false

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp default_summary(:passed), do: "External review passed."

  defp default_summary(:review_required),
    do: "External review found issues requiring human review."

  defp default_summary(:failure), do: "External review provider reported a failure."

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
