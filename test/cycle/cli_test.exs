defmodule Cycle.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints the version" do
    assert capture_io(fn -> Cycle.CLI.main(["--version"]) end) == "cycle 0.1.0-dev\n"
  end

  test "prints help" do
    output = capture_io(fn -> Cycle.CLI.main(["help"]) end)

    assert output =~ "Cycle manages OpenAI Symphony engines"
    assert output =~ "cycle --version"
  end
end
