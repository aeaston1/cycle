defmodule Cycle.ConfigTest do
  use ExUnit.Case, async: false

  alias Cycle.Config

  @home "/tmp/cycle-config-test-home"

  test "missing config file falls back to safe defaults" do
    assert {:ok, config} = Config.load(env: %{}, home: @home)

    assert config.paths.config_file == "/tmp/cycle-config-test-home/.config/cycle/config.yaml"
    assert config.paths.state_dir == "/tmp/cycle-config-test-home/.local/share/cycle"

    assert config.projects["registry_path"] ==
             "/tmp/cycle-config-test-home/.local/share/cycle/projects.yaml"

    assert get_in(config.engines, ["managed", "openai-symphony", "repo"]) ==
             "https://github.com/openai/symphony.git"
  end

  test "review automation and future fix provider defaults are disabled" do
    assert {:ok, config} = Config.load(env: %{}, home: @home)
    external = get_in(config.review_judge, ["external_review"])

    assert config.review_judge["enabled"] == false
    assert config.review_judge["source_state"] == "Human Review"
    assert config.review_judge["review_state"] == "Human Review"
    assert config.review_judge["proceed_state"] == "Merging"
    assert "Rework" in config.linear["active_states"]

    assert external["enabled"] == false
    assert external["provider"] == "clawpatch"
    assert external["execution"] == "local_workspace"
    assert external["trigger"] == "after_tentative_proceed"
    assert external["failure_decision"] == "require_human_review"
    assert external["command"] == "clawpatch"
    assert external["args"] == ["review", "--json", "--since", "origin/main"]

    assert external["artifact_dir"] ==
             "/tmp/cycle-config-test-home/.local/share/cycle/review-jobs"

    assert external["route_findings_to_rework"] == true
    assert external["rework_state"] == "Rework"
    assert get_in(external, ["fix", "enabled"]) == false
  end

  test "valid config YAML loads into typed structs and maps" do
    with_temp_config(
      """
      polling:
        interval_ms: 1000
      projects:
        registry_path: ${CYCLE_HOME}/custom-projects.yaml
      engines:
        managed:
          openai-symphony:
            repo: https://github.com/OWNER/REPO.git
            default_ref: release
      """,
      fn config_path ->
        env = %{"CYCLE_HOME" => "/tmp/cycle-state"}

        assert {:ok, config} = Config.load(env: env, home: @home, config_path: config_path)
        assert %Cycle.Config.Paths{} = config.paths
        assert config.polling["interval_ms"] == 1000
        assert config.projects["registry_path"] == "/tmp/cycle-state/custom-projects.yaml"
        assert get_in(config.engines, ["managed", "openai-symphony", "default_ref"]) == "release"
      end
    )
  end

  test "external review environment overrides implemented local provider settings" do
    env = %{
      "CYCLE_HOME" => "/tmp/cycle-state",
      "CYCLE_REVIEW_EXTERNAL_ENABLED" => "true",
      "CYCLE_CLAWPATCH_COMMAND" => "clawpatch-test",
      "CYCLE_CLAWPATCH_ARGS" => "review --json --dry-run",
      "CYCLE_REVIEW_EXTERNAL_ARTIFACT_DIR" => "/tmp/cycle-state/external-review",
      "CYCLE_CLAWPATCH_CONFIG_PATH" => "/tmp/cycle-state/clawpatch.json",
      "CYCLE_CRABBOX_CONFIG_PATH" => "/tmp/cycle-state/crabbox.toml"
    }

    assert {:ok, config} = Config.load(env: env, home: @home)
    external = get_in(config.review_judge, ["external_review"])

    assert external["enabled"] == true
    assert external["command"] == "clawpatch-test"
    assert external["args"] == ["review", "--json", "--dry-run"]
    assert external["artifact_dir"] == "/tmp/cycle-state/external-review"
    assert external["clawpatch_config_path"] == "/tmp/cycle-state/clawpatch.json"
    assert external["crabbox_config_path"] == "/tmp/cycle-state/crabbox.toml"
  end

  test "external review args environment preserves quoted arguments" do
    env = %{
      "CYCLE_HOME" => "/tmp/cycle-state",
      "CYCLE_CLAWPATCH_ARGS" =>
        ~s(review --config "/tmp/path with spaces/config.json" --flag\\ value)
    }

    assert {:ok, config} = Config.load(env: env, home: @home)

    assert get_in(config.review_judge, ["external_review", "args"]) == [
             "review",
             "--config",
             "/tmp/path with spaces/config.json",
             "--flag value"
           ]
  end

  test "external review args environment accepts JSON arrays and rejects malformed argv" do
    assert {:ok, config} =
             Config.load(
               env: %{
                 "CYCLE_HOME" => "/tmp/cycle-state",
                 "CYCLE_CLAWPATCH_ARGS" => ~s(["review","--json","--prompt","two words"])
               },
               home: @home
             )

    assert get_in(config.review_judge, ["external_review", "args"]) == [
             "review",
             "--json",
             "--prompt",
             "two words"
           ]

    assert {:error, errors} =
             Config.load(
               env: %{
                 "CYCLE_HOME" => "/tmp/cycle-state",
                 "CYCLE_CLAWPATCH_ARGS" => ~s(review "unterminated)
               },
               home: @home
             )

    assert %{path: "review_judge.external_review.args", reason: "must be a non-empty list"} in errors
  end

  test "external review validation rejects unsupported providers and enabled fix" do
    with_temp_config(
      """
      review_judge:
        external_review:
          provider: other-reviewer
          artifact_dir: ${CYCLE_HOME}/review-jobs
          fix:
            enabled: true
      """,
      fn config_path ->
        assert {:error, errors} =
                 Config.load(
                   env: %{"CYCLE_HOME" => "/tmp/cycle-state"},
                   home: @home,
                   config_path: config_path
                 )

        assert %{
                 path: "review_judge.external_review.provider",
                 reason: "must be one of: clawpatch"
               } in errors

        assert %{
                 path: "review_judge.external_review.fix.enabled",
                 reason:
                   "clawpatch fix execution is a Rework-lane follow-up and is not implemented in this release"
               } in errors
      end
    )
  end

  test "environment overrides config file values" do
    with_temp_config(
      """
      service:
        status_url: http://from-config.example/state
      engines:
        managed:
          openai-symphony:
            repo: https://github.com/OWNER/CONFIG.git
            default_ref: config-ref
      """,
      fn config_path ->
        env = %{
          "CYCLE_STATUS_URL" => "http://127.0.0.1:9999/state",
          "CYCLE_SYMPHONY_REPO" => "https://github.com/OWNER/ENV.git",
          "CYCLE_SYMPHONY_REF" => "env-ref"
        }

        assert {:ok, config} = Config.load(env: env, home: @home, config_path: config_path)
        assert config.service["status_url"] == "http://127.0.0.1:9999/state"

        assert get_in(config.engines, ["managed", "openai-symphony", "repo"]) ==
                 "https://github.com/OWNER/ENV.git"

        assert get_in(config.engines, ["managed", "openai-symphony", "default_ref"]) == "env-ref"
      end
    )
  end

  test "CLI overrides environment" do
    env = %{"CYCLE_STATUS_URL" => "http://env.example/state"}
    cli = %{"service" => %{"status_url" => "http://cli.example/state"}}

    assert {:ok, config} = Config.load(env: env, home: @home, cli: cli)
    assert config.service["status_url"] == "http://cli.example/state"
  end

  test "repo workflow defaults are lower precedence than config file" do
    workflow = %{"polling" => %{"interval_ms" => 5000}}

    with_temp_config("polling:\n  interval_ms: 1500\n", fn config_path ->
      assert {:ok, config} =
               Config.load(env: %{}, home: @home, workflow: workflow, config_path: config_path)

      assert config.polling["interval_ms"] == 1500
    end)
  end

  test "invalid YAML returns a structured error" do
    with_temp_config("polling: [", fn config_path ->
      assert {:error, [%{path: "config", reason: reason}]} =
               Config.load(env: %{}, home: @home, config_path: config_path)

      assert reason =~ "invalid YAML"
    end)
  end

  test "invalid values return structured path and reason" do
    with_temp_config(
      """
      polling:
        interval_ms: nope
      engines:
        managed:
          openai-symphony:
            repo: not-a-url
      """,
      fn config_path ->
        assert {:error, errors} = Config.load(env: %{}, home: @home, config_path: config_path)
        assert %{path: "polling.interval_ms", reason: "must be a positive integer"} in errors

        assert %{
                 path: "engines.managed.openai-symphony.repo",
                 reason: "must be a git repository URL or absolute path"
               } in errors
      end
    )
  end

  test "engine repository config rejects credentials" do
    with_temp_config(
      """
      engines:
        managed:
          openai-symphony:
            repo: https://token@github.com/OWNER/REPO.git
      """,
      fn config_path ->
        assert {:error, errors} = Config.load(env: %{}, home: @home, config_path: config_path)

        assert %{
                 path: "engines.managed.openai-symphony.repo",
                 reason: "must not contain credentials"
               } in errors
      end
    )
  end

  test "cycle-owned registry cache engine and log paths must stay under state dir" do
    with_temp_config(
      """
      paths:
        state_dir: /tmp/cycle-owned-state
        logs_dir: /tmp/not-cycle/logs
        engines_dir: /tmp/not-cycle/engines-path
      projects:
        registry_path: /tmp/not-cycle/projects.yaml
        workflow_cache_path: /tmp/not-cycle/workflow-cache
      engines:
        registry_path: /tmp/not-cycle/engines.yaml
        lock_path: /tmp/not-cycle/engines.lock.yaml
        install_root: /tmp/not-cycle/engines
      service:
        logs:
          path: /tmp/not-cycle/logs/cycle.log
      """,
      fn config_path ->
        assert {:error, errors} =
                 Config.load(
                   env: %{},
                   home: @home,
                   config_path: config_path
                 )

        assert %{path: "paths.logs_dir", reason: "must be under paths.state_dir"} in errors
        assert %{path: "paths.engines_dir", reason: "must be under paths.state_dir"} in errors

        assert %{path: "projects.registry_path", reason: "must be under paths.state_dir"} in errors

        assert %{
                 path: "projects.workflow_cache_path",
                 reason: "must be under paths.state_dir"
               } in errors

        assert %{path: "engines.registry_path", reason: "must be under paths.state_dir"} in errors
        assert %{path: "engines.lock_path", reason: "must be under paths.state_dir"} in errors
        assert %{path: "engines.install_root", reason: "must be under paths.state_dir"} in errors
        assert %{path: "service.logs.path", reason: "must be under paths.state_dir"} in errors
      end
    )
  end

  test "relative state file overrides are rejected before normalization" do
    with_temp_config(
      """
      projects:
        registry_path: projects.yaml
      """,
      fn config_path ->
        assert {:error, errors} =
                 Config.load(
                   env: %{"CYCLE_HOME" => "/tmp/cycle-owned-state"},
                   home: @home,
                   config_path: config_path
                 )

        assert %{path: "projects.registry_path", reason: "must be an absolute path"} in errors
      end
    )
  end

  test "sibling path prefixes do not satisfy state dir boundary" do
    with_temp_config(
      """
      projects:
        registry_path: /tmp/cycle-owned-state-evil/projects.yaml
      """,
      fn config_path ->
        assert {:error, errors} =
                 Config.load(
                   env: %{"CYCLE_HOME" => "/tmp/cycle-owned-state"},
                   home: @home,
                   config_path: config_path
                 )

        assert %{path: "projects.registry_path", reason: "must be under paths.state_dir"} in errors
      end
    )
  end

  test "legacy config.env can supply LINEAR_API_KEY compatibility" do
    root = temp_root()
    config_home = Path.join(root, "xdg")
    legacy_dir = Path.join(config_home, "cycle")
    File.mkdir_p!(legacy_dir)
    File.write!(Path.join(legacy_dir, "config.env"), "LINEAR_API_KEY=lin_secret\n")

    try do
      assert {:ok, config} = Config.load(env: %{"XDG_CONFIG_HOME" => config_home}, home: @home)
      assert config.secrets["linear_api_key"] == "lin_secret"
    after
      File.rm_rf!(root)
    end
  end

  test "custom linear api key env is resolved after config merge" do
    with_temp_config(
      """
      linear:
        api_key_env: CUSTOM_LINEAR_TOKEN
      """,
      fn config_path ->
        env = %{
          "LINEAR_API_KEY" => "lin_default",
          "CUSTOM_LINEAR_TOKEN" => "lin_custom"
        }

        assert {:ok, config} = Config.load(env: env, home: @home, config_path: config_path)
        assert config.secrets["linear_api_key"] == "lin_custom"
      end
    )
  end

  test "direct linear api key is stored only in secrets and redacted" do
    with_temp_config(
      """
      linear:
        api_key: lin_file_secret
      """,
      fn config_path ->
        assert {:ok, config} = Config.load(env: %{}, home: @home, config_path: config_path)
        assert config.secrets["linear_api_key"] == "lin_file_secret"
        refute Map.has_key?(config.linear, "api_key")
        refute inspect(Config.redacted(config)) =~ "lin_file_secret"
      end
    )
  end

  test "cycle env file contributes service environment values" do
    root = temp_root()
    env_file = Path.join(root, "cycle.env")
    File.mkdir_p!(root)
    File.write!(env_file, "CUSTOM_LINEAR_TOKEN=lin_from_env_file\n")

    with_temp_config(
      """
      linear:
        api_key_env: CUSTOM_LINEAR_TOKEN
      """,
      fn config_path ->
        assert {:ok, config} =
                 Config.load(
                   env: %{"CYCLE_ENV_FILE" => env_file},
                   home: @home,
                   config_path: config_path
                 )

        assert config.secrets["linear_api_key"] == "lin_from_env_file"
      end
    )

    File.rm_rf!(root)
  end

  test "redacted display never prints Linear API key in full" do
    assert {:ok, config} =
             Config.load(env: %{"LINEAR_API_KEY" => "lin_super_secret"}, home: @home)

    display = Config.redacted(config)
    assert get_in(display, [:secrets, "linear_api_key"]) == "[REDACTED]"
    refute inspect(display) =~ "lin_super_secret"
  end

  test "service api defaults to localhost port 4765" do
    assert {:ok, config} = Config.load(env: %{}, home: @home)

    assert get_in(config.service, ["api", "enabled"]) == true
    assert get_in(config.service, ["api", "bind"]) == "127.0.0.1"
    assert get_in(config.service, ["api", "port"]) == 4765
  end

  test "non-local service api bind requires explicit opt-in" do
    with_temp_config(
      """
      service:
        api:
          bind: 0.0.0.0
      """,
      fn config_path ->
        assert {:error, errors} = Config.load(env: %{}, home: @home, config_path: config_path)

        assert %{
                 path: "service.api.allow_non_local",
                 reason: "must be true when service.api.bind is not localhost"
               } in errors
      end
    )
  end

  test "non-local service api bind loads with explicit opt-in" do
    with_temp_config(
      """
      service:
        api:
          bind: 0.0.0.0
          allow_non_local: true
      """,
      fn config_path ->
        assert {:ok, config} = Config.load(env: %{}, home: @home, config_path: config_path)
        assert get_in(config.service, ["api", "bind"]) == "0.0.0.0"
      end
    )
  end

  defp with_temp_config(contents, fun) do
    root = temp_root()
    config_path = Path.join(root, "config.yaml")
    File.mkdir_p!(root)
    File.write!(config_path, contents)

    try do
      fun.(config_path)
    after
      File.rm_rf!(root)
    end
  end

  defp temp_root do
    Path.join(System.tmp_dir!(), "cycle-config-test-#{System.unique_integer([:positive])}")
  end
end
