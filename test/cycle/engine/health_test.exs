defmodule Cycle.Engine.HealthTest do
  use ExUnit.Case, async: true

  alias Cycle.Engine.Health
  alias Cycle.EngineRegistry

  test "missing install path reports missing" do
    engine = engine("/tmp/cycle-health-missing-#{System.unique_integer([:positive])}")

    assert %{
             "state" => "missing",
             "checked_at" => "2026-05-22T12:00:00Z",
             "reason" => "install path is missing"
           } = Health.check(engine, checked_at: "2026-05-22T12:00:00Z")
  end

  test "missing executable reports invalid" do
    with_engine_checkout(fn path ->
      health = Health.check(engine(path), checked_at: "2026-05-22T12:00:00Z")

      assert health["state"] == "invalid"
      assert health["reason"] == "expected executable is missing"
      assert health["executable"] == Path.join(path, "elixir/bin/symphony")
    end)
  end

  test "fake executable success reports healthy with revision and checked_at" do
    with_engine_checkout(
      fn path ->
        health =
          Health.check(engine(path),
            checked_at: "2026-05-22T12:00:00Z",
            command_finder: fn "git" -> "/usr/bin/git" end,
            command_runner: &git_only_runner/3
          )

        assert health["state"] == "healthy"
        assert health["checked_at"] == "2026-05-22T12:00:00Z"
        assert health["revision"] == git!(path, ["rev-parse", "HEAD"])
      end,
      include_bin: true
    )
  end

  test "runtime command failure reports unhealthy with reason" do
    with_engine_checkout(
      fn path ->
        health =
          Health.check(engine(path),
            command_finder: fn "git" -> "/usr/bin/git" end,
            command_runner: fn
              "git", ["-C", ^path, "rev-parse", "HEAD"], opts ->
                System.cmd("git", ["-C", path, "rev-parse", "HEAD"], opts)

              "git", ["--version"], _opts ->
                {"git failed", 42}
            end
          )

        assert health["state"] == "unhealthy"
        assert health["reason"] == "runtime command git failed with status 42: git failed"
      end,
      include_bin: true
    )
  end

  test "status API check is attempted only when capability advertises it" do
    with_engine_checkout(
      fn path ->
        parent = self()

        without_api =
          Health.check(engine(path),
            command_finder: fn "git" -> "/usr/bin/git" end,
            command_runner: &git_only_runner/3,
            status_get: fn _url, _opts ->
              send(parent, :unexpected_status_api)
              {:ok, %{status: 200}}
            end
          )

        refute_received :unexpected_status_api
        assert without_api["state"] == "healthy"

        with_api =
          Health.check(
            engine(path, %{"status_api" => true, "status_url" => "http://127.0.0.1:4765/health"}),
            command_finder: fn "git" -> "/usr/bin/git" end,
            command_runner: &git_only_runner/3,
            status_get: fn "http://127.0.0.1:4765/health", _opts -> {:ok, %{status: 204}} end
          )

        assert with_api["state"] == "healthy"

        failed_api =
          Health.check(
            engine(path, %{"status_api" => true, "status_url" => "http://127.0.0.1:4765/health"}),
            command_finder: fn "git" -> "/usr/bin/git" end,
            command_runner: &git_only_runner/3,
            status_get: fn "http://127.0.0.1:4765/health", _opts -> {:ok, %{status: 503}} end
          )

        assert failed_api["state"] == "unhealthy"
        assert failed_api["reason"] == "status API returned 503"
      end,
      include_bin: true
    )
  end

  defp engine(path, overrides \\ %{}) do
    %EngineRegistry.Engine{
      id: "openai-symphony@main",
      name: "openai-symphony",
      source: "https://github.com/OWNER/REPO.git",
      ref: "main",
      install_path: path,
      capabilities:
        Map.merge(
          %{
            "adapter" => "symphony",
            "workflow_schema" => "symphony.v1",
            "status_api" => false,
            "runtime_commands" => ["git"],
            "policy" => %{"approval_policy" => true, "sandbox" => true}
          },
          overrides
        ),
      health: %{"state" => "unknown"}
    }
  end

  defp with_engine_checkout(fun, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "cycle-health-test-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(Path.join(path, "elixir/bin"))
      File.write!(Path.join(path, "elixir/WORKFLOW.md"), "# Workflow\n")

      if Keyword.get(opts, :include_bin, false) do
        bin = Path.join(path, "elixir/bin/symphony")
        File.write!(bin, "#!/bin/sh\n")
        File.chmod!(bin, 0o755)
      end

      git!(path, ["init", "-b", "main"])
      git!(path, ["config", "user.email", "cycle-test@example.invalid"])
      git!(path, ["config", "user.name", "Cycle Test"])
      git!(path, ["add", "."])
      git!(path, ["commit", "-m", "fixture"])

      fun.(path)
    after
      File.rm_rf(path)
    end
  end

  defp git_only_runner("git", ["--version"], opts), do: System.cmd("git", ["--version"], opts)

  defp git_only_runner("git", ["-C", path, "rev-parse", "HEAD"], opts),
    do: System.cmd("git", ["-C", path, "rev-parse", "HEAD"], opts)

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
