defmodule Cycle.ReviewJudgeRegistryTest do
  use ExUnit.Case, async: false

  alias Cycle.ReviewJudgeRegistry

  test "concurrent records to the same registry path preserve every update" do
    path =
      Path.join(
        System.tmp_dir!(),
        "cycle-review-judge-registry-test-#{System.unique_integer([:positive])}/review_judge.yaml"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    results =
      1..30
      |> Task.async_stream(
        fn index ->
          ReviewJudgeRegistry.record(path, %{
            "id" => "record-#{index}",
            "issue" => %{"identifier" => "ISSUE-#{index}"},
            "status" => "active"
          })
        end,
        max_concurrency: 30,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %ReviewJudgeRegistry.Record{}}}, &1))

    assert {:ok, registry} = ReviewJudgeRegistry.load(path)

    record_ids = MapSet.new(registry.records, & &1.id)

    assert record_ids == MapSet.new(1..30, &"record-#{&1}")
  end
end
