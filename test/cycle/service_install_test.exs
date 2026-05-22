defmodule Cycle.Service.InstallTest do
  use ExUnit.Case, async: true

  alias Cycle.Service.Install

  test "dry-run renders planned paths and writes no files" do
    with_install_env(fn ctx ->
      assert {:ok, result} =
               Install.install(base_opts(ctx, dry_run: true, service_path: ctx.service_path))

      assert result.platform == :systemd
      assert result.service_path == ctx.service_path
      assert result.rendered_service =~ "ExecStart=#{ctx.executable} start"

      assert result.commands == [
               ["systemctl", "--user", "daemon-reload"],
               ["systemctl", "--user", "enable", "cycle.service"]
             ]

      refute File.exists?(ctx.service_path)
      refute File.exists?(result.env_file_path)
    end)
  end

  test "missing auth fails clearly" do
    with_install_env(%{"LINEAR_API_KEY" => ""}, fn ctx ->
      assert Install.install(base_opts(ctx, dry_run: true)) ==
               {:error,
                "LINEAR_API_KEY is not configured; run cycle linear configure before service install",
                1}
    end)
  end

  test "missing engine fails with install guidance" do
    with_install_env(fn ctx ->
      File.rm_rf!(ctx.engine_path)

      assert {:error, message, 2} = Install.install(base_opts(ctx, dry_run: true))
      assert message =~ "default engine openai-symphony@main is missing"
      assert message =~ "run cycle symphony install"
    end)
  end

  test "invalid policy fails clearly" do
    with_install_env(fn ctx ->
      write_config!(ctx.config_home, "policy:\n  enforcement: enforce\n")

      assert Install.install(base_opts(ctx, dry_run: true)) ==
               {:error, "invalid policy config: policy.enforcement: must be report or block", 3}
    end)
  end

  test "existing unrelated service file is not overwritten" do
    with_install_env(fn ctx ->
      File.mkdir_p!(Path.dirname(ctx.service_path))
      File.write!(ctx.service_path, "unrelated service\n")

      assert Install.install(base_opts(ctx, dry_run: true, service_path: ctx.service_path)) ==
               {:error,
                "refusing to overwrite unrelated existing service file: #{ctx.service_path}", 3}

      assert File.read!(ctx.service_path) == "unrelated service\n"
    end)
  end

  test "confirmed install writes files and enables the user service" do
    with_install_env(fn ctx ->
      parent = self()

      command_runner = fn command, args, _opts ->
        send(parent, {:command, [command | args]})
        {"", 0}
      end

      assert {:ok, result} =
               Install.install(
                 base_opts(ctx,
                   yes: true,
                   service_path: ctx.service_path,
                   command_runner: command_runner
                 )
               )

      assert File.read!(ctx.service_path) == result.rendered_service
      assert File.read!(result.env_file_path) =~ "CYCLE_HOME=#{ctx.cycle_home}"
      assert_received {:command, ["systemctl", "--user", "daemon-reload"]}
      assert_received {:command, ["systemctl", "--user", "enable", "cycle.service"]}
    end)
  end

  test "non-interactive install requires yes" do
    with_install_env(fn ctx ->
      opts = base_opts(ctx, input_reader: fn _prompt -> nil end)

      assert Install.install(opts) ==
               {:error, "non-interactive service install requires --yes", 1}

      refute File.exists?(ctx.service_path)
    end)
  end

  test "platform detection is explicit" do
    assert Install.detect_platform(os_type: {:unix, :darwin}) == {:ok, :launchd}

    assert Install.detect_platform(
             os_type: {:unix, :linux},
             command_finder: fn
               "systemctl" -> "/usr/bin/systemctl"
               _command -> nil
             end
           ) == {:ok, :systemd}

    assert Install.detect_platform(os_type: {:unix, :linux}, command_finder: fn _ -> nil end) ==
             {:error, "systemd service install requires systemctl", 2}
  end

  defp base_opts(ctx, overrides) do
    Keyword.merge(
      [
        env: ctx.env,
        home: ctx.home,
        platform: :systemd,
        executable_path: ctx.executable,
        service_path: ctx.service_path,
        command_runner: fn _command, _args, _opts -> {"", 0} end,
        command_finder: fn _command -> "/usr/bin/fake" end
      ],
      overrides
    )
  end

  defp with_install_env(env_overrides \\ %{}, fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "cycle-service-install-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    home = Path.join(root, "home")
    cycle_home = Path.join(root, "cycle-home")
    config_home = Path.join(root, "config-home")
    executable = Path.join(root, "bin/cycle")
    service_path = Path.join(root, "systemd/cycle.service")
    engine_path = Path.join([cycle_home, "engines", "openai-symphony", "main"])

    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "#!/bin/sh\n")
    File.chmod!(executable, 0o755)
    File.mkdir_p!(Path.join(engine_path, "elixir/bin"))
    File.write!(Path.join(engine_path, "elixir/bin/symphony"), "#!/bin/sh\n")

    env =
      Map.merge(
        %{
          "HOME" => home,
          "CYCLE_HOME" => cycle_home,
          "XDG_CONFIG_HOME" => config_home,
          "LINEAR_API_KEY" => "lin_test"
        },
        env_overrides
      )

    try do
      fun.(%{
        root: root,
        home: home,
        cycle_home: cycle_home,
        config_home: config_home,
        executable: executable,
        service_path: service_path,
        engine_path: engine_path,
        env: env
      })
    after
      File.rm_rf(root)
    end
  end

  defp write_config!(config_home, content) do
    config_dir = Path.join(config_home, "cycle")
    File.mkdir_p!(config_dir)
    File.write!(Path.join(config_dir, "config.yaml"), content)
  end
end
