defmodule Cycle.Registry.StoreTest do
  use ExUnit.Case, async: false

  alias Cycle.Registry.Store

  test "missing registry file returns the supplied empty default" do
    path = Path.join(temp_root(), "missing/projects.yaml")

    assert Store.read(path, []) == {:ok, []}
  end

  test "write and read round trip through YAML" do
    root = temp_root()
    path = Path.join(root, "state/projects.yaml")

    data = %{
      projects: [
        %{
          repo: "https://github.com/OWNER/REPO.git",
          enabled: true,
          capacity: %{"max_concurrent_runs" => 2}
        }
      ]
    }

    try do
      assert Store.write(path, data) == :ok
      assert {:ok, read} = Store.read(path, %{})

      assert read == %{
               "projects" => [
                 %{
                   "repo" => "https://github.com/OWNER/REPO.git",
                   "enabled" => true,
                   "capacity" => %{"max_concurrent_runs" => 2}
                 }
               ]
             }
    after
      File.rm_rf!(root)
    end
  end

  test "invalid YAML returns an error with the file path and parse reason" do
    root = temp_root()
    path = Path.join(root, "projects.yaml")
    File.mkdir_p!(root)
    File.write!(path, "projects: [")

    try do
      assert {:error, {:invalid_yaml, ^path, reason}} = Store.read(path, [])
      assert is_binary(reason)
      assert reason != ""
    after
      File.rm_rf!(root)
    end
  end

  test "write creates parent directories with safe permissions" do
    root = temp_root()
    parent = Path.join(root, "nested/state")
    path = Path.join(parent, "engines.yaml")

    try do
      assert Store.write(path, %{engines: []}) == :ok
      assert File.dir?(parent)

      assert {:ok, parent_stat} = File.stat(parent)
      assert {:ok, file_stat} = File.stat(path)
      assert Bitwise.band(parent_stat.mode, 0o777) == 0o700
      assert Bitwise.band(file_stat.mode, 0o777) == 0o600
    after
      File.rm_rf!(root)
    end
  end

  test "failed encode does not replace the old valid registry" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")
    old_data = %{runs: [%{id: "run-1", state: "running"}]}

    try do
      assert Store.write(path, old_data) == :ok
      old_content = File.read!(path)

      assert {:error, {:encode_failed, _reason}} = Store.write(path, %{bad: self()})

      assert File.read!(path) == old_content

      assert Store.read(path, %{}) ==
               {:ok, %{"runs" => [%{"id" => "run-1", "state" => "running"}]}}
    after
      File.rm_rf!(root)
    end
  end

  test "default registry paths stay under Cycle state, not the repository" do
    root = temp_root()
    home = Path.join(root, "home")
    cycle_home = Path.join(root, "cycle-state")

    try do
      path = Store.path(:projects, env: %{"CYCLE_HOME" => cycle_home}, home: home)

      assert path == Path.join(cycle_home, "projects.yaml")
      refute String.starts_with?(path, File.cwd!())
    after
      File.rm_rf!(root)
    end
  end

  defp temp_root do
    Path.join(
      System.tmp_dir!(),
      "cycle-registry-store-test-#{System.unique_integer([:positive])}"
    )
  end
end
