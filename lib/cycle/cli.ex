defmodule Cycle.CLI do
  @moduledoc """
  Command-line entrypoint for the Cycle escript.
  """

  @version Mix.Project.config()[:version]

  @usage """
  Cycle manages OpenAI Symphony engines across Linear projects.

  Usage:
    cycle --version
    cycle help
  """

  def main(args) do
    case args do
      ["--version"] ->
        IO.puts("cycle #{@version}")

      ["help"] ->
        IO.write(@usage)

      ["--help"] ->
        IO.write(@usage)

      [] ->
        IO.write(@usage)

      [command | _rest] ->
        IO.puts(:stderr, "cycle: unknown command: #{command}")
        System.halt(1)
    end
  end
end
