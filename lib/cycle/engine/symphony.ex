defmodule Cycle.Engine.Symphony do
  @moduledoc """
  Adapter for managed upstream Symphony checkouts.

  The current upstream boundary supports foreground process supervision and an
  optional status endpoint. Single-issue dispatch remains explicitly gated until
  Symphony exposes a stable external run protocol.
  """

  @behaviour Cycle.Engine.Adapter

  alias Cycle.Engine.Health
  alias Cycle.EngineRegistry

  @no_guardrails_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @default_port "4000"
  @default_status_url "http://127.0.0.1:4000/api/v1/state"

  @impl true
  def install(_engine, _opts),
    do: unsupported("install", "install is owned by cycle symphony install")

  @impl true
  def health(%EngineRegistry.Engine{} = engine, opts \\ []), do: Health.check(engine, opts)

  @impl true
  def capabilities(%EngineRegistry.Engine{} = engine) do
    Map.merge(base_capabilities(), engine.capabilities || %{})
  end

  @impl true
  def start_foreground(%EngineRegistry.Engine{} = engine, opts) do
    workflow = Keyword.get(opts, :workflow)

    with :ok <- require_workflow(workflow),
         :ok <- require_executable(engine),
         :ok <- require_workflow_file(workflow) do
      command = foreground_command(engine, opts)

      if Keyword.get(opts, :dry_run, false) do
        {:ok, command}
      else
        run_foreground(command, opts)
      end
    end
  end

  @impl true
  def dispatch(%EngineRegistry.Engine{} = engine, _request, _opts \\ []) do
    if Cycle.Engine.Adapter.dispatch_supported?(__MODULE__, engine) do
      {:error,
       error(
         "engine_dispatch_protocol_missing",
         "Symphony single-issue dispatch is advertised but no stable adapter protocol is implemented"
       )}
    else
      {:error,
       error(
         "engine_dispatch_unsupported",
         "Symphony adapter does not support single-issue dispatch; keep the run queued"
       )}
    end
  end

  @impl true
  def status(%EngineRegistry.Engine{} = engine, opts \\ []) do
    caps = capabilities(engine)

    if caps["status_api"] == true do
      url = caps["status_url"] || Keyword.get(opts, :status_url) || @default_status_url
      status_get = Keyword.get(opts, :status_get, &Req.get/2)

      case status_get.(url, receive_timeout: 2_000, retry: false) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, %{"state" => "reachable", "url" => url, "body" => body}}

        {:ok, %{status: status}} ->
          {:error,
           error("engine_status_unhealthy", "Symphony status endpoint returned #{status}")}

        {:error, reason} ->
          {:error,
           error(
             "engine_status_unreachable",
             "Symphony status endpoint failed: #{inspect(reason)}"
           )}

        _ ->
          {:error, error("engine_status_unreachable", "Symphony status endpoint failed")}
      end
    else
      {:ok, %{"state" => "unsupported", "reason" => "status_api capability is disabled"}}
    end
  end

  @impl true
  def stop(_engine, _opts), do: unsupported("stop", "Symphony foreground stop is process-owned")

  def foreground_command(%EngineRegistry.Engine{} = engine, opts) do
    workflow = Keyword.fetch!(opts, :workflow)
    port = opts |> Keyword.get(:port, @default_port) |> to_string()

    [
      executable_path(engine),
      guardrails_flag(opts),
      "--port",
      port,
      workflow
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp base_capabilities do
    %{
      "adapter" => "symphony",
      "adapter_contract" => "cycle.engine.adapter.v1",
      "workflow_schema" => "symphony.v1",
      "run_mode" => "foreground_process",
      "process_supervision" => true,
      "status_api" => false,
      "dispatch" => %{
        "single_issue" => false,
        "unsupported_reason" => "upstream Symphony does not expose a stable single-run protocol"
      },
      "stop" => %{"foreground_process" => false},
      "runtime_commands" => ["git", "codex", "mise"],
      "policy" => %{"approval_policy" => true, "sandbox" => true}
    }
  end

  defp run_foreground(command, opts) do
    [executable | args] = command
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    stdio = Keyword.get(opts, :stdio, IO.stream(:stdio, :line))
    env = Keyword.get(opts, :env, %{})

    cmd_opts =
      [into: stdio, env: Map.to_list(env)]
      |> maybe_put_cd(Path.dirname(executable))

    case command_runner.(executable, args, cmd_opts) do
      {_output, 0} ->
        :ok

      {_output, status} ->
        {:error, error("engine_exited", "Symphony engine exited with status #{status}")}
    end
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, dir), do: Keyword.put(opts, :cd, dir)

  defp require_workflow(workflow) when is_binary(workflow) and workflow != "", do: :ok

  defp require_workflow(_workflow),
    do: {:error, error("workflow_required", "cycle start requires --workflow PATH")}

  defp require_executable(engine) do
    path = executable_path(engine)

    if File.exists?(path) do
      :ok
    else
      {:error,
       error(
         "engine_executable_missing",
         "missing executable Symphony engine at #{path}; run cycle symphony install first"
       )}
    end
  end

  defp require_workflow_file(path) do
    if File.exists?(path),
      do: :ok,
      else: {:error, error("workflow_missing", "workflow file not found: #{path}")}
  end

  defp executable_path(%EngineRegistry.Engine{} = engine),
    do: Path.join([engine.install_path, "elixir", "bin", "symphony"])

  defp guardrails_flag(opts) do
    if Keyword.get(opts, :allow_foreground_unattended, false), do: @no_guardrails_flag
  end

  defp unsupported(code, message), do: {:error, error("engine_#{code}_unsupported", message)}
  defp error(code, message), do: %{"code" => code, "message" => message}
end
