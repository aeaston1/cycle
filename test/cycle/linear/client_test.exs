defmodule Cycle.Linear.ClientTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Cycle.Linear.Client
  alias Cycle.Linear.Client.{Comment, Issue, Project}

  test "list_projects sends authorized GraphQL request and decodes project fields" do
    name = unique_stub()

    Req.Test.stub(name, fn conn ->
      assert conn.method == "POST"
      assert get_req_header(conn, "authorization") == ["lin_test"]

      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      assert payload["query"] =~ "query CycleListProjects"
      assert payload["variables"] == %{"after" => nil, "first" => 100}

      Req.Test.json(conn, %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{
                "id" => "project-id",
                "name" => "Cycle",
                "slugId" => "CYC",
                "url" => "https://linear.app/example/project/cyc",
                "description" => "description",
                "content" => "cycle:\n  enabled: true"
              }
            ],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      })
    end)

    client = client(name)

    assert {:ok,
            [
              %Project{
                id: "project-id",
                name: "Cycle",
                slug_id: "CYC",
                url: "https://linear.app/example/project/cyc",
                description: "description",
                content: "cycle:\n  enabled: true"
              }
            ]} = Client.list_projects(client)
  end

  test "list_projects follows pagination" do
    name = unique_stub()
    parent = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      variables = Jason.decode!(body)["variables"]
      send(parent, {:variables, variables})

      case variables["after"] do
        nil ->
          Req.Test.json(conn, %{
            "data" => %{
              "projects" => %{
                "nodes" => [%{"id" => "one"}],
                "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
              }
            }
          })

        "cursor-1" ->
          Req.Test.json(conn, %{
            "data" => %{
              "projects" => %{
                "nodes" => [%{"id" => "two"}],
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
              }
            }
          })
      end
    end)

    assert {:ok, [%Project{id: "one"}, %Project{id: "two"}]} =
             Client.list_projects(client(name), page_size: 1)

    assert_received {:variables, %{"after" => nil, "first" => 1}}
    assert_received {:variables, %{"after" => "cursor-1", "first" => 1}}
  end

  test "list_issues filters by project id and state names" do
    name = unique_stub()
    parent = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)
      send(parent, payload)

      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [
              %{
                "id" => "issue-id",
                "identifier" => "CYC-1",
                "title" => "Build client",
                "url" => "https://linear.app/example/issue/CYC-1",
                "state" => %{"name" => "Todo"},
                "project" => %{"id" => "project-id"},
                "team" => %{"id" => "team-id"}
              }
            ],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      })
    end)

    assert {:ok, [%Issue{id: "issue-id", identifier: "CYC-1", state: "Todo"}]} =
             Client.list_issues(client(name), "project-id", ["Todo", "Rework"])

    assert_received %{
      "query" => query,
      "variables" => %{
        "projectId" => "project-id",
        "stateNames" => ["Todo", "Rework"]
      }
    }

    assert query =~ "project: { id: { eq: $projectId } }"
    assert query =~ "state: { name: { in: $stateNames } }"
  end

  test "refresh_issue fetches by raw Linear id" do
    name = unique_stub()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["variables"]["id"] == "raw-issue-id"

      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "id" => "raw-issue-id",
            "identifier" => "CYC-2",
            "title" => "Refresh",
            "url" => "https://linear.app/example/issue/CYC-2",
            "state" => %{"name" => "In Progress"},
            "project" => %{"id" => "project-id"},
            "team" => %{"id" => "team-id"}
          }
        }
      })
    end)

    assert {:ok, %Issue{id: "raw-issue-id", team_id: "team-id"}} =
             Client.refresh_issue(client(name), "raw-issue-id")
  end

  test "list_comments decodes issue comments" do
    name = unique_stub()

    Req.Test.stub(name, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "comments" => %{
              "nodes" => [
                %{
                  "id" => "comment-id",
                  "body" => "workpad",
                  "url" => "https://linear.app/example/comment/comment-id",
                  "createdAt" => "2026-05-22T00:00:00.000Z",
                  "updatedAt" => "2026-05-22T00:00:00.000Z",
                  "user" => %{"name" => "Cycle"}
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      })
    end)

    assert {:ok, [%Comment{id: "comment-id", body: "workpad", user_name: "Cycle"}]} =
             Client.list_comments(client(name), "issue-id")
  end

  test "create_comment preserves raw issue id and body in mutation variables" do
    name = unique_stub()
    parent = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)
      send(parent, payload)

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "comment" => %{
              "id" => "comment-id",
              "body" => "sensitive body",
              "url" => "https://linear.app/example/comment/comment-id",
              "createdAt" => "2026-05-22T00:00:00.000Z",
              "updatedAt" => "2026-05-22T00:00:00.000Z",
              "user" => %{"name" => "Cycle"}
            }
          }
        }
      })
    end)

    assert {:ok, %Comment{id: "comment-id"}} =
             Client.create_comment(client(name), "raw-issue-id", "sensitive body")

    assert_received %{
      "query" => query,
      "variables" => %{"issueId" => "raw-issue-id", "body" => "sensitive body"}
    }

    assert query =~ "mutation CycleCreateComment"
  end

  test "update_issue_state resolves state by name and writes raw state id" do
    name = unique_stub()
    parent = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)
      send(parent, payload)

      cond do
        payload["query"] =~ "query CycleRefreshIssue" ->
          Req.Test.json(conn, %{
            "data" => %{
              "issue" => %{
                "id" => "issue-id",
                "identifier" => "CYC-3",
                "title" => "Update state",
                "url" => "https://linear.app/example/issue/CYC-3",
                "state" => %{"name" => "Todo"},
                "project" => %{"id" => "project-id"},
                "team" => %{"id" => "team-id"}
              }
            }
          })

        payload["query"] =~ "query CycleStateByName" ->
          Req.Test.json(conn, %{
            "data" => %{"workflowStates" => %{"nodes" => [%{"id" => "state-id"}]}}
          })

        payload["query"] =~ "mutation CycleUpdateIssueState" ->
          Req.Test.json(conn, %{
            "data" => %{
              "issueUpdate" => %{
                "issue" => %{
                  "id" => "issue-id",
                  "identifier" => "CYC-3",
                  "title" => "Update state",
                  "url" => "https://linear.app/example/issue/CYC-3",
                  "state" => %{"name" => "In Progress"},
                  "project" => %{"id" => "project-id"},
                  "team" => %{"id" => "team-id"}
                }
              }
            }
          })
      end
    end)

    assert {:ok, %Issue{id: "issue-id", state: "In Progress"}} =
             Client.update_issue_state(client(name), "issue-id", "In Progress")

    assert_received %{"variables" => %{"id" => "issue-id"}}
    assert_received %{"variables" => %{"teamId" => "team-id", "stateName" => "In Progress"}}
    assert_received %{"variables" => %{"issueId" => "issue-id", "stateId" => "state-id"}}
  end

  test "missing auth token is distinguishable before HTTP" do
    assert {:error, {:auth, :missing_token, "CUSTOM_LINEAR_TOKEN"}} =
             Client.list_projects(Client.new(token: nil, token_env: "CUSTOM_LINEAR_TOKEN"))
  end

  test "GraphQL, decode, HTTP, and rate-limit errors are distinguishable" do
    assert {:error, {:graphql, [%{"message" => "bad query"}]}} =
             request_error(%{"errors" => [%{"message" => "bad query"}]}, 200)

    assert {:error, {:decode, _}} = request_error("not json", 200)
    assert {:error, {:http, 500, _}} = request_error(%{"error" => "server"}, 500)
    assert {:error, {:rate_limit, 429, _}} = request_error(%{"error" => "slow down"}, 429)
  end

  defp request_error(body, status) do
    name = unique_stub()

    Req.Test.stub(name, fn conn ->
      encoded = if is_binary(body), do: body, else: Jason.encode!(body)
      send_resp(conn, status, encoded)
    end)

    Client.list_projects(client(name))
  end

  defp client(name) do
    Client.new(token: "lin_test", req_options: [plug: {Req.Test, name}])
  end

  defp unique_stub do
    :"linear-client-test-#{System.unique_integer([:positive])}"
  end
end
