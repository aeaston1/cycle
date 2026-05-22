defmodule Cycle.ProjectDiscoveryTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Cycle.Linear.Client
  alias Cycle.ProjectDiscovery
  alias Cycle.ProjectRegistry
  alias Cycle.Registry.Store

  test "discovers mixed valid and invalid opted-in projects without failing" do
    now = ~U[2026-05-22 12:00:00Z]
    name = unique_stub()

    stub_projects(name, [
      linear_project(%{
        "id" => "valid-id",
        "name" => "Valid Project",
        "slugId" => "VALID",
        "description" => """
        cycle:
          enabled: true
          repo: https://github.com/OWNER/REPO.git
          workflow: ops/WORKFLOW.md
        """
      }),
      linear_project(%{
        "id" => "invalid-id",
        "name" => "Invalid Project",
        "slugId" => "INVALID",
        "description" => """
        cycle:
          enabled: true
        """
      }),
      linear_project(%{
        "id" => "ignored-id",
        "name" => "Ignored Project",
        "slugId" => "IGNORED",
        "description" => """
        symphony:
          enabled: true
          repo: https://github.com/OWNER/IGNORED.git
        """
      })
    ])

    root = temp_root()
    registry_path = Path.join(root, "projects.yaml")
    checkout_path = Path.join(root, "checkout")
    write_workflow!(checkout_path, "ops/WORKFLOW.md")

    assert {:ok, result} =
             ProjectDiscovery.discover(client(name),
               registry_path: registry_path,
               workflow_resolver: [
                 cache_root: Path.join(root, "workflow-cache"),
                 local_checkout_paths: [checkout_path]
               ],
               now: now,
               limit: 50
             )

    assert length(result.records) == 2

    assert %ProjectRegistry.Project{
             status: "valid",
             metadata_namespace: "cycle",
             repo: %{"url" => "https://github.com/OWNER/REPO.git"},
             workflow: %{
               "path" => "ops/WORKFLOW.md",
               "policy_hash" => policy_hash,
               "policy" => workflow_policy
             },
             last_discovered_at: "2026-05-22T12:00:00Z"
           } = Enum.find(result.records, &(get_in(&1.linear_project, ["id"]) == "valid-id"))

    assert policy_hash =~ ~r/^sha256:[0-9a-f]{64}$/
    assert workflow_policy["agent"]["max_concurrent_agents"] == 2
    assert workflow_policy["agent"]["max_concurrent_agents_by_state"] == %{"in_progress" => 1}
    assert workflow_policy["tracker"]["active_states"] == ["Todo", "In Progress"]
    assert workflow_policy["review_judge"]["enabled"] == true
    assert workflow_policy["worker"]["ssh_hosts"] == ["worker-1"]
    assert workflow_policy["hooks"] == %{"before_run" => ["tests/smoke.sh"]}

    assert %ProjectRegistry.Project{
             status: "invalid",
             error: error,
             repo: %{},
             workflow: %{}
           } = Enum.find(result.records, &(get_in(&1.linear_project, ["id"]) == "invalid-id"))

    assert error =~ "cycle.repo"

    assert {:ok, raw} = Store.read(registry_path, %{})
    assert {:ok, registry} = ProjectRegistry.from_map(raw)
    assert Enum.map(registry.projects, & &1.status) |> Enum.sort() == ["invalid", "valid"]
  end

  test "invalid workflow policy marks only that project invalid" do
    now = ~U[2026-05-22 12:00:00Z]
    name = unique_stub()

    stub_projects(name, [
      linear_project(%{
        "id" => "bad-workflow-id",
        "description" => """
        cycle:
          enabled: true
          repo: https://github.com/OWNER/REPO.git
        """
      })
    ])

    root = temp_root()
    checkout_path = Path.join(root, "checkout")
    write_workflow!(checkout_path, "WORKFLOW.md", "# Missing front matter\n")

    assert {:ok, result} =
             ProjectDiscovery.discover(client(name),
               registry_path: Path.join(root, "projects.yaml"),
               workflow_resolver: [
                 cache_root: Path.join(root, "workflow-cache"),
                 local_checkout_paths: [checkout_path]
               ],
               now: now
             )

    assert [
             %ProjectRegistry.Project{
               status: "invalid",
               error: "workflow: workflow: missing YAML front matter"
             }
           ] = result.records
  end

  test "registry write errors are discovery-wide failures" do
    name = unique_stub()

    stub_projects(name, [
      linear_project(%{
        "description" => """
        cycle:
          enabled: true
          repo: https://github.com/OWNER/REPO.git
        """
      })
    ])

    root = temp_root()
    registry_path = Path.join(root, "projects.yaml")
    File.mkdir_p!(registry_path)

    assert {:error, {:rename_failed, _temp_path, ^registry_path, :eisdir}} =
             ProjectDiscovery.discover(client(name), registry_path: registry_path)
  end

  defp client(name) do
    Client.new(token: "lin_test", req_options: Cycle.TestSupport.linear_graphql_req_options(name))
  end

  defp stub_projects(name, projects) do
    Req.Test.stub(name, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["query"] =~ "query CycleListProjects"

      Req.Test.json(conn, %{
        "data" => %{
          "projects" => %{
            "nodes" => projects,
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      })
    end)
  end

  defp linear_project(overrides) do
    Map.merge(
      %{
        "id" => "project-id",
        "name" => "Project",
        "slugId" => "PROJECT",
        "url" => "https://linear.app/example/project/project-id",
        "description" => nil,
        "content" => nil
      },
      overrides
    )
  end

  defp temp_root do
    root =
      Path.join(System.tmp_dir!(), "cycle-discovery-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_workflow!(root, path, content \\ valid_workflow()) do
    workflow_path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, content)
    root
  end

  defp valid_workflow do
    """
    ---
    agent:
      max_concurrent_agents: 2
      max_concurrent_agents_by_state:
        In Progress: 1
    tracker:
      active_states:
        - Todo
        - In Progress
      terminal_states:
        - Done
    review_judge:
      enabled: true
    worker:
      ssh_hosts:
        - worker-1
    hooks:
      before_run:
        - tests/smoke.sh
    unknown_engine_field:
      prompt: ignored
    ---
    Engine prompt body.
    """
  end

  defp unique_stub, do: :"project-discovery-test-#{System.unique_integer([:positive])}"
end
