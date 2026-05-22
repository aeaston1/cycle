defmodule Cycle.GlobalPolicy do
  @moduledoc """
  Operator-owned global policy used to classify discovered project workflows.
  """

  alias Cycle.PolicyDrift
  alias Cycle.WorkflowPolicy

  @default_enforcement "report"
  @default_propagation "manual"
  @valid_enforcement ["report", "block"]

  defstruct enforcement: @default_enforcement,
            required: %{},
            propagation: "manual"

  defmodule Result do
    @moduledoc false
    defstruct status: "valid", drift: []
  end

  @type t :: %__MODULE__{
          enforcement: String.t(),
          required: map(),
          propagation: String.t() | nil
        }

  @spec from_config(Cycle.Config.t() | map()) :: {:ok, t()} | {:error, [map()]}
  def from_config(%Cycle.Config{} = config), do: from_config(Map.from_struct(config))

  def from_config(config) when is_map(config) do
    policy = Map.get(config, :policy) || Map.get(config, "policy") || %{}
    required = Map.get(policy, "required", %{})
    enforcement = Map.get(policy, "enforcement", @default_enforcement)
    propagation = get_in(policy, ["drift", "propagation"]) || @default_propagation

    errors =
      []
      |> validate_enforcement(enforcement)
      |> validate_required(required)

    if errors == [] do
      {:ok, %__MODULE__{enforcement: enforcement, required: required, propagation: propagation}}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @spec classify(t(), WorkflowPolicy.t()) :: Result.t()
  def classify(%__MODULE__{} = global_policy, %WorkflowPolicy{} = workflow_policy) do
    drift =
      global_policy.required
      |> flatten_required()
      |> Enum.flat_map(&drift_for(&1, global_policy, workflow_policy))

    %Result{status: status_for(drift), drift: drift}
  end

  defp validate_enforcement(errors, enforcement) when enforcement in @valid_enforcement,
    do: errors

  defp validate_enforcement(errors, _enforcement),
    do: [%{path: "policy.enforcement", reason: "must be report or block"} | errors]

  defp validate_required(errors, required) when is_map(required), do: errors

  defp validate_required(errors, _required),
    do: [%{path: "policy.required", reason: "must be a mapping"} | errors]

  defp flatten_required(required) do
    required
    |> do_flatten([])
    |> Enum.sort_by(fn {path, _desired} -> path end)
  end

  defp do_flatten(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> do_flatten(value, prefix ++ [to_string(key)]) end)
  end

  defp do_flatten(value, prefix), do: [{Enum.join(prefix, "."), value}]

  defp drift_for({path, desired}, global_policy, workflow_policy) do
    observed_path = workflow_path(path)
    observed = get_path(workflow_policy, observed_path)

    if observed == desired do
      []
    else
      [
        %PolicyDrift{
          path: observed_path,
          desired: desired,
          observed: observed,
          severity: severity(global_policy.enforcement),
          propagation_available: propagation_available?(global_policy)
        }
      ]
    end
  end

  defp workflow_path("capacity." <> rest), do: "agent." <> rest
  defp workflow_path("engine." <> rest), do: "engine." <> rest
  defp workflow_path(path), do: path

  defp get_path(%WorkflowPolicy{} = workflow_policy, path) do
    workflow_policy
    |> policy_to_map()
    |> get_in(String.split(path, "."))
  end

  defp policy_to_map(%WorkflowPolicy{} = policy) do
    %{
      "agent" => policy.agent,
      "codex" => policy.codex,
      "engine" => policy.engine,
      "review_judge" => policy.review_judge,
      "worker" => policy.worker
    }
  end

  defp severity("block"), do: "blocking"
  defp severity(_mode), do: "info"

  defp propagation_available?(%__MODULE__{propagation: propagation}),
    do: propagation in ["manual", "available"]

  defp status_for([]), do: "valid"
  defp status_for(_drift), do: "drift"
end
