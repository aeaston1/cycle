defmodule Cycle.EngineIdTest do
  use ExUnit.Case, async: true

  alias Cycle.EngineId

  test "parses valid engine ids" do
    assert {:ok, %{id: "openai-symphony@main", name: "openai-symphony", ref: "main"}} =
             EngineId.parse("openai-symphony@main")

    assert {:ok, %{ref: "release/2026.05"}} = EngineId.parse("openai-symphony@release/2026.05")
  end

  test "rejects invalid engine ids" do
    invalid = [
      "openai-symphony",
      "OpenAI@main",
      "openai-symphony@",
      "openai-symphony@../main",
      "openai-symphony@feature//branch",
      "openai-symphony@feature branch",
      "@main"
    ]

    for id <- invalid do
      assert {:error, _reason} = EngineId.parse(id)
    end
  end
end
