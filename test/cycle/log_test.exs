defmodule Cycle.LogTest do
  use ExUnit.Case, async: false

  test "configures the default log path and creates the directory" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      assert {:ok, config} =
               Cycle.Config.load(env: %{"CYCLE_HOME" => cycle_home}, home: cycle_home)

      assert Cycle.Log.path(config) == Path.join([cycle_home, "logs", "cycle.log"])
      assert :ok = Cycle.Log.configure(config)
      assert File.dir?(Path.join(cycle_home, "logs"))
    end)
  end

  test "redacts headers, token-like keys, and token-like values" do
    redacted =
      Cycle.Log.redact(%{
        "Authorization" => "Bearer lin_abcdefghijklmnopqrstuvwxyz123456",
        "message" =>
          "failed with token=lin_abcdefghijklmnopqrstuvwxyz123456 and api_key=secret-value",
        "nested" => %{"refresh_token" => "refresh-secret"}
      })

    encoded = inspect(redacted)
    refute encoded =~ "abcdefghijklmnopqrstuvwxyz123456"
    refute encoded =~ "secret-value"
    refute encoded =~ "refresh-secret"
    assert redacted["Authorization"] == "[REDACTED]"
    assert redacted["nested"]["refresh_token"] == "[REDACTED]"
  end

  test "writes redacted log events to the configured log file" do
    Cycle.TestSupport.with_isolated_cycle_env(%{}, fn %{cycle_home: cycle_home} ->
      assert {:ok, config} =
               Cycle.Config.load(env: %{"CYCLE_HOME" => cycle_home}, home: cycle_home)

      Cycle.Log.log_event(config, :error, "Linear failed", %{
        "Authorization" => "Bearer lin_abcdefghijklmnopqrstuvwxyz123456",
        "project" => "Cycle"
      })

      assert {:ok, body} = File.read(Cycle.Log.path(config))
      assert body =~ "Linear failed"
      assert body =~ "Cycle"
      refute body =~ "abcdefghijklmnopqrstuvwxyz123456"
    end)
  end
end
