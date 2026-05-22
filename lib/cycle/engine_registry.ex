defmodule Cycle.EngineRegistry do
  @moduledoc """
  Versioned schemas for Cycle engine registry and engine lock files.
  """

  alias Cycle.Registry.Schema

  @records_key "engines"
  @locks_key "locks"
  @known_engine_keys [
    "id",
    "name",
    "source",
    "ref",
    "install_path",
    "capabilities",
    "health",
    "capacity"
  ]
  @known_lock_keys ["name", "ref", "resolved_revision", "installed_at"]
  @health_states ["unknown", "healthy", "unhealthy", "missing"]

  defstruct schema_version: Schema.schema_version(), engines: [], extra: %{}

  defmodule Engine do
    @moduledoc false
    defstruct id: nil,
              name: nil,
              source: nil,
              ref: nil,
              install_path: nil,
              capabilities: %{},
              health: %{},
              capacity: %{},
              extra: %{}
  end

  defmodule LockRegistry do
    @moduledoc false
    defstruct schema_version: Schema.schema_version(), locks: [], extra: %{}
  end

  defmodule Lock do
    @moduledoc false
    defstruct name: nil, ref: nil, resolved_revision: nil, installed_at: nil, extra: %{}
  end

  def from_map(raw) do
    with {:ok, document} <- Schema.validate_document(raw, @records_key, &validate_engine/2) do
      {:ok,
       %__MODULE__{
         schema_version: document.schema_version,
         engines: Enum.map(document.records, &engine_from_map/1),
         extra: document.extra
       }}
    end
  end

  def validate(raw) do
    case from_map(raw) do
      {:ok, _registry} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  def to_map(%__MODULE__{} = registry) do
    %{
      "schema_version" => registry.schema_version,
      @records_key => Enum.map(registry.engines, &engine_to_map/1)
    }
    |> Schema.put_extra(registry.extra)
  end

  def lock_from_map(raw) do
    with {:ok, document} <- Schema.validate_document(raw, @locks_key, &validate_lock/2) do
      {:ok,
       %LockRegistry{
         schema_version: document.schema_version,
         locks: Enum.map(document.records, &lock_record_from_map/1),
         extra: document.extra
       }}
    end
  end

  def validate_lock_registry(raw) do
    case lock_from_map(raw) do
      {:ok, _registry} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  def lock_to_map(%LockRegistry{} = registry) do
    %{
      "schema_version" => registry.schema_version,
      @locks_key => Enum.map(registry.locks, &lock_record_to_map/1)
    }
    |> Schema.put_extra(registry.extra)
  end

  defp validate_engine(engine, path) do
    [
      Enum.flat_map(
        ["id", "name", "source", "ref", "install_path"],
        &Schema.required_string(engine, &1, path)
      ),
      Schema.optional_map(engine, "capabilities", path),
      Schema.optional_map(engine, "health", path),
      Schema.optional_map(engine, "capacity", path)
    ]
    |> List.flatten()
    |> Kernel.++(validate_health(engine["health"], "#{path}.health"))
  end

  defp validate_health(nil, path), do: [Schema.error(path, "is required")]

  defp validate_health(map, path) when is_map(map) do
    Schema.enum(map, "state", @health_states, path) ++
      Schema.optional_string(map, "checked_at", path)
  end

  defp validate_health(_value, _path), do: []

  defp validate_lock(lock, path) do
    Enum.flat_map(["name", "ref", "resolved_revision"], &Schema.required_string(lock, &1, path)) ++
      Schema.iso8601_utc(lock, "installed_at", path)
  end

  defp engine_from_map(map) do
    %Engine{
      id: map["id"],
      name: map["name"],
      source: map["source"],
      ref: map["ref"],
      install_path: map["install_path"],
      capabilities: Map.get(map, "capabilities", %{}),
      health: map["health"],
      capacity: Map.get(map, "capacity", %{}),
      extra: Schema.preserve_extra(map, @known_engine_keys)
    }
  end

  defp engine_to_map(%Engine{} = engine) do
    %{
      "id" => engine.id,
      "name" => engine.name,
      "source" => engine.source,
      "ref" => engine.ref,
      "install_path" => engine.install_path,
      "capabilities" => engine.capabilities,
      "health" => engine.health,
      "capacity" => engine.capacity
    }
    |> Schema.put_extra(engine.extra)
  end

  defp lock_record_from_map(map) do
    %Lock{
      name: map["name"],
      ref: map["ref"],
      resolved_revision: map["resolved_revision"],
      installed_at: map["installed_at"],
      extra: Schema.preserve_extra(map, @known_lock_keys)
    }
  end

  defp lock_record_to_map(%Lock{} = lock) do
    %{
      "name" => lock.name,
      "ref" => lock.ref,
      "resolved_revision" => lock.resolved_revision,
      "installed_at" => lock.installed_at
    }
    |> Schema.put_extra(lock.extra)
  end
end
