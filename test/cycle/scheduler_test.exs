defmodule Cycle.SchedulerTest do
  use ExUnit.Case, async: true

  alias Cycle.EngineRegistry
  alias Cycle.Scheduler

  defmodule FakeAdapter do
    @behaviour Cycle.Engine.Adapter

    def install(_engine, _opts), do: :ok
    def health(_engine, _opts), do: %{"state" => "healthy"}
    def capabilities(engine), do: engine.capabilities
    def start_foreground(_engine, _opts), do: :ok
    def status(_engine, _opts), do: {:ok, %{}}
    def stop(_engine, _opts), do: :ok

    def dispatch(_engine, request, _opts), do: {:ok, %{"run_id" => request["run_id"]}}
  end

  test "scheduler can ask whether adapter dispatch is supported" do
    refute Scheduler.dispatch_supported?(FakeAdapter, engine(false))
    assert Scheduler.dispatch_supported?(FakeAdapter, engine(true))
  end

  test "unsupported dispatch stays queued with stable reason code" do
    assert {:queued, %{"code" => "engine_dispatch_unsupported"}} =
             Scheduler.dispatch_or_queue(FakeAdapter, engine(false), %{"run_id" => "run-1"})
  end

  test "supported dispatch may create a running result" do
    assert {:running, %{"run_id" => "run-1"}} =
             Scheduler.dispatch_or_queue(FakeAdapter, engine(true), %{"run_id" => "run-1"})
  end

  defp engine(single_issue) do
    %EngineRegistry.Engine{
      id: "openai-symphony@main",
      name: "openai-symphony",
      source: "https://github.com/OWNER/REPO.git",
      ref: "main",
      install_path: "/tmp/cycle/engines/openai-symphony/main",
      capabilities: %{"dispatch" => %{"single_issue" => single_issue}},
      health: %{"state" => "unknown"}
    }
  end
end
