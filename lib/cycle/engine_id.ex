defmodule Cycle.EngineId do
  @moduledoc """
  Parser and formatter for Cycle engine ids.

  Engine ids use `name@ref`, for example `openai-symphony@main`.
  """

  @type t :: %{name: String.t(), ref: String.t(), id: String.t()}

  @name_re ~r/^[a-z][a-z0-9-]*$/
  @ref_re ~r/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/

  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(value) when is_binary(value) do
    case String.split(value, "@", parts: 3) do
      [name, ref] ->
        with :ok <- validate_name(name),
             :ok <- validate_ref(ref) do
          {:ok, %{name: name, ref: ref, id: format(name, ref)}}
        end

      _ ->
        {:error, "engine id must use name@ref"}
    end
  end

  def parse(_value), do: {:error, "engine id must be a string"}

  @spec format(String.t(), String.t()) :: String.t()
  def format(name, ref), do: "#{name}@#{ref}"

  defp validate_name(name) do
    if Regex.match?(@name_re, name) do
      :ok
    else
      {:error, "engine name must contain lowercase letters, numbers, and hyphens"}
    end
  end

  defp validate_ref(ref) do
    cond do
      ref == "" ->
        {:error, "engine ref must be non-empty"}

      String.contains?(ref, ["..", "//"]) ->
        {:error, "engine ref must not contain path traversal or empty path segments"}

      String.starts_with?(ref, ["/", "."]) or String.ends_with?(ref, ["/", "."]) ->
        {:error, "engine ref must not start or end with a path separator or dot"}

      Regex.match?(@ref_re, ref) ->
        :ok

      true ->
        {:error, "engine ref contains invalid characters"}
    end
  end
end
