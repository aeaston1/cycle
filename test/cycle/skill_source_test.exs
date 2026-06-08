defmodule Cycle.SkillSourceTest do
  use ExUnit.Case, async: true

  @skill_dir Path.expand("../../skills/cycle-project-onboarding", __DIR__)

  test "cycle project onboarding skill has valid metadata and references" do
    skill_path = Path.join(@skill_dir, "SKILL.md")
    install_path = Path.join(@skill_dir, "references/INSTALL.md")
    openai_path = Path.join(@skill_dir, "agents/openai.yaml")

    assert File.regular?(skill_path)
    assert File.regular?(install_path)
    assert File.regular?(openai_path)

    assert {:ok, body} = File.read(skill_path)
    assert {:ok, metadata, instructions} = parse_frontmatter(body)

    assert metadata["name"] == "cycle-project-onboarding"
    assert is_binary(metadata["description"])
    assert String.length(metadata["description"]) > 40
    assert instructions =~ "references/INSTALL.md"

    assert {:ok, interface_metadata} = YamlElixir.read_from_file(openai_path)

    assert get_in(interface_metadata, ["interface", "display_name"]) ==
             "Cycle Project Onboarding"

    assert get_in(interface_metadata, ["interface", "short_description"]) =~ "Cycle"

    assert get_in(interface_metadata, ["interface", "default_prompt"]) =~
             "$cycle-project-onboarding"
  end

  defp parse_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [yaml, instructions] ->
        with {:ok, metadata} <- YamlElixir.read_from_string(yaml) do
          {:ok, metadata, instructions}
        end

      _ ->
        {:error, :missing_frontmatter_end}
    end
  end

  defp parse_frontmatter(_body), do: {:error, :missing_frontmatter}
end
