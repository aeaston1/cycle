defmodule Cycle.PolicyPropagationTest do
  use ExUnit.Case, async: true

  alias Cycle.PolicyPropagation
  alias Cycle.ProjectRegistry.Project

  test "prepare rejects front matter delimiter prefixes" do
    workflow_path =
      write_workflow!("""
      ---
      name: example
      review_judge:
        enabled: true
      ---- not a delimiter
      ---
      # Workflow
      """)

    assert {:error, reason} = PolicyPropagation.prepare(project(workflow_path))
    assert reason =~ "workflow YAML is invalid"
  end

  test "prepare keeps the closing front matter delimiter on its own line" do
    workflow_path =
      write_workflow!("""
      ---
      name: example
      review_judge:
        enabled: true
      ---
      # Workflow
      """)

    assert {:ok, patch} = PolicyPropagation.prepare(project(workflow_path))
    assert patch.updated =~ "  policy: standard\n---\n# Workflow"
  end

  defp write_workflow!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cycle-policy-propagation-#{System.unique_integer([:positive])}.md"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    path
  end

  defp project(workflow_path) do
    %Project{
      workflow: %{"resolved_path" => workflow_path},
      policy_drift: %{
        "records" => [
          %{
            "path" => "review_judge.policy",
            "desired" => "standard",
            "observed" => nil,
            "severity" => "info",
            "propagation_available" => true
          }
        ]
      }
    }
  end
end
