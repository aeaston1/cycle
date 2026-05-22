defmodule Cycle.Policy.ReviewJudge.Runner do
  @moduledoc """
  Behaviour for review judge model execution.

  Implementations receive a prompt and model configuration and return the raw
  model payload. Tests should use small in-process modules instead of calling
  external models.
  """

  @callback run(String.t(), map()) :: {:ok, map() | String.t()} | {:error, term()}
end
