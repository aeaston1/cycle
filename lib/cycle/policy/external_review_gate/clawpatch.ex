defmodule Cycle.Policy.ExternalReviewGate.Clawpatch do
  @moduledoc """
  Compatibility wrapper for the local Clawpatch external review provider.

  New callers should use `Cycle.Policy.ExternalReviewGate.run/3` or
  `Cycle.Policy.ExternalReviewGate.ClawpatchLocal.review/3`.
  """

  alias Cycle.Policy.ExternalReviewGate
  alias Cycle.Policy.ExternalReviewGate.Failure
  alias Cycle.Policy.ExternalReviewGate.Report
  alias Cycle.Policy.ExternalReviewGate.Result
  alias Cycle.Policy.ReviewEvidence.Evidence

  @behaviour ExternalReviewGate

  @impl true
  def review(workspace, config, opts) do
    ExternalReviewGate.ClawpatchLocal.review(workspace, config, opts)
  end

  def run(%Evidence{} = evidence, config, opts \\ []) when is_map(config) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    started_at = System.monotonic_time(:millisecond)

    result =
      if Map.get(config, "enabled", true) == false do
        ExternalReviewGate.skipped("external review is disabled")
      else
        workspace_path
        |> ExternalReviewGate.ClawpatchLocal.review(Map.put_new(config, "enabled", true), opts)
        |> normalize(config, evidence, workspace_path, started_at)
      end

    %{result | fingerprint: result.fingerprint || ExternalReviewGate.fingerprint(result)}
  end

  defp normalize(%Result{} = result, config, evidence, workspace_path, started_at) do
    status = status(result)
    findings = result.findings || []

    %Result{
      provider: Map.get(config, "provider", "clawpatch"),
      execution: Map.get(config, "execution", "local_workspace"),
      status: status,
      reason_code: reason_code(result, status),
      message: result.message || result.summary,
      workspace_path: workspace_path,
      artifact_path: artifact_path(result),
      log_path: log_path(result),
      exit_code: nil,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      findings: findings,
      severity_breakdown: severity_breakdown(findings),
      details: details(result),
      report: result.report,
      command: result.command,
      failure: result.failure,
      artifacts: result.artifacts || [],
      review_required: status != "passed",
      decision: if(status == "passed", do: "proceed_to_merging", else: "require_human_review")
    }
    |> maybe_workspace_mismatch(evidence)
  end

  defp status(%Result{status: :passed}), do: "passed"
  defp status(%Result{status: :failure}), do: "failed"
  defp status(%Result{status: :skipped}), do: "failed"
  defp status(%Result{status: :review_required}), do: "review_required"
  defp status(%Result{status: status}) when is_binary(status), do: status
  defp status(_result), do: "failed"

  defp reason_code(%Result{reason_code: reason_code}, _status) when is_binary(reason_code),
    do: reason_code

  defp reason_code(%Result{failure: %Failure{code: code}}, _status), do: Atom.to_string(code)
  defp reason_code(%Result{findings: [_ | _]}, _status), do: "external_review_findings"
  defp reason_code(_result, "failed"), do: "external_review_failed"
  defp reason_code(_result, "review_required"), do: "external_review_findings"
  defp reason_code(_result, _status), do: nil

  defp artifact_path(%Result{artifact_path: path}) when is_binary(path), do: path

  defp artifact_path(%Result{report: %Report{artifact: %{path: path}}}) when is_binary(path),
    do: path

  defp artifact_path(_result), do: nil

  defp log_path(%Result{log_path: path}) when is_binary(path), do: path
  defp log_path(_result), do: nil

  defp details(%Result{details: details}) when is_map(details) and map_size(details) > 0,
    do: details

  defp details(%Result{failure: %Failure{details: details}}) when is_map(details), do: details
  defp details(_result), do: %{}

  defp severity_breakdown(findings) do
    findings
    |> Enum.map(&(&1.severity || "unknown"))
    |> Enum.frequencies()
  end

  defp maybe_workspace_mismatch(%Result{} = result, %Evidence{} = evidence) do
    run_workspace_path = get_in(evidence.run || %{}, ["workspace_path"])

    if is_binary(run_workspace_path) and
         Path.expand(run_workspace_path) != Path.expand(result.workspace_path) do
      %{
        result
        | status: "failed",
          reason_code: "external_review_workspace_mismatch",
          message: "external review workspace does not match run evidence",
          details: %{
            "git_workspace_path" => result.workspace_path,
            "run_workspace_path" => run_workspace_path
          },
          decision: "require_human_review",
          review_required: true
      }
    else
      result
    end
  end
end
