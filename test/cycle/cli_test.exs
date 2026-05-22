defmodule Cycle.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints the version" do
    assert capture_io(fn -> assert Cycle.CLI.run(["--version"]) == :ok end) == "cycle 0.1.0-dev\n"
  end

  test "prints help with documented commands" do
    output = capture_io(fn -> assert Cycle.CLI.run(["help"]) == :ok end)

    assert output =~ "Cycle manages OpenAI Symphony engines"
    assert output =~ "cycle --version"
    assert output =~ "cycle doctor"
    assert output =~ "cycle linear configure"
    assert output =~ "cycle symphony install"
    assert output =~ "cycle symphony path"
    assert output =~ "cycle project opt-in"
    assert output =~ "cycle project discover"
    assert output =~ "cycle start"
    assert output =~ "cycle status"
    assert output =~ "cycle service install"
    assert output =~ "cycle service status"
  end

  test "doctor is an accepted command" do
    output = capture_io(fn -> assert Cycle.CLI.run(["doctor"]) == :ok end)

    assert output =~ "Cycle doctor"
    assert output =~ "config:"
    assert output =~ "state:"
  end

  test "linear configure print reports configuration without leaking tokens" do
    output =
      capture_io(fn ->
        assert Cycle.CLI.run(["linear", "configure", "--print"]) == :ok
      end)

    assert output =~ "config file:"
    refute output =~ System.get_env("LINEAR_API_KEY", "not-a-real-token")
  end

  test "symphony path prints the managed engine path" do
    output =
      capture_io(fn ->
        assert Cycle.CLI.run(["symphony", "path", "--version", "test-ref"]) == :ok
      end)

    assert output =~ "/engines/openai-symphony/test-ref"
  end

  test "project opt-in prints cycle metadata" do
    output =
      capture_io(fn ->
        assert Cycle.CLI.run(["project", "opt-in", "--repo", "https://github.com/OWNER/REPO.git"]) ==
                 :ok
      end)

    assert output =~ "cycle:"
    assert output =~ "enabled: true"
    assert output =~ "repo: https://github.com/OWNER/REPO.git"
  end

  test "project discover validates parser options before external calls" do
    assert Cycle.CLI.run(["project", "discover", "--limit", "not-a-number"]) ==
             {:error, "--limit must be a positive integer", 1}
  end

  test "status is accepted without a running Symphony service" do
    output =
      capture_io(fn ->
        assert Cycle.CLI.run(["status", "--state-url", "http://127.0.0.1:9"]) == :ok
      end)

    assert output =~ "Cycle status"
    assert output =~ "symphony:"
  end

  test "start validates required workflow option" do
    assert Cycle.CLI.run(["start"]) == {:error, "cycle start requires --workflow PATH", 1}
  end

  test "service placeholders remain explicit" do
    install_output = capture_io(fn -> assert Cycle.CLI.run(["service", "install"]) == :ok end)
    status_output = capture_io(fn -> assert Cycle.CLI.run(["service", "status"]) == :ok end)

    assert install_output =~ "Service installation is not implemented yet."
    assert status_output =~ "Service status is not implemented yet."
  end

  test "unknown commands return a user error" do
    assert Cycle.CLI.run(["wat"]) == {:error, "unknown command: wat", 1}
  end
end
