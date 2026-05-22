defmodule Cycle.MigrationTest do
  use ExUnit.Case, async: false

  alias Cycle.Migration

  test "detects an active systemd Symphony service without mutating it" do
    output =
      "LoadState=loaded\nActiveState=active\nMainPID=4321\nFragmentPath=/etc/systemd/system/symphony.service\n"

    command_runner = fn
      "systemctl", ["show", "symphony.service" | _rest], _opts -> {output, 0}
    end

    hint = Migration.detect_service(command_runner)

    assert hint["manager"] == "systemd"
    assert hint["name"] == "symphony.service"
    assert hint["state"] == "running"
    assert hint["pid"] == 4321
    assert hint["file_path"] == "/etc/systemd/system/symphony.service"
    assert hint["guidance"] == nil
  end
end
