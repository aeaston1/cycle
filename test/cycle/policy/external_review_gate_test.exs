defmodule Cycle.Policy.ExternalReviewGateTest do
  use ExUnit.Case, async: true

  alias Cycle.Policy.ExternalReviewGate
  alias Cycle.Policy.ExternalReviewGate.Clawpatch
  alias Cycle.Policy.ExternalReviewGate.ClawpatchLocal
  alias Cycle.Policy.ExternalReviewGate.Result
  alias Cycle.Policy.ReviewEvidence.Evidence

  test "facade delegates to injected provider" do
    assert %Result{status: :passed, provider: "fake"} =
             ExternalReviewGate.review(workspace(), %{"enabled" => true},
               provider: __MODULE__.FakeProvider
             )
  end

  test "disabled or absent config skips without invoking a provider" do
    assert %Result{status: :skipped, decision: nil, review_required: false} =
             ExternalReviewGate.review(workspace(), nil, provider: UnexpectedProvider)

    assert %Result{status: :skipped, decision: nil, review_required: false} =
             ExternalReviewGate.review(workspace(), %{"enabled" => false},
               provider: UnexpectedProvider
             )
  end

  test "run rejects mismatched evidence workspaces before invoking provider" do
    git_workspace = workspace()
    run_workspace = workspace()

    result =
      ExternalReviewGate.run(
        %{
          git: %{"workspace_path" => git_workspace},
          run: %{"workspace_path" => run_workspace}
        },
        %{
          "external_review" => %{
            "enabled" => true,
            "provider" => "clawpatch",
            "execution" => "local_workspace"
          }
        },
        external_review_provider: UnexpectedProvider
      )

    assert result.status == "failed"
    assert result.decision == "require_human_review"
    assert result.reason_code == "external_review_workspace_mismatch"
  end

  test "compatibility run respects disabled config without invoking provider" do
    result =
      Clawpatch.run(
        %Evidence{},
        %{"enabled" => false},
        workspace_path: workspace(),
        command_runner: fn _executable, _args, _opts ->
          raise "disabled external review should not invoke a provider"
        end
      )

    assert result.status == :skipped
    assert result.decision == nil
    refute result.review_required
  end

  test "runs executable args in the workspace and normalizes a clean JSON report" do
    parent = self()
    workspace = workspace()

    result =
      ClawpatchLocal.review(
        workspace,
        %{
          "executable" => "clawpatch",
          "args" => ["review", "--json"],
          "timeout_ms" => 1_000,
          "artifact_dir" => artifact_dir()
        },
        command_runner: fn executable, args, opts ->
          send(parent, {:command, executable, args, opts})

          {Jason.encode!(%{"status" => "passed", "summary" => "  no issues\nfound  "}), 0}
        end
      )

    assert %Result{status: :passed, decision: "proceed_to_merging"} = result
    assert result.summary == "no issues found"
    assert result.command.timeout_ms == 1_000
    assert_received {:command, "clawpatch", ["review", "--json"], opts}
    assert opts[:cd] == workspace
    assert opts[:stderr_to_stdout] == true
  end

  test "normalizes findings and requires review when report contains findings" do
    result =
      ClawpatchLocal.review(
        workspace(),
        config(),
        command_runner: fn _executable, _args, _opts ->
          report = %{
            "status" => "completed",
            "summary" => "Review finished",
            "findings" => [
              %{
                "severity" => "HIGH",
                "title" => "Mutation risk",
                "message" => "  Provider tried\n  to edit state.  ",
                "file" => "lib/cycle/reconciler.ex",
                "line" => "42",
                "rule_id" => "readonly-boundary"
              }
            ]
          }

          {Jason.encode!(report), 0}
        end
      )

    assert result.status == :review_required
    assert result.decision == "require_human_review"
    assert [finding] = result.findings
    assert finding.severity == "high"
    assert finding.summary == "Provider tried to edit state."
    assert finding.path == "lib/cycle/reconciler.ex"
    assert finding.line == 42
    assert finding.rule_id == "readonly-boundary"
  end

  test "status-only review requirement is not labeled as findings" do
    result =
      ClawpatchLocal.review(
        workspace(),
        config(),
        command_runner: fn _executable, _args, _opts ->
          {Jason.encode!(%{"status" => "blocked", "summary" => "provider blocked"}), 0}
        end
      )

    assert result.status == :review_required
    assert result.decision == "require_human_review"
    assert result.reason_code == "external_review_required"
    assert result.findings == []
  end

  test "empty or unknown successful provider reports fail closed" do
    for report <- [%{}, %{"status" => "typo"}] do
      result =
        ClawpatchLocal.review(
          workspace(),
          config(),
          command_runner: fn _executable, _args, _opts ->
            {Jason.encode!(report), 0}
          end
        )

      assert result.status == :failure
      assert result.decision == "require_human_review"
      assert result.failure.code == :provider_report_failure
    end
  end

  test "rejects shell command string config without running provider" do
    parent = self()

    result =
      ClawpatchLocal.review(
        workspace(),
        %{"command" => "clawpatch review --json", "artifact_dir" => artifact_dir()},
        command_runner: fn _executable, _args, _opts ->
          send(parent, :unexpected_command)
          {"{}", 0}
        end
      )

    assert result.status == :failure
    assert result.decision == "require_human_review"
    assert result.failure.code == :invalid_config
    refute_received :unexpected_command
  end

  test "rejects non-review clawpatch args without running provider" do
    parent = self()

    result =
      ClawpatchLocal.review(
        workspace(),
        %{
          "executable" => "clawpatch",
          "args" => ["fix", "--finding", "finding-1"],
          "artifact_dir" => artifact_dir()
        },
        command_runner: fn _executable, _args, _opts ->
          send(parent, :unexpected_command)
          {"{}", 0}
        end
      )

    assert result.status == :failure
    assert result.decision == "require_human_review"
    assert result.failure.code == :invalid_config
    refute_received :unexpected_command
  end

  test "provider non-zero exit returns failure and requires review" do
    result =
      ClawpatchLocal.review(
        workspace(),
        config(),
        command_runner: fn _executable, _args, _opts ->
          {"clawpatch unavailable", 127}
        end
      )

    assert result.status == :failure
    assert result.decision == "require_human_review"
    assert result.review_required
    assert result.failure.code == :provider_exit
    assert result.failure.details["exit_status"] == 127
  end

  test "provider timeout returns failure instead of raising" do
    result =
      ClawpatchLocal.review(
        workspace(),
        Map.put(config(), "timeout_ms", 10),
        command_runner: fn _executable, _args, _opts ->
          Process.sleep(1_000)
          {"{}", 0}
        end
      )

    assert result.status == :failure
    assert result.decision == "require_human_review"
    assert result.failure.code == :provider_timeout
    assert result.failure.details["timeout_ms"] == 10
  end

  test "reads report artifact under configured artifact dir and renders report path arg" do
    parent = self()
    artifact_dir = artifact_dir()
    report_path = Path.join([artifact_dir, "reports", "clawpatch.json"])
    log_path = Path.join([artifact_dir, "logs", "finding.json"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "{}")

    result =
      ClawpatchLocal.review(
        workspace(),
        %{
          "executable" => "clawpatch",
          "args" => ["review", "--output", "${report_path}"],
          "artifact_dir" => artifact_dir,
          "report_path" => "reports/clawpatch.json"
        },
        command_runner: fn _executable, args, _opts ->
          send(parent, {:args, args})
          File.mkdir_p!(Path.dirname(report_path))

          File.write!(
            report_path,
            Jason.encode!(%{
              "status" => "passed",
              "summary" => "artifact report",
              "findings" => [
                %{"summary" => "attached context", "artifact_path" => "logs/finding.json"}
              ]
            })
          )

          {"", 0}
        end
      )

    assert_received {:args, ["review", "--output", ^report_path]}
    assert result.status == :review_required
    assert result.report.artifact.path == report_path
    assert [report_artifact, finding_artifact] = result.artifacts
    assert report_artifact.kind == "report"
    assert finding_artifact.path == log_path
    assert finding_artifact.relative_path == "logs/finding.json"
    assert finding_artifact.exists == true
  end

  test "uses existing clawpatch and crabbox config from the workspace" do
    parent = self()
    workspace = workspace()
    artifact_dir = artifact_dir()
    clawpatch_config = Path.join(workspace, ".clawpatch/config.json")
    crabbox_config = Path.join(workspace, "crabbox.toml")
    File.mkdir_p!(Path.dirname(clawpatch_config))
    File.write!(clawpatch_config, ~s({"profile":"repo"}\n))
    File.write!(crabbox_config, "runtime = \"repo\"\n")

    result =
      ClawpatchLocal.review(
        workspace,
        %{
          "executable" => "clawpatch",
          "args" => [
            "review",
            "--clawpatch-config",
            "${clawpatch_config_path}",
            "--crabbox-config",
            "${crabbox_config_path}"
          ],
          "artifact_dir" => artifact_dir
        },
        command_runner: fn _executable, args, opts ->
          send(parent, {:command, args, opts})
          {Jason.encode!(%{"status" => "passed"}), 0}
        end
      )

    assert result.status == :passed

    assert_received {:command,
                     [
                       "review",
                       "--clawpatch-config",
                       ^clawpatch_config,
                       "--crabbox-config",
                       ^crabbox_config
                     ], opts}

    assert {"CYCLE_CLAWPATCH_CONFIG_PATH", clawpatch_config} in opts[:env]
    assert {"CYCLE_CRABBOX_CONFIG_PATH", crabbox_config} in opts[:env]
    assert {"CYCLE_CRABBOX_CONFIG_SOURCE", "workspace"} in opts[:env]
  end

  test "creates opinionated Crabbox Cloudflare Workers fallback under artifact dir" do
    parent = self()
    workspace = workspace()
    artifact_dir = artifact_dir()

    result =
      ClawpatchLocal.review(
        workspace,
        %{
          "executable" => "clawpatch",
          "args" => ["review", "--crabbox-config", "${crabbox_config_path}"],
          "artifact_dir" => artifact_dir
        },
        command_runner: fn _executable, args, opts ->
          send(parent, {:command, args, opts})
          {Jason.encode!(%{"status" => "passed"}), 0}
        end
      )

    assert result.status == :passed

    assert_received {:command, ["review", "--crabbox-config", fallback_path], opts}
    assert fallback_path == Path.join(artifact_dir, "cycle-crabbox.cloudflare-workers.json")
    assert {"CYCLE_CRABBOX_CONFIG_PATH", fallback_path} in opts[:env]
    assert {"CYCLE_CRABBOX_CONFIG_SOURCE", "cycle_cloudflare_workers_default"} in opts[:env]

    assert Jason.decode!(File.read!(fallback_path)) == %{
             "credentials" => "external_plugin",
             "managed_by" => "cycle",
             "mode" => "review",
             "provider" => "cloudflare_workers",
             "runtime" => "cloudflare_workers",
             "schema" => "cycle.external_review.crabbox.v1"
           }
  end

  test "report path cannot escape configured artifact dir" do
    parent = self()
    artifact_dir = artifact_dir()

    result =
      ClawpatchLocal.review(
        workspace(),
        %{
          "executable" => "clawpatch",
          "args" => [],
          "artifact_dir" => artifact_dir,
          "report_path" => "../outside.json"
        },
        command_runner: fn _executable, _args, _opts ->
          send(parent, :unexpected_command)
          {"{}", 0}
        end
      )

    assert result.status == :failure
    assert result.failure.code == :invalid_artifact_path
    refute_received :unexpected_command
  end

  defmodule FakeProvider do
    @behaviour ExternalReviewGate

    def review(_workspace, _config, _opts) do
      ExternalReviewGate.passed(provider: "fake")
    end
  end

  defmodule UnexpectedProvider do
    @behaviour ExternalReviewGate

    def review(_workspace, _config, _opts) do
      raise "disabled external review should not invoke a provider"
    end
  end

  defp config do
    %{
      "executable" => "clawpatch",
      "args" => ["review", "--json"],
      "timeout_ms" => 1_000,
      "artifact_dir" => artifact_dir()
    }
  end

  defp workspace do
    path = Path.join(System.tmp_dir!(), "cycle-clawpatch-workspace-#{unique()}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp artifact_dir do
    path = Path.join(System.tmp_dir!(), "cycle-clawpatch-artifacts-#{unique()}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp unique, do: System.unique_integer([:positive])
end
