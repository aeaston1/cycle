defmodule Cycle.SecurityTest do
  use ExUnit.Case, async: true

  @fake_token "lin_9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b"

  test "redacts authorization headers, credentialed urls, keys, and high entropy values" do
    redacted =
      Cycle.Security.redact(%{
        "Authorization" => "Bearer #{@fake_token}",
        "message" => "clone https://user:#{@fake_token}@github.com/OWNER/REPO.git",
        "repo_url" => "clone https://#{@fake_token}@github.com/OWNER/REPO.git",
        "nested" => %{"api_key" => @fake_token}
      })

    encoded = inspect(redacted)

    refute encoded =~ @fake_token
    assert redacted["Authorization"] == "[REDACTED]"
    assert redacted["nested"]["api_key"] == "[REDACTED]"
    assert redacted["message"] =~ "https://[REDACTED]@github.com/OWNER/REPO.git"
    assert redacted["repo_url"] =~ "https://[REDACTED]@github.com/OWNER/REPO.git"
  end

  test "public docs scan allows the Homebrew tap and rejects private repo names" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "README.md"), "brew install aeaston1/tap/cycle\n")
    File.write!(Path.join(root, "docs/release.md"), "clone aeaston1/cycle\n")

    assert [
             %{
               path: "docs/release.md",
               reason: "contains private repo name",
               value: "aeaston1/cycle"
             }
           ] = Cycle.Security.scan_public_docs(root)
  end

  test "public docs scan includes skill sources" do
    root = tmp_dir()
    skill_dir = Path.join(root, "skills/example")
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "clone aeaston1/cycle\n")

    assert [
             %{
               path: "skills/example/SKILL.md",
               reason: "contains private repo name",
               value: "aeaston1/cycle"
             }
           ] = Cycle.Security.scan_public_docs(root)
  end

  test "public docs scan includes root workflow" do
    root = tmp_dir()
    File.write!(Path.join(root, "WORKFLOW.md"), "clone aeaston1/cycle\n")

    assert [
             %{
               path: "WORKFLOW.md",
               reason: "contains private repo name",
               value: "aeaston1/cycle"
             }
           ] = Cycle.Security.scan_public_docs(root)
  end

  test "repository public docs and examples do not contain private repo names" do
    assert [] = Cycle.Security.scan_public_docs(File.cwd!())
  end

  test "archive scan detects known fake token values after extraction" do
    root = tmp_dir()
    stage = Path.join(root, "cycle-v0.1.0")
    archive = Path.join(root, "cycle-v0.1.0.tar.gz")

    File.mkdir_p!(Path.join(stage, "docs"))
    File.write!(Path.join(stage, "docs/leak.txt"), @fake_token)

    assert {"", 0} = System.cmd("tar", ["-czf", archive, "-C", root, "cycle-v0.1.0"])

    assert {:ok,
            [
              %{
                path: "cycle-v0.1.0/docs/leak.txt",
                reason: "contains forbidden value",
                value: @fake_token
              }
            ]} = Cycle.Security.scan_archive(archive, Cycle.Security.fake_secret_values())
  end

  defp tmp_dir do
    path =
      Path.join([
        System.tmp_dir!(),
        "cycle-security-test-#{System.unique_integer([:positive, :monotonic])}"
      ])

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
