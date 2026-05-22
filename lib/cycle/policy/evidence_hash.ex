defmodule Cycle.Policy.EvidenceHash do
  @moduledoc """
  Computes stable review judge evidence hashes and detects duplicate comments.

  The hash input is canonical JSON built from stable evidence only. Callers
  should pass normalized evidence, policy versions, and judge profile values,
  not raw logs or volatile timestamps.
  """

  @prefix "sha256:"
  @marker "Cycle-Evidence-Hash"
  @marker_regex ~r/(?:^|\n)Cycle-Evidence-Hash:\s*(sha256:[a-f0-9]{64})(?:\s|$)/i

  @doc """
  Returns the comment marker used to record a review judge evidence hash.
  """
  def marker, do: @marker

  @doc """
  Computes a SHA-256 evidence hash from stable evidence input.

  Options:

    * `:judge_profile` - review judge profile or policy name.
    * `:workflow_policy_version` - workflow or project policy version.
    * `:global_policy_version` - Cycle global policy version.
  """
  def compute(evidence_input, opts \\ []) when is_map(evidence_input) do
    input =
      evidence_input
      |> Map.put("judge_profile", Keyword.get(opts, :judge_profile))
      |> put_if_present("workflow_policy_version", Keyword.get(opts, :workflow_policy_version))
      |> put_if_present("global_policy_version", Keyword.get(opts, :global_policy_version))

    @prefix <> Base.encode16(:crypto.hash(:sha256, canonical_json(input)), case: :lower)
  end

  @doc """
  Formats the marker line included in new review judge comments.
  """
  def marker_line(hash) when is_binary(hash), do: "#{@marker}: #{hash}"

  @doc """
  Returns true when any existing comment already carries the evidence hash.
  """
  def duplicate_comment?(comments, hash) when is_list(comments) and is_binary(hash) do
    Enum.any?(comments, &(extract(&1) == hash))
  end

  @doc """
  Extracts an evidence hash from a Linear comment or raw comment body.
  """
  def extract(comment_or_body)

  def extract(body) when is_binary(body) do
    case Regex.run(@marker_regex, body) do
      [_, hash] -> String.downcase(hash)
      _ -> nil
    end
  end

  def extract(%struct{} = comment) when is_atom(struct), do: extract(Map.get(comment, :body))

  def extract(comment) when is_map(comment),
    do: extract(Map.get(comment, :body) || Map.get(comment, "body"))

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> Jason.encode!(key) <> ":" <> canonical_json(value) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> (value |> Enum.map(&canonical_json/1) |> Enum.join(",")) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
