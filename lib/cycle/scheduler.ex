defmodule Cycle.Scheduler do
  @moduledoc """
  Scheduler-facing helpers for engine dispatch gates.

  Full candidate selection lives in later scheduler milestones. This module
  gives that code a stable way to ask whether creating a running record is
  allowed for the selected engine adapter.
  """

  alias Cycle.EngineRegistry

  @spec dispatch_supported?(module(), EngineRegistry.Engine.t()) :: boolean()
  def dispatch_supported?(adapter, %EngineRegistry.Engine{} = engine) do
    Cycle.Engine.Adapter.dispatch_supported?(adapter, engine)
  end

  @spec dispatch_or_queue(module(), EngineRegistry.Engine.t(), map(), keyword()) ::
          {:running, map()} | {:queued, map()}
  def dispatch_or_queue(adapter, %EngineRegistry.Engine{} = engine, request, opts \\ []) do
    if dispatch_supported?(adapter, engine) do
      case adapter.dispatch(engine, request, opts) do
        {:ok, run_status} ->
          {:running, run_status}

        {:error, %{"code" => "engine_dispatch_unsupported"} = error} ->
          {:queued, error}

        {:error, error} ->
          {:queued, error}
      end
    else
      {:queued,
       %{
         "code" => "engine_dispatch_unsupported",
         "message" => "selected engine adapter does not support single-issue dispatch"
       }}
    end
  end
end
