defmodule Cycle.Linear.Client do
  @moduledoc """
  Minimal Cycle-owned Linear GraphQL client.

  The client keeps Linear API access behind typed return values so schedulers,
  discovery, and review policy code can distinguish transport, auth, GraphQL,
  decode, and rate-limit failures without exiting the process.
  """

  alias Cycle.Config

  defmodule Project do
    @moduledoc "Linear project fields used by Cycle discovery."
    defstruct [:id, :name, :slug_id, :url, :description, :content]
    @type t :: %__MODULE__{}
  end

  defmodule Issue do
    @moduledoc "Linear issue fields used by Cycle scheduling."
    defstruct [
      :id,
      :identifier,
      :title,
      :url,
      :state,
      :state_type,
      :branch_name,
      :assignee_id,
      :assignee_name,
      :assignee_email,
      :labels,
      :blocks,
      :priority,
      :priority_label,
      :created_at,
      :updated_at,
      :project_id,
      :team_id
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Comment do
    @moduledoc "Linear issue comment fields used by Cycle workpads."
    defstruct [:id, :body, :url, :created_at, :updated_at, :user_name]
    @type t :: %__MODULE__{}
  end

  defstruct endpoint: "https://api.linear.app/graphql",
            token: nil,
            token_env: "LINEAR_API_KEY",
            req_options: []

  @type t :: %__MODULE__{}
  @type error ::
          {:auth, :missing_token, String.t()}
          | {:http, non_neg_integer(), term()}
          | {:transport, String.t()}
          | {:graphql, [map()]}
          | {:decode, String.t()}
          | {:rate_limit, non_neg_integer(), term()}

  @default_page_size 100

  @doc """
  Builds a client from Cycle config or keyword options.

  Options override config values and are intentionally explicit for tests.
  """
  def new(config_or_opts \\ [])

  def new(%Config{} = config) do
    token_env = get_in(config.linear, ["api_key_env"]) || "LINEAR_API_KEY"

    %__MODULE__{
      endpoint: get_in(config.linear, ["endpoint"]) || "https://api.linear.app/graphql",
      token: config.secrets["linear_api_key"] || System.get_env(token_env),
      token_env: token_env,
      req_options: Application.get_env(:cycle, :linear_req_options, [])
    }
  end

  def new(opts) when is_list(opts) do
    token_env = Keyword.get(opts, :token_env, "LINEAR_API_KEY")

    %__MODULE__{
      endpoint: Keyword.get(opts, :endpoint, "https://api.linear.app/graphql"),
      token: Keyword.get(opts, :token, System.get_env(token_env)),
      token_env: token_env,
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  def list_projects(%__MODULE__{} = client, opts \\ []) do
    paginate(client, project_query(), %{}, [:projects], &decode_project/1, opts)
  end

  def list_issues(%__MODULE__{} = client, project_id, state_names, opts \\ [])
      when is_binary(project_id) and is_list(state_names) do
    variables = %{"projectId" => project_id, "stateNames" => state_names}
    paginate(client, issues_query(), variables, [:issues], &decode_issue/1, opts)
  end

  def refresh_issue(%__MODULE__{} = client, issue_id) when is_binary(issue_id) do
    with {:ok, payload} <- request(client, refresh_issue_query(), %{"id" => issue_id}),
         {:ok, node} <- fetch_path(payload, ["data", "issue"]) do
      {:ok, decode_issue(node)}
    end
  end

  def list_comments(%__MODULE__{} = client, issue_id, opts \\ []) when is_binary(issue_id) do
    variables = %{"issueId" => issue_id}

    with {:ok, payload} <-
           request(client, comments_query(), Map.put(variables, "first", page_size(opts))) do
      case get_in(payload, ["data", "issue"]) do
        nil -> {:error, {:decode, "response missing data.issue"}}
        _ -> paginate_comments(client, variables, payload, opts)
      end
    end
  end

  def create_comment(%__MODULE__{} = client, issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    variables = %{"issueId" => issue_id, "body" => body}

    with {:ok, payload} <- request(client, create_comment_mutation(), variables),
         {:ok, node} <- fetch_path(payload, ["data", "commentCreate", "comment"]) do
      {:ok, decode_comment(node)}
    end
  end

  def update_issue_state(%__MODULE__{} = client, issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, issue} <- refresh_issue(client, issue_id),
         true <- present?(issue.team_id) || {:error, {:decode, "issue missing team id"}},
         {:ok, state_id} <- state_id_by_name(client, issue.team_id, state_name),
         {:ok, payload} <-
           request(client, update_issue_state_mutation(), %{
             "issueId" => issue_id,
             "stateId" => state_id
           }),
         {:ok, node} <- fetch_path(payload, ["data", "issueUpdate", "issue"]) do
      {:ok, decode_issue(node)}
    end
  end

  defp state_id_by_name(client, team_id, state_name) do
    with {:ok, payload} <-
           request(client, state_by_name_query(), %{
             "teamId" => team_id,
             "stateName" => state_name
           }),
         {:ok, nodes} <- fetch_path(payload, ["data", "workflowStates", "nodes"]) do
      case nodes do
        [%{"id" => id} | _] when is_binary(id) -> {:ok, id}
        _ -> {:error, {:decode, "state not found: #{state_name}"}}
      end
    end
  end

  defp paginate(client, query, base_variables, connection_path, decoder, opts) do
    page_size = page_size(opts)

    collect_pages(client, query, base_variables, connection_path, decoder, page_size, nil, [])
  end

  defp collect_pages(
         client,
         query,
         base_variables,
         connection_path,
         decoder,
         page_size,
         cursor,
         acc
       ) do
    variables =
      base_variables
      |> Map.put("first", page_size)
      |> Map.put("after", cursor)

    with {:ok, payload} <- request(client, query, variables),
         {:ok, connection} <-
           fetch_path(payload, ["data" | Enum.map(connection_path, &to_string/1)]),
         {:ok, nodes} <- fetch_path(connection, ["nodes"]),
         {:ok, page_info} <- fetch_path(connection, ["pageInfo"]) do
      next = page_info["endCursor"]
      results = acc ++ Enum.map(nodes, decoder)

      if page_info["hasNextPage"] do
        collect_pages(
          client,
          query,
          base_variables,
          connection_path,
          decoder,
          page_size,
          next,
          results
        )
      else
        {:ok, results}
      end
    end
  end

  defp paginate_comments(client, base_variables, first_payload, opts) do
    with {:ok, connection} <- fetch_path(first_payload, ["data", "issue", "comments"]),
         {:ok, nodes} <- fetch_path(connection, ["nodes"]),
         {:ok, page_info} <- fetch_path(connection, ["pageInfo"]) do
      comments = Enum.map(nodes, &decode_comment/1)

      if page_info["hasNextPage"] do
        collect_comment_pages(
          client,
          base_variables,
          page_size(opts),
          page_info["endCursor"],
          comments
        )
      else
        {:ok, comments}
      end
    end
  end

  defp collect_comment_pages(client, base_variables, page_size, cursor, acc) do
    variables =
      base_variables
      |> Map.put("first", page_size)
      |> Map.put("after", cursor)

    with {:ok, payload} <- request(client, comments_query(), variables),
         {:ok, connection} <- fetch_path(payload, ["data", "issue", "comments"]),
         {:ok, nodes} <- fetch_path(connection, ["nodes"]),
         {:ok, page_info} <- fetch_path(connection, ["pageInfo"]) do
      comments = acc ++ Enum.map(nodes, &decode_comment/1)

      if page_info["hasNextPage"] do
        collect_comment_pages(client, base_variables, page_size, page_info["endCursor"], comments)
      else
        {:ok, comments}
      end
    end
  end

  defp request(%__MODULE__{token: token, token_env: token_env}, _query, _variables)
       when not is_binary(token) or token == "" do
    {:error, {:auth, :missing_token, token_env}}
  end

  defp request(%__MODULE__{} = client, query, variables) do
    body = Jason.encode!(%{query: query, variables: variables})

    req_options =
      Keyword.merge(
        [
          headers: [
            {"authorization", client.token},
            {"content-type", "application/json"}
          ],
          body: body,
          retry: false
        ],
        client.req_options
      )

    case Req.post(client.endpoint, req_options) do
      {:ok, %{status: 429, body: response_body}} ->
        {:error, {:rate_limit, 429, response_body}}

      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        decode_response(response_body)

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:http, status, response_body}}

      {:error, error} ->
        {:error, {:transport, Exception.message(error)}}
    end
  end

  defp decode_response(response) when is_map(response) do
    if is_list(response["errors"]),
      do: {:error, {:graphql, response["errors"]}},
      else: {:ok, response}
  end

  defp decode_response(response) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, payload} -> decode_response(payload)
      {:error, error} -> {:error, {:decode, Exception.message(error)}}
    end
  end

  defp decode_response(_response), do: {:error, {:decode, "response body is not JSON"}}

  defp fetch_path(payload, path) do
    case get_in(payload, path) do
      nil -> {:error, {:decode, "response missing #{Enum.join(path, ".")}"}}
      value -> {:ok, value}
    end
  end

  defp decode_project(project) do
    %Project{
      id: project["id"],
      name: project["name"],
      slug_id: project["slugId"],
      url: project["url"],
      description: project["description"],
      content: project["content"]
    }
  end

  defp decode_issue(issue) do
    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      url: issue["url"],
      state: get_in(issue, ["state", "name"]),
      state_type: get_in(issue, ["state", "type"]),
      branch_name: issue["branchName"],
      assignee_id: get_in(issue, ["assignee", "id"]),
      assignee_name: get_in(issue, ["assignee", "name"]),
      assignee_email: get_in(issue, ["assignee", "email"]),
      labels: issue |> get_in(["labels", "nodes"]) |> decode_label_names(),
      blocks: issue |> get_in(["inverseRelations", "nodes"]) |> decode_blockers(),
      priority: issue["priority"],
      priority_label: issue["priorityLabel"],
      created_at: issue["createdAt"],
      updated_at: issue["updatedAt"],
      project_id: get_in(issue, ["project", "id"]),
      team_id: get_in(issue, ["team", "id"])
    }
  end

  defp decode_label_names(nil), do: []

  defp decode_label_names(labels) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.filter(&present?/1)
  end

  defp decode_label_names(_labels), do: []

  defp decode_blockers(nil), do: []

  defp decode_blockers(relations) when is_list(relations) do
    Enum.flat_map(relations, fn
      %{"type" => relation_type, "issue" => blocker} when is_map(blocker) ->
        if String.downcase(String.trim(relation_type || "")) == "blocks" do
          [
            %{
              "id" => blocker["id"],
              "identifier" => blocker["identifier"],
              "title" => blocker["title"],
              "url" => blocker["url"],
              "state" => get_in(blocker, ["state", "name"]),
              "state_type" => get_in(blocker, ["state", "type"])
            }
          ]
        else
          []
        end

      _relation ->
        []
    end)
  end

  defp decode_blockers(_blockers), do: []

  defp decode_comment(comment) do
    %Comment{
      id: comment["id"],
      body: comment["body"],
      url: comment["url"],
      created_at: comment["createdAt"],
      updated_at: comment["updatedAt"],
      user_name: get_in(comment, ["user", "name"])
    }
  end

  defp page_size(opts), do: Keyword.get(opts, :page_size, @default_page_size)
  defp present?(value), do: is_binary(value) and value != ""

  defp project_query do
    """
    query CycleListProjects($first: Int!, $after: String) {
      projects(first: $first, after: $after) {
        nodes {
          id
          name
          slugId
          url
          description
          content
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """
  end

  defp issues_query do
    """
    query CycleListIssues($projectId: String!, $stateNames: [String!], $first: Int!, $after: String) {
      issues(
        first: $first
        after: $after
        filter: {
          project: { id: { eq: $projectId } }
          state: { name: { in: $stateNames } }
        }
      ) {
        nodes {
          id
          identifier
          title
          url
          branchName
          priority
          priorityLabel
          createdAt
          updatedAt
          state { name type }
          assignee { id name }
          labels { nodes { name } }
          inverseRelations(first: 50) {
            nodes {
              type
              issue {
                id
                identifier
                title
                url
                state { name type }
              }
            }
          }
          project { id }
          team { id }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """
  end

  defp refresh_issue_query do
    """
    query CycleRefreshIssue($id: String!) {
      issue(id: $id) {
        id
        identifier
        title
        url
        branchName
        priority
        priorityLabel
        createdAt
        updatedAt
        state { name type }
        assignee { id name }
        labels { nodes { name } }
        inverseRelations(first: 50) {
          nodes {
            type
            issue {
              id
              identifier
              title
              url
              state { name type }
            }
          }
        }
        project { id }
        team { id }
      }
    }
    """
  end

  defp comments_query do
    """
    query CycleIssueComments($issueId: String!, $first: Int!, $after: String) {
      issue(id: $issueId) {
        comments(first: $first, after: $after) {
          nodes {
            id
            body
            url
            createdAt
            updatedAt
            user { name }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
    """
  end

  defp create_comment_mutation do
    """
    mutation CycleCreateComment($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) {
        comment {
          id
          body
          url
          createdAt
          updatedAt
          user { name }
        }
      }
    }
    """
  end

  defp state_by_name_query do
    """
    query CycleStateByName($teamId: String!, $stateName: String!) {
      workflowStates(first: 1, filter: { team: { id: { eq: $teamId } }, name: { eq: $stateName } }) {
        nodes { id }
      }
    }
    """
  end

  defp update_issue_state_mutation do
    """
    mutation CycleUpdateIssueState($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: { stateId: $stateId }) {
        issue {
          id
          identifier
          title
          url
          branchName
          priority
          priorityLabel
          createdAt
          updatedAt
          state { name type }
          assignee { id name }
          labels { nodes { name } }
          inverseRelations(first: 50) {
            nodes {
              type
              issue {
                id
                identifier
                title
                url
                state { name type }
              }
            }
          }
          project { id }
          team { id }
        }
      }
    }
    """
  end
end
