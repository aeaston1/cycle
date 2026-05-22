defmodule Cycle.Service.Template do
  @moduledoc """
  Renders platform service templates for explicit Cycle service installation.
  """

  require EEx

  @required_fields [
    :executable_path,
    :config_path,
    :state_path,
    :log_path,
    :env_file_path
  ]

  @template_dir Path.expand("../../../templates/service", __DIR__)
  @launchd_template File.read!(Path.join(@template_dir, "launchd.plist.eex"))
  @systemd_template File.read!(Path.join(@template_dir, "cycle.service.eex"))

  @type platform :: :launchd | :systemd
  @type render_field ::
          :executable_path | :config_path | :state_path | :log_path | :env_file_path
  @type render_fields :: %{required(render_field()) => String.t()}
  @type render_option :: {:secrets, [String.t()]}

  @spec render(platform(), render_fields(), [render_option()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def render(platform, fields, opts \\ []) when is_map(fields) do
    with :ok <- validate_platform(platform),
         {:ok, bindings} <- validate_fields(fields),
         {:ok, rendered} <- render_template(platform, bindings),
         :ok <- validate_no_placeholders(rendered),
         :ok <- validate_no_secrets(rendered, Keyword.get(opts, :secrets, [])) do
      {:ok, rendered}
    end
  end

  defp validate_platform(platform) when platform in [:launchd, :systemd], do: :ok
  defp validate_platform(platform), do: {:error, "unknown service template: #{inspect(platform)}"}

  defp validate_fields(fields) do
    missing =
      Enum.filter(@required_fields, fn field ->
        !present?(Map.get(fields, field))
      end)

    case missing do
      [] -> {:ok, Map.take(fields, @required_fields)}
      fields -> {:error, "missing required service template fields: #{join_fields(fields)}"}
    end
  end

  defp render_template(:launchd, bindings),
    do: {:ok, EEx.eval_string(@launchd_template, assigns: bindings)}

  defp render_template(:systemd, bindings),
    do: {:ok, EEx.eval_string(@systemd_template, assigns: bindings)}

  defp validate_no_placeholders(rendered) do
    if Regex.match?(~r/<%|%>|__[^_\s]+__|\{\{|\}\}/, rendered),
      do: {:error, "rendered service template still contains placeholder tokens"},
      else: :ok
  end

  defp validate_no_secrets(rendered, secrets) do
    leaked =
      secrets
      |> List.wrap()
      |> Enum.filter(&present?/1)
      |> Enum.find(&String.contains?(rendered, &1))

    if leaked,
      do: {:error, "rendered service template contains a secret value"},
      else: :ok
  end

  defp join_fields(fields), do: fields |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
  defp present?(value), do: is_binary(value) && String.trim(value) != ""
end
