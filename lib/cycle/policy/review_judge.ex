defmodule Cycle.Policy.ReviewJudge do
  @moduledoc """
  Decides whether Cycle review evidence can proceed to merging.

  This module is intentionally read-only: it does not write Linear comments or
  move issues. Hard stops are evaluated before model output and all failures
  fall back to `require_human_review`.
  """

  alias Cycle.Policy.ReviewEvidence.Evidence
  alias Cycle.Policy.ReviewJudge.Prompt

  @decisions ["proceed_to_merging", "require_human_review"]
  @confidences %{"low" => 0, "medium" => 1, "high" => 2}
  @default_minimum_confidence "medium"
  @default_sensitive_path_patterns [
    "WORKFLOW.md",
    ".github/",
    "config/",
    "priv/repo/",
    "migrations/",
    "security",
    "auth",
    "api",
    "schema",
    "database"
  ]

  defmodule Decision do
    @moduledoc "Review judge decision result."
    defstruct [
      :decision,
      :confidence,
      :human_review_value,
      :reason,
      evidence: [],
      hard_stops: [],
      provenance: %{}
    ]
  end

  defmodule HardStop do
    @moduledoc "Reason that forces human review before or after model execution."
    defstruct [:code, :message, details: %{}]
  end

  @doc """
  Returns a decision for collected review evidence.

  Options:

    * `:runner` - module implementing `Cycle.Policy.ReviewJudge.Runner`.
  """
  def decide(%Evidence{} = evidence, policy \\ %{}, opts \\ []) when is_map(policy) do
    provenance = provenance(policy)

    case hard_stops(evidence, policy) do
      [] -> run_model(evidence, policy, opts, provenance)
      stops -> require_human_review(stops, provenance)
    end
  end

  def confidence_at_least?(confidence, minimum) do
    with score when is_integer(score) <- Map.get(@confidences, to_string(confidence)),
         minimum_score when is_integer(minimum_score) <- Map.get(@confidences, to_string(minimum)) do
      score >= minimum_score
    else
      _ -> false
    end
  end

  defp run_model(evidence, policy, opts, provenance) do
    runner = Keyword.get(opts, :runner)

    if is_nil(runner) do
      require_human_review(
        [hard_stop(:judge_failure, "review judge runner is not configured")],
        provenance
      )
    else
      prompt = Prompt.build(evidence, policy)
      model_config = provenance["model_config"]

      case runner.run(prompt, model_config) do
        {:ok, output} -> parse_model_output(output, policy, provenance)
        {:error, reason} -> judge_failure(reason, provenance)
      end
    end
  rescue
    error -> judge_failure(Exception.message(error), provenance)
  end

  defp parse_model_output(output, policy, provenance) do
    with {:ok, parsed} <- normalize_output(output),
         true <- valid_decision?(parsed),
         true <- valid_confidence?(parsed) do
      minimum = minimum_confidence(policy)

      if parsed["decision"] == "proceed_to_merging" and
           not confidence_at_least?(parsed["confidence"], minimum) do
        require_human_review(
          [
            hard_stop(
              :confidence_below_threshold,
              "model confidence is below configured minimum",
              %{
                "confidence" => parsed["confidence"],
                "minimum_confidence" => minimum
              }
            )
          ],
          provenance
        )
      else
        %Decision{
          decision: parsed["decision"],
          confidence: parsed["confidence"],
          human_review_value: Map.get(parsed, "human_review_value"),
          reason: Map.get(parsed, "reason"),
          evidence: Map.get(parsed, "evidence", []),
          hard_stops: [],
          provenance: provenance
        }
      end
    else
      _ ->
        require_human_review(
          [hard_stop(:malformed_model_output, "review judge returned malformed output")],
          provenance
        )
    end
  end

  defp hard_stops(%Evidence{} = evidence, policy) do
    []
    |> hard_path_stops(evidence, policy)
    |> hard_label_stops(evidence, policy)
    |> required_missing_stops(evidence)
    |> git_unavailable_stop(evidence)
    |> workspace_mismatch_stop(evidence)
    |> validation_evidence_stop(evidence)
    |> sensitive_surface_stops(evidence, policy)
    |> Enum.reverse()
  end

  defp hard_path_stops(stops, evidence, policy) do
    patterns = get_in(policy, ["hard_require_human_review", "paths"]) || []

    matching_path_stops(stops, changed_files(evidence), patterns, :hard_path_stop)
  end

  defp sensitive_surface_stops(stops, evidence, policy) do
    configured = get_in(policy, ["sensitive_surface_paths"])
    patterns = configured || @default_sensitive_path_patterns

    matching_path_stops(stops, changed_files(evidence), patterns, :sensitive_surface)
  end

  defp matching_path_stops(stops, files, patterns, code) do
    matches =
      for file <- files,
          pattern <- patterns,
          path_match?(file, pattern),
          do: %{"path" => file, "pattern" => pattern}

    case matches do
      [] ->
        stops

      _ ->
        [hard_stop(code, "changed files require human review", %{"matches" => matches}) | stops]
    end
  end

  defp hard_label_stops(stops, evidence, policy) do
    hard_labels = get_in(policy, ["hard_require_human_review", "labels"]) || []
    labels = MapSet.new(Enum.map(evidence.labels || [], &String.downcase(to_string(&1))))

    matches =
      hard_labels
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(String.downcase(&1) in labels))

    case matches do
      [] ->
        stops

      _ ->
        [
          hard_stop(:hard_label_stop, "issue labels require human review", %{"labels" => matches})
          | stops
        ]
    end
  end

  defp required_missing_stops(stops, evidence) do
    required = Enum.filter(evidence.missing || [], & &1.required)

    case required do
      [] ->
        stops

      _ ->
        details =
          Enum.map(required, &%{"code" => Atom.to_string(&1.code), "message" => &1.message})

        [
          hard_stop(:missing_required_evidence, "required evidence is missing", %{
            "missing" => details
          })
          | stops
        ]
    end
  end

  defp git_unavailable_stop(stops, %Evidence{git: nil, missing: missing}) do
    if Enum.any?(missing || [], &(&1.code in [:git_state_unavailable, :missing_workspace])) do
      [
        hard_stop(:git_evidence_unavailable, "git evidence is unavailable for code changes")
        | stops
      ]
    else
      stops
    end
  end

  defp git_unavailable_stop(stops, _evidence), do: stops

  defp workspace_mismatch_stop(
         stops,
         %Evidence{
           git: %{"workspace_path" => git_workspace_path},
           run: %{"workspace_path" => run_workspace_path}
         }
       )
       when is_binary(git_workspace_path) and is_binary(run_workspace_path) do
    if same_path?(git_workspace_path, run_workspace_path) do
      stops
    else
      [
        hard_stop(:workspace_mismatch, "git evidence came from a different workspace", %{
          "git_workspace_path" => git_workspace_path,
          "run_workspace_path" => run_workspace_path
        })
        | stops
      ]
    end
  end

  defp workspace_mismatch_stop(stops, _evidence), do: stops

  defp same_path?(left, right), do: Path.expand(left) == Path.expand(right)

  defp validation_evidence_stop(stops, evidence) do
    if code_changes?(evidence) and not validation_evidence?(evidence) do
      [hard_stop(:missing_validation_evidence, "validation evidence is missing") | stops]
    else
      stops
    end
  end

  defp code_changes?(%Evidence{git: %{"has_changes" => true}}), do: true

  defp code_changes?(%Evidence{git: %{"changed_files" => files}}) when is_list(files),
    do: files != []

  defp code_changes?(_evidence), do: false

  defp validation_evidence?(%Evidence{run: %{"evidence" => evidence}}) when is_list(evidence) do
    Enum.any?(evidence, fn item ->
      type = item |> Map.get("type", "") |> to_string() |> String.downcase()
      name = item |> Map.get("name", "") |> to_string() |> String.downcase()
      status = item |> Map.get("status", "") |> to_string() |> String.downcase()

      status in ["passed", "ok", "success"] and
        (type in ["validation", "test", "tests", "check"] or
           validation_name?(name))
    end)
  end

  defp validation_evidence?(_evidence), do: false

  defp validation_name?(name) do
    Regex.match?(~r/(^|[^a-z0-9])(test|tests|check|checks|ci|smoke)([^a-z0-9]|$)/, name)
  end

  defp normalize_output(output) when is_map(output), do: {:ok, stringify_keys(output)}

  defp normalize_output(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} when is_map(decoded) -> {:ok, stringify_keys(decoded)}
      _ -> :error
    end
  end

  defp normalize_output(_output), do: :error

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp valid_decision?(output), do: Map.get(output, "decision") in @decisions

  defp valid_confidence?(output),
    do: Map.has_key?(@confidences, to_string(Map.get(output, "confidence")))

  defp minimum_confidence(policy),
    do: Map.get(policy, "minimum_skip_confidence", @default_minimum_confidence)

  defp provenance(policy) do
    %{
      "policy_profile" => Map.get(policy, "policy") || Map.get(policy, "profile"),
      "model_config" => %{
        "model" => Map.get(policy, "model"),
        "reasoning_effort" => Map.get(policy, "reasoning_effort"),
        "service_tier" => Map.get(policy, "service_tier")
      },
      "minimum_skip_confidence" => minimum_confidence(policy)
    }
  end

  defp require_human_review(stops, provenance) do
    %Decision{
      decision: "require_human_review",
      confidence: "high",
      reason: "Hard stop requires human review.",
      hard_stops: stops,
      provenance: provenance
    }
  end

  defp judge_failure(reason, provenance) do
    require_human_review(
      [hard_stop(:judge_failure, "review judge failed", %{"reason" => inspect(reason)})],
      provenance
    )
  end

  defp hard_stop(code, message, details \\ %{}),
    do: %HardStop{code: code, message: message, details: details}

  defp changed_files(%Evidence{git: %{"changed_files" => files}}) when is_list(files), do: files
  defp changed_files(_evidence), do: []

  defp path_match?(path, pattern) do
    path = to_string(path)
    pattern = to_string(pattern)

    cond do
      String.ends_with?(pattern, "/**") ->
        String.starts_with?(path, String.trim_trailing(pattern, "/**") <> "/")

      String.contains?(pattern, "*") ->
        path == String.replace(pattern, "*", "")

      true ->
        path == pattern or String.contains?(path, pattern)
    end
  end
end
