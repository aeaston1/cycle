defmodule Cycle.Engine.SymphonyTest do
  use ExUnit.Case, async: true

  alias Cycle.Engine.Symphony
  alias Cycle.EngineRegistry

  test "capabilities are machine-readable and dispatch is disabled by default" do
    caps = Symphony.capabilities(engine("/tmp/missing"))

    assert caps["adapter"] == "symphony"
    assert caps["adapter_contract"] == "cycle.engine.adapter.v1"
    assert caps["run_mode"] == "foreground_process"
    assert caps["process_supervision"] == true
    assert caps["dispatch"]["single_issue"] == false
  end

  test "dry-run command omits no-guardrails flag until operator config allows it" do
    with_engine(fn path ->
      workflow = Path.join(path, "elixir/WORKFLOW.md")
      engine = engine(path)

      assert {:ok, command} =
               Symphony.start_foreground(engine, workflow: workflow, port: "4567", dry_run: true)

      refute "--i-understand-that-this-will-be-running-without-the-usual-guardrails" in command
      assert command == [Path.join(path, "elixir/bin/symphony"), "--port", "4567", workflow]

      assert {:ok, approved_command} =
               Symphony.start_foreground(engine,
                 workflow: workflow,
                 port: "4567",
                 dry_run: true,
                 allow_foreground_unattended: true
               )

      assert approved_command == [
               Path.join(path, "elixir/bin/symphony"),
               "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
               "--port",
               "4567",
               workflow
             ]
    end)
  end

  test "missing engine executable returns structured error" do
    path =
      Path.join(System.tmp_dir!(), "cycle-symphony-missing-#{System.unique_integer([:positive])}")

    workflow = Path.join(path, "WORKFLOW.md")
    File.mkdir_p!(path)
    File.write!(workflow, "# Workflow\n")

    try do
      assert {:error, %{"code" => "engine_executable_missing", "message" => message}} =
               Symphony.start_foreground(engine(path), workflow: workflow)

      assert message =~ "run cycle symphony install first"
    after
      File.rm_rf!(path)
    end
  end

  test "foreground start executes exact command with explicit environment only" do
    with_engine(fn path ->
      workflow = Path.join(path, "elixir/WORKFLOW.md")
      parent = self()

      assert :ok =
               Symphony.start_foreground(engine(path),
                 workflow: workflow,
                 port: 4765,
                 env: %{"LINEAR_API_KEY" => "secret"},
                 command_runner: fn executable, args, opts ->
                   send(parent, {:cmd, executable, args, opts})
                   {"", 0}
                 end
               )

      assert_received {:cmd, executable, args, opts}
      assert executable == Path.join(path, "elixir/bin/symphony")
      assert args == ["--port", "4765", workflow]
      assert Keyword.fetch!(opts, :env) == [{"LINEAR_API_KEY", "secret"}]
    end)
  end

  test "dispatch unsupported is not success" do
    assert {:error, %{"code" => "engine_dispatch_unsupported", "message" => message}} =
             Symphony.dispatch(engine("/tmp/missing"), %{"run_id" => "run-1"})

    assert message =~ "does not support single-issue dispatch"
  end

  test "status endpoint is polled only when advertised" do
    parent = self()

    assert {:ok, %{"state" => "unsupported"}} =
             Symphony.status(engine("/tmp/missing"),
               status_get: fn _url, _opts ->
                 send(parent, :unexpected)
                 {:ok, %{status: 200, body: %{}}}
               end
             )

    refute_received :unexpected

    engine =
      engine("/tmp/missing", %{
        "status_api" => true,
        "status_url" => "http://127.0.0.1:4765/health"
      })

    assert {:ok, %{"state" => "reachable", "body" => %{"ok" => true}}} =
             Symphony.status(engine,
               status_get: fn "http://127.0.0.1:4765/health", _opts ->
                 {:ok, %{status: 200, body: %{"ok" => true}}}
               end
             )
  end

  defp engine(path, capabilities \\ %{}) do
    %EngineRegistry.Engine{
      id: "openai-symphony@main",
      name: "openai-symphony",
      source: "https://github.com/OWNER/REPO.git",
      ref: "main",
      install_path: path,
      capabilities: capabilities,
      health: %{"state" => "unknown"}
    }
  end

  defp with_engine(fun) do
    path =
      Path.join(System.tmp_dir!(), "cycle-symphony-test-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(Path.join(path, "elixir/bin"))
      File.write!(Path.join(path, "elixir/WORKFLOW.md"), "# Workflow\n")
      bin = Path.join(path, "elixir/bin/symphony")
      File.write!(bin, "#!/bin/sh\n")
      File.chmod!(bin, 0o755)
      fun.(path)
    after
      File.rm_rf!(path)
    end
  end
end
