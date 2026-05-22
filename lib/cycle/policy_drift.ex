defmodule Cycle.PolicyDrift do
  @moduledoc """
  Machine-readable global policy drift record for a discovered project workflow.
  """

  @enforce_keys [:path, :desired, :observed, :severity, :propagation_available]
  defstruct [:path, :desired, :observed, :severity, :propagation_available]

  @type t :: %__MODULE__{
          path: String.t(),
          desired: term(),
          observed: term(),
          severity: String.t(),
          propagation_available: boolean()
        }

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = drift) do
    %{
      "path" => drift.path,
      "desired" => drift.desired,
      "observed" => drift.observed,
      "severity" => drift.severity,
      "propagation_available" => drift.propagation_available
    }
  end
end
