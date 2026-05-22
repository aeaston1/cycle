defmodule Cycle.WorkflowResolverTest do
  use ExUnit.Case, async: false

  alias Cycle.WorkflowResolver

  test "sanitizes repo full names for cache paths" do
    assert WorkflowResolver.sanitize_repo_full_name("OWNER/REPO") == "OWNER-REPO"
    assert WorkflowResolver.sanitize_repo_full_name("owner/repo.name") == "owner-repo.name"
  end

  test "resolves workflow from a local repo path" do
    root = temp_root()
    repo = write_workflow!(Path.join(root, "repo"), "ops/WORKFLOW.md", "policy")

    assert {:ok, result} =
             WorkflowResolver.resolve(
               %{"url" => repo, "full_name" => "OWNER/REPO"},
               "ops/WORKFLOW.md",
               cache_root: Path.join(root, "cache")
             )

    assert result.path == "ops/WORKFLOW.md"
    assert result.resolved_path == Path.join(repo, "ops/WORKFLOW.md")
    assert result.cache_path == repo
    assert result.content == "policy"
    assert result.hash =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "resolves workflow from an existing local checkout" do
    root = temp_root()
    checkout = write_workflow!(Path.join(root, "OWNER/REPO"), "WORKFLOW.md", "checkout")

    assert {:ok, result} =
             WorkflowResolver.resolve(
               %{"url" => "https://github.com/OWNER/REPO.git", "full_name" => "OWNER/REPO"},
               "WORKFLOW.md",
               cache_root: Path.join(root, "cache"),
               local_checkout_roots: [root]
             )

    assert result.resolved_path == Path.join(checkout, "WORKFLOW.md")
    assert result.content == "checkout"
  end

  test "returns a clear error when workflow is missing" do
    root = temp_root()
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    assert {:error, "workflow not found at WORKFLOW.md"} =
             WorkflowResolver.resolve(
               %{"url" => repo, "full_name" => "OWNER/REPO"},
               "WORKFLOW.md",
               cache_root: Path.join(root, "cache")
             )
  end

  test "clones HTTPS GitHub repos into workflow cache when needed" do
    root = temp_root()
    cache_root = Path.join(root, "cache")

    git = fn "git",
             ["clone", "--quiet", "https://github.com/OWNER/REPO.git", cache_path],
             _opts ->
      File.mkdir_p!(Path.join(cache_path, ".git"))
      File.write!(Path.join(cache_path, "WORKFLOW.md"), "cloned")
      {"", 0}
    end

    assert {:ok, result} =
             WorkflowResolver.resolve(
               %{"url" => "https://github.com/OWNER/REPO.git", "full_name" => "OWNER/REPO"},
               "WORKFLOW.md",
               cache_root: cache_root,
               git: git
             )

    assert result.cache_path == Path.join(cache_root, "OWNER-REPO")
    assert result.content == "cloned"
  end

  test "fetches existing workflow cache safely" do
    root = temp_root()
    cache_root = Path.join(root, "cache")
    cache_path = write_workflow!(Path.join(cache_root, "OWNER-REPO"), "WORKFLOW.md", "cached")
    File.mkdir_p!(Path.join(cache_path, ".git"))

    git = fn "git", ["-C", ^cache_path, "fetch", "--prune", "--tags"], _opts -> {"", 0} end

    assert {:ok, result} =
             WorkflowResolver.resolve(
               %{"url" => "https://github.com/OWNER/REPO.git", "full_name" => "OWNER/REPO"},
               "WORKFLOW.md",
               cache_root: cache_root,
               git: git
             )

    assert result.resolved_path == Path.join(cache_path, "WORKFLOW.md")
    assert result.content == "cached"
  end

  defp temp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "cycle-workflow-resolver-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_workflow!(root, path, content) do
    workflow_path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, content)
    root
  end
end
