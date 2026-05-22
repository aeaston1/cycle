defmodule Cycle.API.Router do
  @moduledoc """
  Read-only localhost JSON API for Cycle status consumers.
  """

  use Plug.Router

  alias Cycle.API.Serializers
  alias Cycle.Config
  alias Cycle.StatusSnapshot

  plug(:match)
  plug(:dispatch)

  get "/health" do
    json(conn, 200, %{"status" => "ok", "version" => Cycle.Version.current()})
  end

  get "/api/v1/status" do
    with {:ok, config} <- load_config(conn) do
      json(conn, 200, StatusSnapshot.from_config(config, api_get: fn _url, _opts -> :skip end))
    end
  end

  get "/api/v1/projects" do
    with {:ok, config} <- load_config(conn) do
      json(conn, 200, %{"projects" => Serializers.projects(config)})
    end
  end

  get "/api/v1/engines" do
    with {:ok, config} <- load_config(conn) do
      json(conn, 200, %{"engines" => Serializers.engines(config)})
    end
  end

  get "/api/v1/runs" do
    with {:ok, config} <- load_config(conn) do
      json(conn, 200, %{"runs" => Serializers.runs(config)})
    end
  end

  get "/api/v1/runs/:id" do
    with {:ok, config} <- load_config(conn) do
      case Enum.find(Serializers.runs(config), &(&1["id"] == id)) do
        nil -> json(conn, 404, %{"error" => %{"code" => "run_not_found", "id" => id}})
        run -> json(conn, 200, run)
      end
    end
  end

  get "/api/v1/logs" do
    with {:ok, config} <- load_config(conn) do
      json(conn, 200, Serializers.logs(config))
    end
  end

  match _ do
    json(conn, 404, %{"error" => %{"code" => "not_found"}})
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)

    Bandit.child_spec(bandit_opts(config))
  end

  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)

    Bandit.start_link(bandit_opts(config))
  end

  defp bandit_opts(config) do
    bind = get_in(config.service, ["api", "bind"]) || "127.0.0.1"
    port = get_in(config.service, ["api", "port"]) || 4765

    [
      plug: {__MODULE__, config: config},
      scheme: :http,
      ip: parse_ip!(bind),
      port: port
    ]
  end

  defp parse_ip!("localhost"), do: {127, 0, 0, 1}

  defp parse_ip!(bind) do
    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, address} -> address
      {:error, _reason} -> raise ArgumentError, "invalid service.api.bind: #{inspect(bind)}"
    end
  end

  defp load_config(conn) do
    case conn.private[:cycle_config] do
      %Config{} = config -> {:ok, config}
      _ -> Config.load()
    end
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn =
      case Keyword.get(opts, :config) do
        %Config{} = config -> put_private(conn, :cycle_config, config)
        _ -> conn
      end

    super(conn, opts)
  end
end
