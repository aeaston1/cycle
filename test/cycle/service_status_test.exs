defmodule Cycle.Service.StatusTest do
  use ExUnit.Case, async: false

  alias Cycle.Service.Status

  @mutating_verbs Status.mutating_verbs()

  test "missing systemd service reports missing" do
    snapshot = snapshot_with_systemd("LoadState=not-found\nActiveState=inactive\nMainPID=0\n", 1)

    assert snapshot["service"]["manager"] == "systemd"
    assert snapshot["service"]["installed"] == false
    assert snapshot["service"]["state"] == "missing"
    assert snapshot["service"]["pid"] == nil
    assert snapshot["service"]["guidance"] =~ "not installed"
  end

  test "active systemd service reports running pid" do
    snapshot =
      snapshot_with_systemd(
        "LoadState=loaded\nActiveState=active\nMainPID=1234\nFragmentPath=/etc/systemd/system/cycle.service\n",
        0
      )

    assert snapshot["service"]["installed"] == true
    assert snapshot["service"]["state"] == "running"
    assert snapshot["service"]["pid"] == 1234
    assert snapshot["service"]["file_path"] == "/etc/systemd/system/cycle.service"
  end

  test "failed systemd service reports failed and log pointer" do
    snapshot =
      snapshot_with_systemd(
        "LoadState=loaded\nActiveState=failed\nMainPID=0\nFragmentPath=/etc/systemd/system/cycle.service\n",
        0
      )

    assert snapshot["service"]["state"] == "failed"
    assert snapshot["logs"] =~ "/logs/cycle.log"
  end

  test "status command list contains no mutating verbs" do
    snapshot = snapshot_with_systemd("LoadState=not-found\nActiveState=inactive\nMainPID=0\n", 1)

    command_words = snapshot["commands_checked"] |> List.flatten() |> Enum.map(&to_string/1)

    refute Enum.any?(command_words, &(&1 in @mutating_verbs))
  end

  test "json snapshot has stable top-level keys" do
    snapshot = snapshot_with_systemd("LoadState=not-found\nActiveState=inactive\nMainPID=0\n", 1)

    assert Map.keys(snapshot) == [
             "api_health",
             "commands_checked",
             "config_path",
             "drift_summary",
             "engine_health",
             "logs",
             "service",
             "state_path"
           ]
  end

  defp snapshot_with_systemd(output, status) do
    Status.snapshot(
      home: System.tmp_dir!(),
      env: %{"CYCLE_HOME" => tmp_path(), "XDG_CONFIG_HOME" => tmp_path()},
      command_runner: fn
        "systemctl", ["show", "cycle.service" | _rest], _opts -> {output, status}
      end,
      api_get: fn _url, _opts -> {:error, :econnrefused} end
    )
  end

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "cycle-service-status-test-#{System.unique_integer([:positive])}"
    )
  end
end
