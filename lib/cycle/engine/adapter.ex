defmodule Cycle.Engine.Adapter do
  @moduledoc """
  Behaviour for Cycle-managed engine adapters.

  Adapters are the boundary between Cycle's control plane and an execution
  engine. They expose machine-readable capabilities and explicit unsupported
  operations so schedulers do not infer success from a queued decision.
  """

  alias Cycle.EngineRegistry

  @type capability_map :: map()
  @type adapter_error :: %{required(:code) => String.t(), required(:message) => String.t()}
  @type run_request :: map()
  @type foreground_option ::
          {:workflow, Path.t()}
          | {:port, String.t() | integer()}
          | {:dry_run, boolean()}
          | {:env, map()}
          | {:command_runner, function()}
          | {:stdio, Collectable.t()}

  @callback install(EngineRegistry.Engine.t(), keyword()) :: :ok | {:error, adapter_error()}
  @callback health(EngineRegistry.Engine.t(), keyword()) :: map()
  @callback capabilities(EngineRegistry.Engine.t()) :: capability_map()
  @callback start_foreground(EngineRegistry.Engine.t(), keyword()) ::
              {:ok, [String.t()]} | :ok | {:error, adapter_error()}
  @callback dispatch(EngineRegistry.Engine.t(), run_request(), keyword()) ::
              {:ok, map()} | {:error, adapter_error()}
  @callback status(EngineRegistry.Engine.t(), keyword()) ::
              {:ok, map()} | {:error, adapter_error()}
  @callback stop(EngineRegistry.Engine.t(), keyword()) :: :ok | {:error, adapter_error()}

  @doc """
  Returns true when an adapter advertises single-issue dispatch support.
  """
  def dispatch_supported?(adapter, %EngineRegistry.Engine{} = engine) when is_atom(adapter) do
    adapter.capabilities(engine)
    |> get_in(["dispatch", "single_issue"])
    |> Kernel.==(true)
  end
end
