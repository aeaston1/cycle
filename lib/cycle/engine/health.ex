defmodule Cycle.Engine.Health do
  @moduledoc """
  Read-only health probes for Cycle-managed engine records.
  """

  alias Cycle.EngineRegistry

  @expected_executable Path.join(["elixir", "bin", "symphony"])
  @supported_workflow_schemas ["symphony.v1"]
  @required_policy_capabilities ["approval_policy", "sandbox"]

  @type result :: map()

  @spec check(EngineRegistry.Engine.t(), keyword()) :: result()
  def check(%EngineRegistry.Engine{} = engine, opts \\ []) do
    now =
      Keyword.get_lazy(opts, :checked_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      end)

    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    executable? = Keyword.get(opts, :executable?, &File.exists?/1)
    dir? = Keyword.get(opts, :dir?, &File.dir?/1)
    command_finder = Keyword.get(opts, :command_finder, &System.find_executable/1)
    status_get = Keyword.get(opts, :status_get, &Req.get/2)

    engine
    |> probe(dir?, executable?, command_runner, command_finder, status_get)
    |> Map.put("checked_at", now)
  end

  @spec refresh_registry(EngineRegistry.t(), keyword()) :: EngineRegistry.t()
  def refresh_registry(%EngineRegistry{} = registry, opts \\ []) do
    %{registry | engines: Enum.map(registry.engines, &%{&1 | health: check(&1, opts)})}
  end

  @spec refresh_registry_file(Path.t(), keyword()) :: :ok | {:error, term()}
  def refresh_registry_file(path, opts \\ []) when is_binary(path) do
    with {:ok, registry} <- EngineRegistry.read(path) do
      EngineRegistry.write(path, refresh_registry(registry, opts))
    end
  end

  defp probe(engine, dir?, executable?, command_runner, command_finder, status_get) do
    install_path = engine.install_path
    executable_path = Path.join(install_path || "", @expected_executable)

    cond do
      !is_binary(install_path) or install_path == "" or !dir?.(install_path) ->
        %{"state" => "missing", "path" => install_path, "reason" => "install path is missing"}

      !executable?.(executable_path) ->
        %{
          "state" => "invalid",
          "path" => install_path,
          "executable" => executable_path,
          "reason" => "expected executable is missing"
        }

      true ->
        installed_probe(engine, executable_path, command_runner, command_finder, status_get)
    end
  end

  defp installed_probe(engine, executable_path, command_runner, command_finder, status_get) do
    with {:ok, revision} <- git_revision(engine.install_path, command_runner),
         :ok <- runtime_commands(engine.capabilities, command_finder, command_runner),
         :ok <- workflow_schema(engine.capabilities),
         :ok <- policy_capabilities(engine.capabilities),
         :ok <- status_api(engine.capabilities, status_get) do
      %{
        "state" => "healthy",
        "path" => engine.install_path,
        "executable" => executable_path,
        "revision" => revision
      }
    else
      {:error, reason} ->
        %{
          "state" => "unhealthy",
          "path" => engine.install_path,
          "executable" => executable_path,
          "reason" => reason
        }
    end
  end

  defp git_revision(path, command_runner) do
    case command_runner.("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} ->
        {:ok, String.trim(revision)}

      {output, status} ->
        {:error, "git revision check failed with status #{status}: #{trim(output)}"}
    end
  rescue
    error -> {:error, "git revision check failed: #{Exception.message(error)}"}
  end

  defp runtime_commands(capabilities, command_finder, command_runner) do
    capabilities
    |> Map.get("runtime_commands", [])
    |> Enum.reduce_while(:ok, fn command, :ok ->
      with :ok <- command_available(command, command_finder),
           :ok <- command_runs(command, command_runner) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp command_available(command, command_finder) do
    if command_finder.(command),
      do: :ok,
      else: {:error, "runtime command is missing: #{command}"}
  end

  defp command_runs("git", command_runner), do: run_version("git", ["--version"], command_runner)

  defp command_runs("codex", command_runner),
    do: run_version("codex", ["--version"], command_runner)

  defp command_runs("mise", command_runner),
    do: run_version("mise", ["--version"], command_runner)

  defp command_runs(_command, _command_runner), do: :ok

  defp run_version(command, args, command_runner) do
    case command_runner.(command, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "runtime command #{command} failed with status #{status}: #{trim(output)}"}
    end
  rescue
    error -> {:error, "runtime command #{command} failed: #{Exception.message(error)}"}
  end

  defp workflow_schema(capabilities) do
    case Map.get(capabilities, "workflow_schema") do
      schema when schema in @supported_workflow_schemas -> :ok
      nil -> {:error, "workflow schema capability is missing"}
      schema -> {:error, "unsupported workflow schema capability: #{schema}"}
    end
  end

  defp policy_capabilities(capabilities) do
    policy = Map.get(capabilities, "policy", %{})

    case Enum.find(@required_policy_capabilities, &(Map.get(policy, &1) != true)) do
      nil -> :ok
      capability -> {:error, "policy capability is missing: #{capability}"}
    end
  end

  defp status_api(%{"status_api" => true} = capabilities, status_get) do
    case Map.get(capabilities, "status_url") do
      url when is_binary(url) and url != "" ->
        case status_get.(url, receive_timeout: 2_000, retry: false) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{status: status}} -> {:error, "status API returned #{status}"}
          {:error, error} -> {:error, "status API check failed: #{inspect(error)}"}
          _ -> {:error, "status API check failed"}
        end

      _ ->
        {:error, "status API capability is enabled without status_url"}
    end
  end

  defp status_api(_capabilities, _status_get), do: :ok

  defp trim(output) when is_binary(output), do: output |> String.trim() |> String.slice(0, 200)
  defp trim(output), do: inspect(output)
end
