defmodule Cycle.ProjectMetadataTest do
  use ExUnit.Case, async: true

  alias Cycle.ProjectMetadata

  test "valid minimal cycle metadata parses" do
    assert {:ok, metadata} =
             ProjectMetadata.parse("""
             cycle:
               enabled: true
               repo: https://github.com/OWNER/REPO
             """)

    assert metadata.repo_url == "https://github.com/OWNER/REPO.git"
    assert metadata.repo_full_name == "OWNER/REPO"
    assert metadata.workflow_path == "WORKFLOW.md"
    assert metadata.source == %{namespace: "cycle", field: "metadata", line: 1}
  end

  test "valid recommended cycle metadata parses" do
    assert {:ok, metadata} =
             ProjectMetadata.parse(
               """
               Introductory Linear copy.

               cycle:
                 enabled: true
                 repo: https://github.com/OWNER/REPO.git
                 workflow: .cycle/workflow.yml
                 engines:
                   - openai-symphony@main
                 policy:
                   review_judge: default
                 capacity:
                   max_concurrent_agents: 2
                   max_concurrent_agents_by_state:
                     In Progress: 1
                 display_name: Cycle Public Repo
               """,
               field: "description"
             )

    assert metadata.repo_url == "https://github.com/OWNER/REPO.git"
    assert metadata.workflow_path == ".cycle/workflow.yml"
    assert metadata.allowed_engines == ["openai-symphony@main"]
    assert metadata.policy_profile == "default"
    assert metadata.capacity["max_concurrent_agents"] == 2
    assert metadata.unknown_fields == %{"display_name" => "Cycle Public Repo"}
    assert metadata.source == %{namespace: "cycle", field: "description", line: 3}
  end

  test "symphony metadata only is not opted in" do
    assert :not_opted_in =
             ProjectMetadata.parse("""
             symphony:
               enabled: true
               repo: https://github.com/OWNER/REPO.git
             """)
  end

  test "symphony metadata does not supplement cycle metadata" do
    assert {:error, errors} =
             ProjectMetadata.parse("""
             symphony:
               enabled: true
               repo: https://github.com/OWNER/REPO.git

             cycle:
               enabled: true
             """)

    assert %{path: "cycle.repo", reason: "must be an HTTPS GitHub repo URL"} in errors
  end

  test "disabled projects are not valid opted-in projects" do
    assert {:error, errors} =
             ProjectMetadata.parse("""
             cycle:
               enabled: false
               repo: https://github.com/OWNER/REPO.git
             """)

    assert %{path: "cycle.enabled", reason: "must be true to opt in"} in errors
  end

  test "invalid yaml returns a structured error" do
    assert {:error, [%{path: "cycle", reason: reason}]} =
             ProjectMetadata.parse("""
             cycle:
               enabled: true
                repo: https://github.com/OWNER/REPO.git
             """)

    assert reason =~ "invalid YAML"
  end

  test "invalid repo url is reported clearly" do
    assert {:error, errors} =
             ProjectMetadata.parse("""
             cycle:
               enabled: true
               repo: ssh://github.com/OWNER/REPO.git
             """)

    assert %{path: "cycle.repo", reason: "must be an HTTPS GitHub repo URL"} in errors
  end

  test "non-positive capacity values are rejected" do
    assert {:error, errors} =
             ProjectMetadata.parse("""
             cycle:
               enabled: true
               repo: https://github.com/OWNER/REPO.git
               capacity:
                 max_concurrent_agents: 0
                 max_concurrent_agents_by_state:
                   Todo: -1
             """)

    assert %{path: "cycle.capacity.max_concurrent_agents", reason: "must be a positive integer"} in errors

    assert %{
             path: "cycle.capacity.max_concurrent_agents_by_state.Todo",
             reason: "must be a positive integer"
           } in errors
  end

  test "workflow path must be a repo-relative string" do
    assert {:error, errors} =
             ProjectMetadata.parse("""
             cycle:
               enabled: true
               repo: https://github.com/OWNER/REPO.git
               workflow: /tmp/WORKFLOW.md
             """)

    assert %{path: "cycle.workflow", reason: "must be a repo-relative path"} in errors
  end

  test "token-looking fields are rejected" do
    assert {:error, errors} =
             ProjectMetadata.parse("""
             cycle:
               enabled: true
               repo: https://github.com/OWNER/REPO.git
               api_key: real-value-must-not-live-here
             """)

    assert %{path: "cycle.api_key", reason: "must not contain secrets or tokens"} in errors
  end
end
