defmodule Cycle.Policy.ExternalReviewGate do
  @moduledoc """
  Read-only external review gate facade.

  The gate runs after the review judge has tentatively allowed an issue to
  proceed. It only returns a normalized result; Linear writes and state routing
  remain owned by `Cycle.Policy.ReviewRouter`.
  """

  alias Cycle.Policy.ExternalReviewGate.ClawpatchLocal

  defmodule Artifact do
    @moduledoc "External review artifact under the configured artifact directory."
    defstruct [:path, :relative_path, :kind, exists: false]
  end

  defmodule Command do
    @moduledoc "Executable command used for a local external review provider."
    defstruct [:executable, :cd, :timeout_ms, :artifact_dir, :report_path, args: []]
  end

  defmodule Failure do
    @moduledoc "Provider failure that forces human review."
    defstruct [:code, :message, details: %{}]
  end

  defmodule Finding do
    @moduledoc "Bounded external review finding summary."
    defstruct [:severity, :title, :summary, :path, :line, :rule_id, :artifact]
  end

  defmodule Report do
    @moduledoc "Normalized external review JSON report."
    defstruct [:status, :summary, :artifact, raw: %{}]
  end

  defmodule Result do
    @moduledoc "Normalized external review result."
    defstruct [
      :provider,
      :execution,
      :status,
      :decision,
      :summary,
      :reason_code,
      :message,
      :workspace_path,
      :artifact_path,
      :log_path,
      :exit_code,
      :duration_ms,
      :fingerprint,
      :report,
      :command,
      :failure,
      review_required: false,
      findings: [],
      artifacts: [],
      severity_breakdown: %{},
      details: %{},
      metadata: %{}
    ]
  end

  @callback review(Path.t(), map(), keyword()) :: Result.t()

  @supported_provider "clawpatch"
  @supported_execution "local_workspace"
  @default_timeout_ms 120_000

  @doc "Returns true when the merged review policy enables the external review gate."
  def enabled?(policy) when is_map(policy) do
    get_in(policy, ["external_review", "enabled"]) == true
  end

  def enabled?(_policy), do: false

  @doc "Returns the merged external review config from a review policy."
  def config(policy) when is_map(policy) do
    policy
    |> Map.get("external_review", %{})
    |> stringify_keys()
  end

  def config(_policy), do: %{}

  @doc "Timeout used by local external review command execution."
  def timeout_ms(config) when is_map(config) do
    case Map.get(config, "timeout_ms") do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_timeout(value)
      _ -> @default_timeout_ms
    end
  end

  def timeout_ms(_config), do: @default_timeout_ms

  defp parse_timeout(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> @default_timeout_ms
    end
  end

  @doc """
  Runs a local external review provider for callers that already have a workspace.
  """
  def review(workspace, config, opts \\ [])

  def review(_workspace, nil, _opts), do: skipped("external review is not configured")

  def review(workspace, config, opts) when is_map(config) do
    config = stringify_keys(config)

    if Map.get(config, "enabled", true) == false do
      skipped("external review is disabled")
    else
      provider = Keyword.get(opts, :provider, review_provider_module(config))
      provider.review(workspace, config, opts)
    end
  rescue
    error ->
      failure(:provider_exception, "external review provider failed", %{
        "error" => Exception.message(error)
      })
  end

  def passed(fields \\ []) do
    struct!(
      Result,
      Keyword.merge(
        [
          status: :passed,
          decision: "proceed_to_merging",
          reason_code: nil,
          review_required: false,
          summary: "External review passed.",
          message: "External review passed."
        ],
        fields
      )
    )
  end

  def review_required(fields \\ []) do
    struct!(
      Result,
      Keyword.merge(
        [
          status: :review_required,
          decision: "require_human_review",
          reason_code: "external_review_findings",
          review_required: true,
          summary: "External review requires human review.",
          message: "External review requires human review."
        ],
        fields
      )
    )
  end

  def failure(code, message, details \\ %{}, fields \\ []) when is_atom(code) do
    struct!(
      Result,
      Keyword.merge(
        [
          status: :failure,
          decision: "require_human_review",
          review_required: true,
          summary: message,
          message: message,
          reason_code: Atom.to_string(code),
          failure: %Failure{code: code, message: message, details: details},
          details: details || %{}
        ],
        fields
      )
    )
  end

  def skipped(summary) do
    %Result{
      status: :skipped,
      decision: nil,
      review_required: false,
      summary: summary,
      message: summary
    }
  end

  @doc """
  Runs the configured provider in the evidence workspace.

  The evidence workspace is authoritative. If it is missing or unsafe, the gate
  returns a failure result, which forces human review.
  """
  def run(evidence, policy, opts \\ [])

  def run(evidence, policy, opts) when is_map(evidence) and is_map(policy) do
    external_config = config(policy)
    workspace_path = get_in(evidence.git || %{}, ["workspace_path"])
    run_workspace_path = get_in(evidence.run || %{}, ["workspace_path"])

    with :ok <- validate_config(external_config),
         :ok <- validate_workspace(workspace_path),
         :ok <- validate_workspace_match(workspace_path, run_workspace_path) do
      provider = Keyword.get(opts, :external_review_provider, provider_module(external_config))

      provider.review(
        workspace_path,
        external_config,
        Keyword.put(opts, :workspace_path, workspace_path)
      )
      |> normalize_run_result(external_config, workspace_path)
    else
      {:error, reason_code, message, details} ->
        failure(external_config, workspace_path, reason_code, message, details)
    end
  rescue
    error ->
      failure(
        config(policy),
        get_in(evidence.git || %{}, ["workspace_path"]),
        "external_review_failed",
        "external review failed",
        %{"reason" => Exception.message(error)}
      )
  end

  def run(_evidence, policy, _opts) do
    failure(
      config(policy),
      nil,
      "external_review_failed",
      "external review evidence missing",
      %{}
    )
  end

  @doc "Returns a sanitized, stable external-review summary for registry/status/Linear use."
  def summary(%Result{} = result) do
    findings = Enum.map(result.findings || [], &finding_summary/1)
    status = summary_status(result, findings)
    reason_code = summary_reason_code(result, status, findings)
    artifact_path = result.artifact_path || artifact_path(result)
    log_path = result.log_path || metadata_value(result, "log_path")
    message = result.message || result.summary

    summary =
      %{}
      |> put_present("provider", text(result.provider, 120))
      |> put_present("execution", text(result.execution, 120))
      |> put_present("status", status)
      |> put_present("reason_code", reason_code)
      |> put_present("message", text(message, 300))
      |> put_present("workspace_path", text(result.workspace_path, 300))
      |> put_present("artifact_path", text(artifact_path, 300))
      |> put_present("log_path", text(log_path, 300))
      |> put_present("exit_code", result.exit_code)
      |> put_present("findings_count", length(findings))
      |> put_present("severity_breakdown", severity_breakdown(result, findings))
      |> put_present("findings", findings)
      |> put_present("fingerprint", result.fingerprint || fingerprint(result))
      |> Cycle.Log.redact()

    summary
  end

  def summary(value) when is_map(value), do: value |> stringify_keys() |> Cycle.Log.redact()
  def summary(_value), do: %{}

  defp normalize_run_result(%Result{} = result, config, workspace_path) do
    status = run_status(result)

    normalized = %Result{
      provider: Map.get(config || %{}, "provider", @supported_provider),
      execution: Map.get(config || %{}, "execution", @supported_execution),
      status: status,
      reason_code: run_reason_code(result, status),
      message: result.message || result.summary,
      workspace_path: workspace_path,
      artifact_path: artifact_path(result),
      log_path: result.log_path,
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
      findings: result.findings || [],
      severity_breakdown: severity_breakdown(result.findings || []),
      details: run_details(result),
      report: result.report,
      command: result.command,
      failure: result.failure,
      artifacts: result.artifacts || [],
      review_required: status != "passed",
      decision: if(status == "passed", do: "proceed_to_merging", else: "require_human_review")
    }

    %{normalized | fingerprint: result.fingerprint || fingerprint(normalized)}
  end

  defp normalize_run_result(_result, config, workspace_path) do
    failure(
      config,
      workspace_path,
      "external_review_failed",
      "external review provider returned an unexpected result",
      %{}
    )
  end

  defp run_status(%Result{status: :passed}), do: "passed"
  defp run_status(%Result{status: :failure}), do: "failed"
  defp run_status(%Result{status: :skipped}), do: "failed"
  defp run_status(%Result{status: :review_required}), do: "review_required"
  defp run_status(%Result{status: status}) when is_binary(status), do: status
  defp run_status(_result), do: "failed"

  defp run_reason_code(%Result{reason_code: reason_code}, _status) when is_binary(reason_code),
    do: reason_code

  defp run_reason_code(%Result{failure: %Failure{code: code}}, _status), do: Atom.to_string(code)
  defp run_reason_code(%Result{findings: [_ | _]}, _status), do: "external_review_findings"
  defp run_reason_code(_result, "failed"), do: "external_review_failed"
  defp run_reason_code(_result, "review_required"), do: "external_review_required"
  defp run_reason_code(_result, _status), do: nil

  defp severity_breakdown(findings) when is_list(findings) do
    findings
    |> Enum.map(&(&1.severity || "unknown"))
    |> Enum.frequencies()
  end

  defp run_details(%Result{details: details}) when is_map(details) and map_size(details) > 0,
    do: details

  defp run_details(%Result{failure: %Failure{details: details}}) when is_map(details), do: details
  defp run_details(_result), do: %{}

  def failure(config, workspace_path, reason_code, message, details) do
    %Result{
      provider: Map.get(config || %{}, "provider", @supported_provider),
      execution: Map.get(config || %{}, "execution", @supported_execution),
      status: "failed",
      decision: "require_human_review",
      reason_code: reason_code,
      message: message,
      summary: message,
      workspace_path: workspace_path,
      review_required: true,
      failure: %Failure{code: safe_code(reason_code), message: message, details: details || %{}},
      details: details || %{}
    }
  end

  def fingerprint(%Result{} = result) do
    findings = Enum.map(result.findings || [], &finding_summary/1)
    status = summary_status(result, findings)

    input = %{
      "provider" => result.provider,
      "execution" => result.execution,
      "status" => status,
      "reason_code" => summary_reason_code(result, status, findings),
      "exit_code" => result.exit_code,
      "findings" => findings,
      "severity_breakdown" => severity_breakdown(result, findings),
      "details" => result.details || %{}
    }

    "sha256:" <> Base.encode16(:crypto.hash(:sha256, Jason.encode!(input)), case: :lower)
  end

  defp provider_module(%{"provider" => @supported_provider}), do: ClawpatchLocal
  defp provider_module(_config), do: ClawpatchLocal

  defp review_provider_module(%{"provider" => "clawpatch_local"}),
    do: Cycle.Policy.ExternalReviewGate.ClawpatchLocal

  defp review_provider_module(%{"provider" => @supported_provider}),
    do: Cycle.Policy.ExternalReviewGate.ClawpatchLocal

  defp review_provider_module(%{"provider" => provider}) when is_atom(provider), do: provider
  defp review_provider_module(_config), do: Cycle.Policy.ExternalReviewGate.ClawpatchLocal

  defp validate_config(config) do
    cond do
      Map.get(config, "enabled") != true ->
        {:error, "external_review_disabled", "external review is disabled", %{}}

      Map.get(config, "provider") != @supported_provider ->
        {:error, "external_review_invalid_provider", "external review provider is unsupported",
         %{"provider" => inspect(Map.get(config, "provider"))}}

      Map.get(config, "execution") != @supported_execution ->
        {:error, "external_review_invalid_execution", "external review execution is unsupported",
         %{"execution" => inspect(Map.get(config, "execution"))}}

      true ->
        :ok
    end
  end

  defp validate_workspace(path) do
    cond do
      not is_binary(path) or Path.type(path) != :absolute ->
        {:error, "external_review_unsafe_workspace", "external review workspace must be absolute",
         %{"workspace_path" => inspect(path)}}

      not File.dir?(path) ->
        {:error, "external_review_unsafe_workspace", "external review workspace does not exist",
         %{"workspace_path" => path}}

      true ->
        :ok
    end
  end

  defp validate_workspace_match(workspace_path, run_workspace_path) do
    cond do
      not is_binary(run_workspace_path) ->
        :ok

      Path.type(run_workspace_path) != :absolute ->
        {:error, "external_review_unsafe_workspace",
         "external review run workspace must be absolute",
         %{"workspace_path" => inspect(run_workspace_path)}}

      Path.expand(workspace_path) != Path.expand(run_workspace_path) ->
        {:error, "external_review_workspace_mismatch",
         "external review workspace does not match run evidence",
         %{
           "git_workspace_path" => workspace_path,
           "run_workspace_path" => run_workspace_path
         }}

      true ->
        :ok
    end
  end

  defp finding_summary(%Finding{} = finding) do
    %{}
    |> put_present("severity", text(finding.severity, 80))
    |> put_present("title", text(finding.title, 160))
    |> put_present("summary", text(finding.summary, 300))
    |> put_present("path", text(finding.path, 240))
    |> put_present("line", finding.line)
    |> put_present("rule_id", text(finding.rule_id, 120))
  end

  defp finding_summary(finding) when is_map(finding) do
    finding
    |> stringify_keys()
    |> Map.take(["severity", "title", "summary", "path", "line", "rule_id"])
  end

  defp summary_status(%Result{status: status}, findings) do
    case status_key(status) do
      "passed" -> "passed"
      "review_required" -> if findings == [], do: "review_required", else: "findings"
      "failure" -> "failed"
      "failed" -> "failed"
      "skipped" -> "skipped"
      nil -> if findings == [], do: nil, else: "findings"
      other -> other
    end
  end

  defp summary_reason_code(%Result{reason_code: reason_code}, _status, _findings)
       when is_binary(reason_code) and reason_code != "" do
    reason_code
  end

  defp summary_reason_code(%Result{failure: %Failure{code: code}}, "failed", _findings)
       when is_atom(code),
       do: Atom.to_string(code)

  defp summary_reason_code(_result, "passed", _findings), do: nil
  defp summary_reason_code(_result, "findings", _findings), do: "external_review_findings"
  defp summary_reason_code(_result, "review_required", _findings), do: "external_review_required"
  defp summary_reason_code(_result, "failed", _findings), do: "external_review_failed"
  defp summary_reason_code(_result, _status, _findings), do: "external_review_required"

  defp severity_breakdown(%Result{severity_breakdown: counts}, _findings)
       when is_map(counts) and map_size(counts) > 0 do
    counts
  end

  defp severity_breakdown(_result, findings) do
    findings
    |> Enum.map(&Map.get(&1, "severity"))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp artifact_path(%Result{artifact_path: path}) when is_binary(path), do: path

  defp artifact_path(%Result{report: %Report{artifact: %Artifact{path: path}}})
       when is_binary(path),
       do: path

  defp artifact_path(%Result{artifacts: [%Artifact{path: path} | _]}) when is_binary(path),
    do: path

  defp artifact_path(%Result{} = result), do: metadata_value(result, "artifact_path")

  defp metadata_value(%Result{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))
  end

  defp metadata_value(_result, _key), do: nil

  defp status_key(nil), do: nil
  defp status_key(value) when is_atom(value), do: value |> Atom.to_string() |> status_key()

  defp status_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
  end

  defp status_key(value), do: value |> to_string() |> status_key()

  defp safe_code(reason_code) when is_binary(reason_code) do
    reason_code
    |> status_key()
    |> String.to_atom()
  end

  defp safe_code(_reason_code), do: :external_review_failed

  defp text(nil, _max), do: nil

  defp text(value, max) do
    value
    |> to_string()
    |> Cycle.Security.redact()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> empty_to_nil()
    |> slice(max)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  defp put_present(map, _key, value) when is_list(value) and value == [], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp slice(nil, _max), do: nil
  defp slice(value, max), do: String.slice(value, 0, max)

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
