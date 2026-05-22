defmodule Cycle.EngineRegistry do
  @moduledoc """
  Versioned schemas for Cycle engine registry and engine lock files.
  """

  alias Cycle.Registry.Schema
  alias Cycle.Registry.Store

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
  @health_states ["unknown", "healthy", "unhealthy", "missing", "invalid"]

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

  def read(path) when is_binary(path) do
    with {:ok, raw} <-
           Store.read(path, %{"schema_version" => Schema.schema_version(), @records_key => []}) do
      from_map(raw)
    end
  end

  def write(path, %__MODULE__{} = registry) when is_binary(path) do
    Store.write(path, to_map(registry))
  end

  def read_lock(path) when is_binary(path) do
    with {:ok, raw} <-
           Store.read(path, %{"schema_version" => Schema.schema_version(), @locks_key => []}) do
      lock_from_map(raw)
    end
  end

  def write_lock(path, %LockRegistry{} = registry) when is_binary(path) do
    Store.write(path, lock_to_map(registry))
  end

  def default_record(config, engine_id) do
    managed = get_in(config.engines, ["managed", engine_id.name]) || %{}
    install_path = install_path(config, engine_id)

    %Engine{
      id: engine_id.id,
      name: engine_id.name,
      source: managed["repo"],
      ref: engine_id.ref,
      install_path: install_path,
      capabilities: %{
        "adapter" => "symphony",
        "workflow_schema" => "symphony.v1",
        "status_api" => false,
        "runtime_commands" => ["git", "codex", "mise"],
        "policy" => %{"approval_policy" => true, "sandbox" => true}
      },
      health: %{"state" => health_state(install_path)},
      capacity: %{"max_concurrent_runs" => get_in(config.scheduler, ["max_concurrent_runs"])}
    }
  end

  def install_path(config, engine_id) do
    install_root = get_in(config.engines, ["install_root"]) || config.paths.engines_dir
    Path.join([install_root, engine_id.name, engine_id.ref])
  end

  def upsert(%__MODULE__{} = registry, %Engine{} = engine) do
    engines =
      registry.engines
      |> Enum.reject(&(&1.id == engine.id))
      |> Kernel.++([engine])

    %{registry | engines: engines}
  end

  def upsert_lock(%LockRegistry{} = registry, %Lock{} = lock) do
    locks =
      registry.locks
      |> Enum.reject(&(&1.name == lock.name and &1.ref == lock.ref))
      |> Kernel.++([lock])

    %{registry | locks: locks}
  end

  def find(%__MODULE__{} = registry, engine_id) do
    Enum.find(registry.engines, &(&1.id == engine_id.id))
  end

  def lock_for(%LockRegistry{} = registry, engine_id) do
    Enum.find(registry.locks, &(&1.name == engine_id.name and &1.ref == engine_id.ref))
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
    |> Kernel.++(validate_id(engine, path))
    |> Kernel.++(validate_health(engine["health"], "#{path}.health"))
    |> Kernel.++(validate_source(engine["source"], "#{path}.source"))
  end

  defp validate_id(engine, path) do
    with id when is_binary(id) <- engine["id"],
         name when is_binary(name) <- engine["name"],
         ref when is_binary(ref) <- engine["ref"],
         {:ok, parsed} <- Cycle.EngineId.parse(id),
         true <- parsed.name == name and parsed.ref == ref do
      []
    else
      {:error, reason} -> [Schema.error("#{path}.id", reason)]
      false -> [Schema.error("#{path}.id", "must match name and ref")]
      _ -> []
    end
  end

  defp validate_source(source, path) when is_binary(source) do
    uri = URI.parse(source)

    cond do
      uri.userinfo ->
        [Schema.error(path, "must not contain credentials")]

      uri.scheme in ["http", "https", "git", "ssh"] and is_binary(uri.host) ->
        []

      uri.scheme == "file" and is_binary(uri.path) and uri.path != "" ->
        []

      Path.type(source) == :absolute ->
        []

      true ->
        [Schema.error(path, "must be a git repository URL or absolute path")]
    end
  end

  defp validate_source(_source, _path), do: []

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

  defp health_state(path) do
    if File.dir?(Path.join(path, ".git")), do: "healthy", else: "missing"
  end
end
