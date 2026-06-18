defmodule Cycle.Security do
  @moduledoc """
  Shared redaction and deterministic public-surface scanning helpers.
  """

  @tokenish_key ~r/(authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret)/i
  @bearer ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]+/i
  @basic ~r/\bBasic\s+[A-Za-z0-9._~+\/=-]+/i
  @assignment ~r/\b([A-Za-z0-9_.-]*(?:token|secret|api[_-]?key)[A-Za-z0-9_.-]*)=([^\s]+)/i
  @long_token ~r/\b(?=[A-Za-z0-9._~+=-]{32,}\b)(?=[A-Za-z0-9._~+=-]*[0-9])[A-Za-z0-9._~+=-]{32,}\b/
  @credentialed_url ~r{(https?://)[^/\s@]+@}i

  @public_doc_paths ["README.md", "WORKFLOW.md", "docs", "packaging", "skills", ".env.example"]
  @allowed_private_strings ["aeaston1/tap/cycle"]
  @private_repo_pattern ~r/\baeaston1\/(?!tap\/cycle\b)[A-Za-z0-9_.-]+/i
  @machine_local_path_pattern ~r{/(?:Users|home)/[A-Za-z0-9._-]+/[^\s`'")]+}
  @numeric_project_slug_pattern ~r/project_slug:\s*["']?\d{6,}["']?/

  @type finding :: %{path: String.t(), reason: String.t(), value: String.t()}

  def public_doc_paths, do: @public_doc_paths

  def allowed_private_strings, do: @allowed_private_strings

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if tokenish_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(nested)}
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_binary(value) do
    value
    |> then(&Regex.replace(@bearer, &1, "Bearer [REDACTED]"))
    |> then(&Regex.replace(@basic, &1, "Basic [REDACTED]"))
    |> then(&Regex.replace(@assignment, &1, "\\1=[REDACTED]"))
    |> then(&Regex.replace(@credentialed_url, &1, "\\1[REDACTED]@"))
    |> then(&Regex.replace(@long_token, &1, "[REDACTED]"))
  end

  def redact(value), do: value

  def scan_public_docs(root) when is_binary(root) do
    scan_paths(root, @public_doc_paths, private_repo_scan_values())
  end

  def scan_paths(root, relative_paths, values) when is_binary(root) and is_list(relative_paths) do
    files =
      relative_paths
      |> Enum.map(&Path.join(root, &1))
      |> Enum.flat_map(&expand_path/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(files, fn file ->
      rel = Path.relative_to(file, root)

      case File.read(file) do
        {:ok, body} -> scan_body(rel, body, values)
        {:error, _reason} -> []
      end
    end)
  end

  def scan_archive(archive, values) when is_binary(archive) and is_list(values) do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "cycle-security-scan-#{System.unique_integer([:positive, :monotonic])}"
      ])

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    try do
      case System.cmd("tar", ["-xzf", archive, "-C", tmp], stderr_to_stdout: true) do
        {_, 0} -> {:ok, scan_paths(tmp, ["."], values)}
        {output, _status} -> {:error, "failed to extract archive:\n#{output}"}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  def scan_body(path, body, values)
      when is_binary(path) and is_binary(body) and is_list(values) do
    explicit_findings =
      values
      |> Enum.reject(&(&1 in @allowed_private_strings))
      |> Enum.filter(&String.contains?(body, &1))
      |> Enum.map(&%{path: path, reason: "contains forbidden value", value: &1})

    private_repo_findings =
      @private_repo_pattern
      |> Regex.scan(body)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @allowed_private_strings))
      |> Enum.map(&%{path: path, reason: "contains private repo name", value: &1})

    machine_local_path_findings =
      @machine_local_path_pattern
      |> Regex.scan(body)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&%{path: path, reason: "contains machine-local path", value: &1})

    numeric_project_slug_findings =
      @numeric_project_slug_pattern
      |> Regex.scan(body)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&%{path: path, reason: "contains numeric project slug", value: &1})

    explicit_findings ++
      private_repo_findings ++ machine_local_path_findings ++ numeric_project_slug_findings
  end

  def fake_secret_values do
    [
      "lin_9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b",
      "cycle_test_secret_4d4c1f7a9b2e6c8d0a3f5b7e9c1a2d4f",
      "ghp_9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f"
    ]
  end

  defp expand_path(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.flat_map(&expand_path(Path.join(path, &1)))

      true ->
        []
    end
  end

  defp private_repo_scan_values, do: @allowed_private_strings

  defp tokenish_key?(key), do: Regex.match?(@tokenish_key, to_string(key))
end
