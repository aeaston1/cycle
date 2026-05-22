defmodule Cycle.Service.TemplateTest do
  use ExUnit.Case, async: true

  alias Cycle.Service.Template

  @fields %{
    executable_path: "/opt/cycle/bin/cycle",
    config_path: "/home/operator/.config/cycle/config.yaml",
    state_path: "/home/operator/.local/share/cycle",
    log_path: "/home/operator/.local/share/cycle/logs/cycle.log",
    env_file_path: "/home/operator/.config/cycle/cycle.env"
  }

  test "renders launchd plist with install-time paths" do
    assert {:ok, rendered} = Template.render(:launchd, @fields)

    assert rendered =~ "<plist version=\"1.0\">"
    assert rendered =~ "<string>/opt/cycle/bin/cycle</string>"
    assert rendered =~ "<string>/home/operator/.config/cycle/config.yaml</string>"
    assert rendered =~ "<string>/home/operator/.local/share/cycle</string>"
    assert rendered =~ "<string>/home/operator/.local/share/cycle/logs/cycle.log</string>"
    assert rendered =~ "<string>/home/operator/.config/cycle/cycle.env</string>"
    assert rendered =~ "<key>RunAtLoad</key>\n  <false/>"
  end

  test "renders systemd unit with install-time paths" do
    assert {:ok, rendered} = Template.render(:systemd, @fields)

    assert rendered =~ "[Unit]"
    assert rendered =~ "EnvironmentFile=/home/operator/.config/cycle/cycle.env"

    assert rendered =~
             "ExecStart=/opt/cycle/bin/cycle start --config /home/operator/.config/cycle/config.yaml --state /home/operator/.local/share/cycle"

    assert rendered =~
             "StandardOutput=append:/home/operator/.local/share/cycle/logs/cycle.log"

    assert rendered =~ "Restart=no"
  end

  test "missing required field returns a clear error" do
    fields = Map.delete(@fields, :state_path)

    assert Template.render(:systemd, fields) ==
             {:error, "missing required service template fields: state_path"}
  end

  test "rendered templates contain no placeholder tokens" do
    assert {:ok, launchd} = Template.render(:launchd, @fields)
    assert {:ok, systemd} = Template.render(:systemd, @fields)

    refute placeholder?(launchd)
    refute placeholder?(systemd)
  end

  test "secret values are rejected when rendering templates" do
    secret = "lin_secret_value"
    fields = Map.put(@fields, :env_file_path, "/home/operator/.config/cycle/cycle.env")

    assert {:ok, rendered} = Template.render(:systemd, fields, secrets: [secret])
    refute rendered =~ secret

    leaking_fields = Map.put(fields, :config_path, secret)

    assert Template.render(:systemd, leaking_fields, secrets: [secret]) ==
             {:error, "rendered service template contains a secret value"}
  end

  defp placeholder?(rendered), do: Regex.match?(~r/<%|%>|__[^_\s]+__|\{\{|\}\}/, rendered)
end
