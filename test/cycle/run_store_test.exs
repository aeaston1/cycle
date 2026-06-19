defmodule Cycle.RunStoreTest do
  use ExUnit.Case, async: false

  alias Cycle.RunStore

  @t0 "2026-05-22T12:00:00Z"
  @t1 "2026-05-22T12:01:00Z"
  @t2 "2026-05-22T12:02:00Z"

  test "creates a queued run record in the durable registry" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} = RunStore.create_queued(path, run_attrs(), now: @t0)

      assert run.id =~ ~r/^run-\d+$/
      assert run.state == "queued"
      assert run.issue["identifier"] == "AEA-162"
      assert run.project["name"] == "Cycle"
      assert run.engine["id"] == "symphony"
      assert run.workflow_path == "WORKFLOW.md"
      assert run.workflow_hash == "sha256:abc123"
      assert run.timestamps == %{"created_at" => @t0, "updated_at" => @t0}
      assert run.retry == %{"attempt" => 0}

      assert {:ok, registry} = RunStore.load(path)
      assert [persisted] = registry.runs
      assert persisted.id == run.id
    after
      File.rm_rf!(root)
    end
  end

  test "transitions through valid lifecycle states" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} = RunStore.create_queued(path, run_attrs(%{"id" => "run-1"}), now: @t0)
      assert {:ok, running} = RunStore.transition(path, run.id, "running", %{}, now: @t1)
      assert running.state == "running"
      assert running.timestamps["started_at"] == @t1

      assert {:ok, judging} =
               RunStore.transition(
                 path,
                 run.id,
                 "judging",
                 %{"last_event" => %{"summary" => "validation passed"}},
                 now: @t2
               )

      assert judging.state == "judging"
      assert judging.last_event == %{"summary" => "validation passed"}

      assert {:ok, completed} = RunStore.transition(path, run.id, "completed", %{}, now: @t2)
      assert completed.state == "completed"
      assert completed.timestamps["finished_at"] == @t2
    after
      File.rm_rf!(root)
    end
  end

  test "rejects invalid transitions" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} = RunStore.create_queued(path, run_attrs(%{"id" => "run-1"}), now: @t0)

      assert {:error, {:invalid_transition, "queued", "completed"}} =
               RunStore.transition(path, run.id, "completed", %{}, now: @t1)

      assert {:ok, registry} = RunStore.load(path)
      assert [persisted] = registry.runs
      assert persisted.state == "queued"
    after
      File.rm_rf!(root)
    end
  end

  test "persists retry fields and evidence pointers without full logs" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} = RunStore.create_queued(path, run_attrs(%{"id" => "run-1"}), now: @t0)
      assert {:ok, _running} = RunStore.transition(path, run.id, "running", %{}, now: @t1)

      assert {:ok, retrying} =
               RunStore.transition(
                 path,
                 run.id,
                 "retrying",
                 %{
                   "retry" => %{
                     "attempt" => 1,
                     "max_attempts" => 3,
                     "next_retry_at" => "2026-05-22T12:10:00Z"
                   },
                   "last_event" => %{"summary" => "engine exited unsuccessfully"},
                   "evidence" => [%{"type" => "log", "path" => "/tmp/cycle/logs/run-1.log"}]
                 },
                 now: @t2
               )

      assert retrying.state == "retrying"
      assert retrying.retry["attempt"] == 1
      assert retrying.retry["max_attempts"] == 3
      assert retrying.last_event == %{"summary" => "engine exited unsuccessfully"}
      assert retrying.evidence == [%{"type" => "log", "path" => "/tmp/cycle/logs/run-1.log"}]
    after
      File.rm_rf!(root)
    end
  end

  test "schedule_retry increments attempts and caps deterministic backoff" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} = RunStore.create_queued(path, run_attrs(%{"id" => "run-1"}), now: @t0)
      assert {:ok, _running} = RunStore.transition(path, run.id, "running", %{}, now: @t1)

      assert {:ok, first} =
               RunStore.schedule_retry(path, run.id, "engine_unhealthy",
                 now: @t1,
                 base_delay_seconds: 30,
                 max_delay_seconds: 60
               )

      assert first.retry["attempt"] == 1
      assert first.retry["next_retry_at"] == "2026-05-22T12:01:30Z"
      assert first.last_event["reason_code"] == "engine_unhealthy"

      assert {:ok, second} =
               RunStore.schedule_retry(path, run.id, "engine_unhealthy",
                 now: @t2,
                 base_delay_seconds: 30,
                 max_delay_seconds: 60
               )

      assert second.retry["attempt"] == 2
      assert second.retry["next_retry_at"] == "2026-05-22T12:03:00Z"
    after
      File.rm_rf!(root)
    end
  end

  test "schedule_retry stores capped next retry time" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} =
               RunStore.create_queued(
                 path,
                 run_attrs(%{"id" => "run-1", "retry" => %{"attempt" => 5}}),
                 now: @t0
               )

      assert {:ok, _running} = RunStore.transition(path, run.id, "running", %{}, now: @t1)

      assert {:ok, retrying} =
               RunStore.schedule_retry(path, run.id, "engine_unhealthy",
                 now: @t1,
                 base_delay_seconds: 30,
                 max_delay_seconds: 60,
                 max_attempts: 10
               )

      assert retrying.retry["attempt"] == 6
      assert retrying.retry["next_retry_at"] == "2026-05-22T12:02:00Z"
    after
      File.rm_rf!(root)
    end
  end

  test "schedule_retry fails exhausted retries after max attempts" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} =
               RunStore.create_queued(
                 path,
                 run_attrs(%{"id" => "run-1", "retry" => %{"attempt" => 3, "max_attempts" => 3}}),
                 now: @t0
               )

      assert {:ok, _running} = RunStore.transition(path, run.id, "running", %{}, now: @t1)

      assert {:ok, _retrying} =
               RunStore.transition(
                 path,
                 run.id,
                 "retrying",
                 %{"retry" => %{"attempt" => 3, "max_attempts" => 3, "next_retry_at" => @t2}},
                 now: @t1
               )

      assert {:ok, failed} =
               RunStore.schedule_retry(path, run.id, "engine_unhealthy",
                 now: @t2,
                 base_delay_seconds: 30,
                 max_delay_seconds: 60
               )

      assert failed.state == "failed"
      assert failed.retry["attempt"] == 4
      assert failed.retry["max_attempts"] == 3
      refute Map.has_key?(failed.retry, "next_retry_at")
      assert failed.last_event["type"] == "retry_exhausted"
      assert failed.last_event["reason_code"] == "engine_unhealthy"
      assert failed.timestamps["finished_at"] == @t2
    after
      File.rm_rf!(root)
    end
  end

  test "survives process restart through registry persistence" do
    root = temp_root()
    path = Path.join(root, "runs.yaml")

    try do
      assert {:ok, run} = RunStore.create_queued(path, run_attrs(%{"id" => "run-1"}), now: @t0)
      assert {:ok, _running} = RunStore.transition(path, run.id, "running", %{}, now: @t1)

      assert {:ok, restarted_registry} = RunStore.load(path)
      assert [restarted_run] = restarted_registry.runs
      assert restarted_run.id == "run-1"
      assert restarted_run.state == "running"
      assert restarted_run.timestamps["created_at"] == @t0
      assert restarted_run.timestamps["started_at"] == @t1
    after
      File.rm_rf!(root)
    end
  end

  defp run_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "issue" => %{"id" => "issue-id", "identifier" => "AEA-162"},
        "project" => %{"id" => "project-id", "name" => "Cycle"},
        "engine" => %{"id" => "symphony", "name" => "Symphony"},
        "workflow_path" => "WORKFLOW.md",
        "workflow_hash" => "sha256:abc123",
        "workspace_path" => "/tmp/cycle/workspaces/AEA-162"
      },
      overrides
    )
  end

  defp temp_root do
    Path.join(System.tmp_dir!(), "cycle-run-store-test-#{System.unique_integer([:positive])}")
  end
end
