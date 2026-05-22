defmodule Cycle.CLITest do
  use ExUnit.Case, async: false

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

  test "linear configure writes config.yaml as the primary config file" do
    config_parent =
      Path.join(System.tmp_dir!(), "cycle-cli-test-#{System.unique_integer([:positive])}")

    previous_config_home = System.get_env("XDG_CONFIG_HOME")
    previous_linear_key = System.get_env("LINEAR_API_KEY")

    System.put_env("XDG_CONFIG_HOME", config_parent)
    System.put_env("LINEAR_API_KEY", "test-token")

    on_exit(fn ->
      restore_env("XDG_CONFIG_HOME", previous_config_home)
      restore_env("LINEAR_API_KEY", previous_linear_key)
      File.rm_rf(config_parent)
    end)

    output =
      capture_io(fn ->
        assert Cycle.CLI.run(["linear", "configure", "--from-env"]) == :ok
      end)

    config_file = Path.join([config_parent, "cycle", "config.yaml"])

    assert output =~ "Saved Linear configuration to #{config_file}"
    assert File.read!(config_file) == "linear:\n  api_key_env: LINEAR_API_KEY\n"
    refute File.exists?(Path.join([config_parent, "cycle", "config.env"]))
  end

  test "symphony path prints the managed engine path" do
    with_cycle_home(fn cycle_home ->
      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["symphony", "path", "--version", "test-ref"]) == :ok
        end)

      assert String.trim(output) ==
               Path.join([cycle_home, "engines", "openai-symphony", "test-ref"])
    end)
  end

  test "symphony path prefers registry install path" do
    with_cycle_home(fn cycle_home ->
      registry_path = Path.join(cycle_home, "engines.yaml")
      install_path = Path.join(cycle_home, "custom-engines/openai-symphony/main")

      File.mkdir_p!(cycle_home)

      :ok =
        Cycle.EngineRegistry.write(registry_path, %Cycle.EngineRegistry{
          engines: [
            %Cycle.EngineRegistry.Engine{
              id: "openai-symphony@main",
              name: "openai-symphony",
              source: "https://github.com/OWNER/REPO.git",
              ref: "main",
              install_path: install_path,
              health: %{"state" => "missing"}
            }
          ]
        })

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["symphony", "path"]) == :ok
        end)

      assert String.trim(output) == install_path
    end)
  end

  test "symphony install clones a configured repo and writes the lock" do
    with_cycle_home(fn cycle_home ->
      source = symphony_fixture_repo()

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["symphony", "install", "--repo", source, "--version", "main"]) ==
                   :ok
        end)

      install_path = Path.join([cycle_home, "engines", "openai-symphony", "main"])
      lock_path = Path.join(cycle_home, "engines.lock.yaml")

      assert output =~ "Cloning Symphony from #{source}"
      assert output =~ "Symphony installed at: #{install_path}"
      assert File.exists?(Path.join(install_path, "elixir/WORKFLOW.md"))
      assert File.exists?(Path.join(install_path, "elixir/bin/symphony"))

      assert {:ok, lock_registry} = Cycle.EngineRegistry.read_lock(lock_path)

      assert lock =
               Cycle.EngineRegistry.lock_for(lock_registry, %{
                 name: "openai-symphony",
                 ref: "main"
               })

      assert lock.resolved_revision == git!(source, ["rev-parse", "HEAD"])
    end)
  end

  test "symphony install updates an existing checkout safely" do
    with_cycle_home(fn cycle_home ->
      source = symphony_fixture_repo()

      capture_io(fn ->
        assert Cycle.CLI.run(["symphony", "install", "--repo", source, "--version", "main"]) ==
                 :ok
      end)

      first_revision = git!(source, ["rev-parse", "HEAD"])
      File.write!(Path.join(source, "elixir/WORKFLOW.md"), "# Workflow\n\nupdated\n")
      git!(source, ["add", "elixir/WORKFLOW.md"])
      git!(source, ["commit", "-m", "update workflow"])
      second_revision = git!(source, ["rev-parse", "HEAD"])

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["symphony", "install", "--repo", source, "--version", "main"]) ==
                   :ok
        end)

      install_path = Path.join([cycle_home, "engines", "openai-symphony", "main"])
      assert output =~ "Updating with git fetch, checkout, and fast-forward pull"
      refute first_revision == second_revision
      assert git!(install_path, ["rev-parse", "HEAD"]) == second_revision

      assert {:ok, lock_registry} =
               Cycle.EngineRegistry.read_lock(Path.join(cycle_home, "engines.lock.yaml"))

      assert lock =
               Cycle.EngineRegistry.lock_for(lock_registry, %{
                 name: "openai-symphony",
                 ref: "main"
               })

      assert lock.resolved_revision == second_revision
    end)
  end

  test "symphony install rejects an existing non-git target" do
    with_cycle_home(fn cycle_home ->
      target = Path.join([cycle_home, "engines", "openai-symphony", "main"])
      File.mkdir_p!(target)
      File.write!(Path.join(target, "README.md"), "not a checkout")

      assert Cycle.CLI.run([
               "symphony",
               "install",
               "--repo",
               symphony_fixture_repo(),
               "--version",
               "main"
             ]) == {:error, "target exists but is not a git checkout: #{target}", 3}
    end)
  end

  test "symphony install reports missing expected Symphony paths" do
    with_cycle_home(fn _cycle_home ->
      source = symphony_fixture_repo(include_bin: false)

      capture_io(fn ->
        assert {:error, message, 3} =
                 Cycle.CLI.run(["symphony", "install", "--repo", source, "--version", "main"])

        assert message =~ "installed Symphony checkout did not contain"
        assert message =~ "elixir/bin/symphony"
      end)
    end)
  end

  test "symphony install reports missing expected workflow path" do
    with_cycle_home(fn _cycle_home ->
      source = symphony_fixture_repo(include_workflow: false)

      capture_io(fn ->
        assert {:error, message, 3} =
                 Cycle.CLI.run(["symphony", "install", "--repo", source, "--version", "main"])

        assert message =~ "installed Symphony checkout did not contain"
        assert message =~ "elixir/WORKFLOW.md"
      end)
    end)
  end

  test "symphony install redacts credentials from output and registry state" do
    with_cycle_home(fn cycle_home ->
      repo = "https://secret-token@example.invalid/OWNER/REPO.git"

      output =
        capture_io(fn ->
          assert {:error, message, 2} =
                   Cycle.CLI.run(["symphony", "install", "--repo", repo, "--version", "main"])

          refute message =~ "secret-token"
        end)

      refute output =~ "secret-token"
      assert output =~ "Cloning Symphony from https://[REDACTED]@example.invalid/OWNER/REPO.git"

      registry_path = Path.join(cycle_home, "engines.yaml")
      refute File.exists?(registry_path)
    end)
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

  test "service install placeholder remains explicit and service status reports safely" do
    install_output = capture_io(fn -> assert Cycle.CLI.run(["service", "install"]) == :ok end)
    status_output = capture_io(fn -> assert Cycle.CLI.run(["service", "status"]) == :ok end)

    assert install_output =~ "Service installation is not implemented yet."
    assert status_output =~ "Cycle service status"
    assert status_output =~ "installed:"
    assert status_output =~ "state:"
    assert status_output =~ "logs:"
  end

  test "service status supports json output" do
    output = capture_io(fn -> assert Cycle.CLI.run(["service", "status", "--json"]) == :ok end)
    payload = Jason.decode!(output)

    assert Map.has_key?(payload, "service")
    assert Map.has_key?(payload, "config_path")
    assert Map.has_key?(payload, "state_path")
    assert Map.has_key?(payload, "api_health")
  end

  test "unknown commands return a user error" do
    assert Cycle.CLI.run(["wat"]) == {:error, "unknown command: wat", 1}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp with_cycle_home(fun) do
    cycle_home =
      Path.join(System.tmp_dir!(), "cycle-cli-home-#{System.unique_integer([:positive])}")

    previous_cycle_home = System.get_env("CYCLE_HOME")

    System.put_env("CYCLE_HOME", cycle_home)

    try do
      fun.(cycle_home)
    after
      restore_env("CYCLE_HOME", previous_cycle_home)
      File.rm_rf(cycle_home)
    end
  end

  defp symphony_fixture_repo(opts \\ []) do
    root =
      Path.join(System.tmp_dir!(), "cycle-symphony-fixture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "elixir/bin"))

    if Keyword.get(opts, :include_workflow, true) do
      File.write!(Path.join(root, "elixir/WORKFLOW.md"), "# Workflow\n")
    end

    if Keyword.get(opts, :include_bin, true) do
      bin = Path.join(root, "elixir/bin/symphony")
      File.write!(bin, "#!/bin/sh\n")
      File.chmod!(bin, 0o755)
    end

    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.email", "cycle-test@example.invalid"])
    git!(root, ["config", "user.name", "Cycle Test"])
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "fixture"])

    root
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
