defmodule Cycle.WorkflowResolver do
  @moduledoc """
  Resolves repo-owned workflow files into Cycle-owned discovery records.
  """

  alias Cycle.Config.Paths

  @default_workflow "WORKFLOW.md"

  defmodule Result do
    @moduledoc false
    defstruct [:path, :resolved_path, :cache_path, :content, :hash]
  end

  @type repo :: %{required(String.t()) => String.t()}
  @type result :: %Result{}

  @spec resolve(repo(), String.t() | nil, keyword()) :: {:ok, result()} | {:error, String.t()}
  def resolve(repo, workflow_path \\ nil, opts \\ []) when is_map(repo) do
    path = workflow_path || @default_workflow

    with :ok <- validate_workflow_path(path) do
      repo_url = repo["url"] || repo[:url]
      repo_full_name = repo["full_name"] || repo[:full_name] || full_name_from_url(repo_url)

      candidates = candidate_roots(repo_url, repo_full_name, opts)

      case resolve_from_candidates(candidates, path) do
        {:ok, result} ->
          {:ok, result}

        :not_found ->
          if local_repo_url?(repo_url) do
            {:error, "workflow not found at #{path}"}
          else
            resolve_from_cache(repo_url, repo_full_name, path, opts)
          end
      end
    end
  end

  def cache_path(repo_full_name, cache_root) when is_binary(repo_full_name) do
    Path.join(cache_root, sanitize_repo_full_name(repo_full_name))
  end

  def sanitize_repo_full_name(repo_full_name) when is_binary(repo_full_name) do
    repo_full_name
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
  end

  defp validate_workflow_path(path) when is_binary(path) and path != "" do
    if String.starts_with?(path, "/") or String.contains?(path, "..") do
      {:error, "workflow path must be repo-relative"}
    else
      :ok
    end
  end

  defp validate_workflow_path(_path), do: {:error, "workflow path must be a non-empty string"}

  defp candidate_roots(repo_url, repo_full_name, opts) do
    []
    |> maybe_add_local_repo(repo_url)
    |> Kernel.++(local_checkout_candidates(repo_full_name, opts))
    |> Enum.uniq()
  end

  defp maybe_add_local_repo(candidates, repo_url) when is_binary(repo_url) do
    cond do
      File.dir?(repo_url) -> candidates ++ [repo_url]
      String.starts_with?(repo_url, "file://") -> candidates ++ [URI.parse(repo_url).path]
      true -> candidates
    end
  end

  defp maybe_add_local_repo(candidates, _repo_url), do: candidates

  defp local_repo_url?(repo_url) when is_binary(repo_url) do
    File.dir?(repo_url) or String.starts_with?(repo_url, "file://")
  end

  defp local_repo_url?(_repo_url), do: false

  defp local_checkout_candidates(nil, _opts), do: []

  defp local_checkout_candidates(repo_full_name, opts) do
    roots = Keyword.get(opts, :local_checkout_roots, [])
    repo_name = repo_full_name |> String.split("/") |> List.last()
    sanitized = sanitize_repo_full_name(repo_full_name)

    explicit =
      opts
      |> Keyword.get(:local_checkout_paths, [])
      |> List.wrap()

    root_candidates =
      Enum.flat_map(List.wrap(roots), fn root ->
        [
          Path.join(root, repo_full_name),
          Path.join(root, repo_name),
          Path.join(root, sanitized)
        ]
      end)

    explicit ++ root_candidates
  end

  defp resolve_from_candidates(candidates, workflow_path) do
    Enum.find_value(candidates, :not_found, fn root ->
      workflow_file = Path.expand(workflow_path, root)

      if inside?(root, workflow_file) and File.regular?(workflow_file) do
        read_result(workflow_path, workflow_file, root)
      end
    end)
  end

  defp resolve_from_cache(repo_url, repo_full_name, workflow_path, opts) do
    with :ok <- validate_remote(repo_url),
         {:ok, repo_full_name} <- require_full_name(repo_full_name),
         {:ok, cache_root} <- fetch_cache_root(opts),
         cache_path <- cache_path(repo_full_name, cache_root),
         :ok <- ensure_cache(repo_url, cache_path, opts) do
      workflow_file = Path.join(cache_path, workflow_path)

      if File.regular?(workflow_file) do
        read_result(workflow_path, workflow_file, cache_path)
      else
        {:error, "workflow not found at #{workflow_path}"}
      end
    end
  end

  defp validate_remote(repo_url) when is_binary(repo_url) do
    uri = URI.parse(repo_url)

    if uri.scheme == "https" and uri.host == "github.com" and is_nil(uri.userinfo) do
      :ok
    else
      {:error, "workflow cache requires an HTTPS GitHub repo URL"}
    end
  end

  defp validate_remote(_repo_url), do: {:error, "repo URL is required"}

  defp require_full_name(repo_full_name) when is_binary(repo_full_name) and repo_full_name != "",
    do: {:ok, repo_full_name}

  defp require_full_name(_repo_full_name), do: {:error, "repo full name is required"}

  defp fetch_cache_root(opts) do
    case Keyword.get(opts, :cache_root) do
      value when is_binary(value) and value != "" -> {:ok, Paths.normalize(value)}
      _ -> {:error, "workflow cache path is required"}
    end
  end

  defp ensure_cache(repo_url, cache_path, opts) do
    git = Keyword.get(opts, :git, &System.cmd/3)

    if File.dir?(Path.join(cache_path, ".git")) do
      run_git(git, ["-C", cache_path, "fetch", "--prune", "--tags"], opts)
    else
      File.mkdir_p!(Path.dirname(cache_path))
      run_git(git, ["clone", "--quiet", repo_url, cache_path], opts)
    end
  end

  defp run_git(git, args, opts) do
    case git.("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if Keyword.get(opts, :include_git_output, false) do
          {:error,
           "git #{Enum.join(args, " ")} failed with status #{status}: #{String.trim(output)}"}
        else
          {:error, "git #{List.last(args)} failed with status #{status}"}
        end
    end
  end

  defp read_result(workflow_path, resolved_path, root) do
    content = File.read!(resolved_path)

    {:ok,
     %Result{
       path: workflow_path,
       resolved_path: Paths.normalize(resolved_path),
       cache_path: Paths.normalize(root),
       content: content,
       hash: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
     }}
  end

  defp inside?(root, path) do
    root = root |> Paths.normalize() |> Path.join("")
    path = Paths.normalize(path)
    String.starts_with?(path, root)
  end

  defp full_name_from_url("https://github.com/" <> rest), do: String.trim_trailing(rest, ".git")
  defp full_name_from_url(_url), do: nil
end
