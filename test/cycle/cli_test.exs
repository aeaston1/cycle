defmodule Cycle.CLITest do
  use ExUnit.Case, async: false

  import Plug.Conn
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
    assert output =~ "cycle policy drift"
    assert output =~ "cycle policy propagate"
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

  test "project discover writes registry and prints opted-in records with fake Linear" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      name = :"cli-discover-test-#{System.unique_integer([:positive])}"
      previous_key = System.get_env("LINEAR_API_KEY")
      previous_req_options = Application.get_env(:cycle, :linear_req_options)

      System.put_env("LINEAR_API_KEY", "lin_test")

      Application.put_env(
        :cycle,
        :linear_req_options,
        Cycle.TestSupport.linear_graphql_req_options(name)
      )

      on_exit(fn ->
        restore_env("LINEAR_API_KEY", previous_key)

        if previous_req_options do
          Application.put_env(:cycle, :linear_req_options, previous_req_options)
        else
          Application.delete_env(:cycle, :linear_req_options)
        end
      end)

      Req.Test.stub(name, fn conn ->
        {:ok, body, conn} = read_body(conn)
        assert Jason.decode!(body)["variables"]["first"] == 5

        Req.Test.json(conn, %{
          "data" => %{
            "projects" => %{
              "nodes" => [
                %{
                  "id" => "project-id",
                  "name" => "Cycle Project",
                  "slugId" => "CYCLE",
                  "url" => "https://linear.app/example/project/cycle",
                  "description" => """
                  cycle:
                    enabled: true
                    repo: https://github.com/OWNER/REPO.git
                  """,
                  "content" => nil
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        })
      end)

      checkout_root =
        Path.join(
          System.tmp_dir!(),
          "cycle-cli-discover-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(checkout_root, "OWNER/REPO"))

      File.write!(Path.join(checkout_root, "OWNER/REPO/WORKFLOW.md"), """
      ---
      agent:
        max_concurrent_agents: 1
      tracker:
        active_states:
          - Todo
        terminal_states:
          - Done
      ---
      # Workflow
      """)

      on_exit(fn -> File.rm_rf!(checkout_root) end)

      output =
        capture_io(fn ->
          File.cd!(checkout_root, fn ->
            assert Cycle.CLI.run(["project", "discover", "--limit", "5"]) == :ok
          end)
        end)

      assert output =~ "NAMESPACE\tNAME\tSLUG\tREPO\tWORKFLOW\tSTATUS\tLAST_ERROR"

      assert output =~
               "cycle\tCycle Project\tCYCLE\thttps://github.com/OWNER/REPO.git\tWORKFLOW.md\tvalid"

      assert output =~ "Wrote 1 project records"

      assert File.exists?(Path.join(cycle_home, "projects.yaml"))
    end)
  end

  test "status is accepted without a running Symphony service" do
    output =
      capture_io(fn ->
        assert Cycle.CLI.run(["status", "--state-url", "http://127.0.0.1:9"]) == :ok
      end)

    assert output =~ "Cycle status"
    assert output =~ "symphony:"
  end

  test "status summarizes persisted policy drift" do
    with_cycle_home(fn cycle_home ->
      registry_path = Path.join(cycle_home, "projects.yaml")

      assert :ok =
               Cycle.Registry.Store.write(registry_path, %{
                 "schema_version" => 1,
                 "projects" => [
                   project_record(%{
                     "status" => "drift",
                     "policy_drift" => %{
                       "status" => "drift",
                       "records" => [
                         %{
                           "path" => "review_judge.model",
                           "desired" => "gpt-5.5",
                           "observed" => "gpt-4.1",
                           "severity" => "info",
                           "propagation_available" => true
                         }
                       ]
                     }
                   })
                 ]
               })

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["status", "--state-url", "http://127.0.0.1:9"]) == :ok
        end)

      assert output =~ "policy drift: 1 records across 1 projects"
    end)
  end

  test "policy drift lists persisted drift records by project" do
    with_cycle_home(fn cycle_home ->
      registry_path = Path.join(cycle_home, "projects.yaml")

      assert :ok =
               Cycle.Registry.Store.write(registry_path, %{
                 "schema_version" => 1,
                 "projects" => [
                   project_record(%{
                     "namespace" => "owner-repo",
                     "status" => "drift",
                     "policy_drift" => %{
                       "status" => "drift",
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
                   })
                 ]
               })

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["policy", "drift"]) == :ok
        end)

      assert output =~ "PROJECT\tWORKFLOW\tPATH\tOBSERVED\tDESIRED\tSEVERITY\tPROPAGATION"

      assert output =~
               "owner-repo\tWORKFLOW.md\treview_judge.policy\tmissing\tstandard\tinfo\tavailable"
    end)
  end

  test "policy propagate dry-run prints a patch and does not mutate workflow" do
    with_cycle_home(fn cycle_home ->
      workflow_path =
        write_policy_workflow!("""
        ---
        name: example
        review_judge:
          enabled: true
        ---
        # Workflow
        """)

      write_drift_registry!(cycle_home, workflow_path, [
        %{
          "path" => "review_judge.policy",
          "desired" => "standard",
          "observed" => nil,
          "severity" => "info",
          "propagation_available" => true
        }
      ])

      original = File.read!(workflow_path)

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["policy", "propagate", "--project", "cycle", "--dry-run"]) == :ok
        end)

      assert output =~ "--- a/WORKFLOW.md"
      assert output =~ "+  policy: standard"
      assert File.read!(workflow_path) == original
    end)
  end

  test "policy propagate dry-run patches capacity drift" do
    with_cycle_home(fn cycle_home ->
      workflow_path =
        write_policy_workflow!("""
        ---
        name: example
        agent:
          max_turns: 8
        ---
        # Workflow
        """)

      write_drift_registry!(cycle_home, workflow_path, [
        %{
          "path" => "agent.max_concurrent_agents",
          "desired" => 2,
          "observed" => nil,
          "severity" => "blocking",
          "propagation_available" => true
        }
      ])

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["policy", "propagate", "--project", "cycle", "--dry-run"]) == :ok
        end)

      assert output =~ "+  max_concurrent_agents: 2"
    end)
  end

  test "policy propagate apply refuses dirty git worktrees unless allowed" do
    with_cycle_home(fn cycle_home ->
      repo =
        Path.join(System.tmp_dir!(), "cycle-policy-repo-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(repo)
        git!(repo, ["init", "-b", "main"])
        git!(repo, ["config", "user.email", "cycle-test@example.invalid"])
        git!(repo, ["config", "user.name", "Cycle Test"])

        workflow_path = Path.join(repo, "WORKFLOW.md")

        File.write!(workflow_path, """
        ---
        name: example
        review_judge:
          enabled: true
        ---
        # Workflow
        """)

        git!(repo, ["add", "WORKFLOW.md"])
        git!(repo, ["commit", "-m", "workflow"])
        File.write!(Path.join(repo, "dirty.txt"), "dirty\n")

        write_drift_registry!(cycle_home, workflow_path, [
          %{
            "path" => "review_judge.policy",
            "desired" => "standard",
            "observed" => nil,
            "severity" => "info",
            "propagation_available" => true
          }
        ])

        assert Cycle.CLI.run(["policy", "propagate", "--project", "cycle", "--apply"]) ==
                 {:error, "refusing to apply policy propagation in dirty worktree", 1}
      after
        File.rm_rf(repo)
      end
    end)
  end

  test "start validates required workflow option" do
    assert Cycle.CLI.run(["start"]) == {:error, "cycle start requires --workflow PATH", 1}
  end

  test "start dry-run renders exact managed engine command without executing it" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      install_path = fake_installed_engine(cycle_home)
      workflow = Path.join(install_path, "elixir/WORKFLOW.md")

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["start", "--workflow", workflow, "--port", "4765", "--dry-run"]) ==
                   :ok
        end)

      assert String.trim(output) ==
               Enum.join(
                 [Path.join(install_path, "elixir/bin/symphony"), "--port", "4765", workflow],
                 " "
               )
    end)
  end

  test "start dry-run includes no-guardrails flag only with operator-approved config" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{
                                                        cycle_home: cycle_home,
                                                        config_home: config_home
                                                      } ->
      install_path = fake_installed_engine(cycle_home)
      workflow = Path.join(install_path, "elixir/WORKFLOW.md")
      config_dir = Path.join(config_home, "cycle")
      File.mkdir_p!(config_dir)

      File.write!(
        Path.join(config_dir, "config.yaml"),
        """
        engines:
          managed:
            openai-symphony:
              foreground_unattended: true
        """
      )

      output =
        capture_io(fn ->
          assert Cycle.CLI.run(["start", "--workflow", workflow, "--dry-run"]) == :ok
        end)

      assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
    end)
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
    File.write!(Path.join(root, "README.md"), "# Symphony fixture\n")

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

  defp project_record(overrides) do
    Map.merge(
      %{
        "linear_project" => %{
          "id" => "project-id",
          "name" => "Project",
          "slug" => "project",
          "url" => "https://linear.app/example/project/project-id"
        },
        "namespace" => "cycle",
        "repo" => %{"url" => "https://github.com/OWNER/REPO.git", "full_name" => "OWNER/REPO"},
        "workflow" => %{"path" => "WORKFLOW.md", "resolved_path" => "/tmp/cycle/WORKFLOW.md"},
        "allowed_engines" => ["openai-symphony@main"],
        "policy_profile" => "default",
        "capacity" => %{},
        "last_discovery_at" => "2026-05-22T12:00:00Z",
        "status" => "valid",
        "error" => nil,
        "policy_drift" => %{"status" => "valid", "records" => []}
      },
      overrides
    )
  end

  defp write_policy_workflow!(content) do
    root =
      Path.join(System.tmp_dir!(), "cycle-policy-workflow-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "WORKFLOW.md")
    File.write!(path, content)
    path
  end

  defp write_drift_registry!(cycle_home, workflow_path, drift_records) do
    Cycle.Registry.Store.write(Path.join(cycle_home, "projects.yaml"), %{
      "schema_version" => 1,
      "projects" => [
        project_record(%{
          "status" => "drift",
          "workflow" => %{
            "path" => "WORKFLOW.md",
            "resolved_path" => workflow_path
          },
          "policy_drift" => %{"status" => "drift", "records" => drift_records}
        })
      ]
    })
  end

  defp fake_installed_engine(cycle_home) do
    install_path = Path.join([cycle_home, "engines", "openai-symphony", "main"])
    File.mkdir_p!(Path.join(install_path, "elixir/bin"))
    File.write!(Path.join(install_path, "elixir/WORKFLOW.md"), "# Workflow\n")
    bin = Path.join(install_path, "elixir/bin/symphony")
    File.write!(bin, "#!/bin/sh\nexit 0\n")
    File.chmod!(bin, 0o755)
    install_path
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
