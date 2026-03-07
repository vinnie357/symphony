defmodule SymphonyElixir.Backends.AppleSlicerAPITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Backends.AppleSlicerAPI

  # ---------------------------------------------------------------------------
  # Mock Plug server — returns "completed" on every poll (happy path)
  # ---------------------------------------------------------------------------

  defmodule MockServer do
    @moduledoc false
    use Plug.Router

    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    post "/api/symphony/runs" do
      run_id = "run-#{System.unique_integer([:positive])}"

      json_resp(conn, 201, %{
        "run" => %{"id" => run_id, "status" => "pending", "turn_count" => 0}
      })
    end

    post "/api/symphony/runs/:id/turns" do
      json_resp(conn, 202, %{
        "turn" => %{
          "turn_number" => 1,
          "triggered_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "run_id" => id
        }
      })
    end

    get "/api/symphony/runs/:id" do
      json_resp(conn, 200, %{
        "run" => %{
          "id" => id,
          "status" => "completed",
          "turn_count" => 1,
          "session_id" => "sess-abc",
          "codex_input_tokens" => 500,
          "codex_output_tokens" => 200,
          "codex_total_tokens" => 700,
          "runtime_seconds" => 12
        }
      })
    end

    delete "/api/symphony/runs/:id" do
      _ = id
      json_resp(conn, 200, %{"ok" => true})
    end

    match _ do
      send_resp(conn, 404, "not found")
    end

    defp json_resp(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  # ---------------------------------------------------------------------------
  # Configurable mock — reads responses from an ETS table keyed by server ref
  # ---------------------------------------------------------------------------

  defmodule ConfigurableMockServer do
    @moduledoc false
    use Plug.Router

    plug :fetch_query_params
    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    post "/api/symphony/runs" do
      {status, body} = lookup_response(conn, :create_run)
      json_resp(conn, status, body)
    end

    post "/api/symphony/runs/:id/turns" do
      _ = id
      {status, body} = lookup_response(conn, :trigger_turn)
      json_resp(conn, status, body)
    end

    get "/api/symphony/runs/:id" do
      _ = id
      {status, body} = lookup_response(conn, :get_run)
      json_resp(conn, status, body)
    end

    delete "/api/symphony/runs/:id" do
      _ = id
      {status, body} = lookup_response(conn, :delete_run)
      json_resp(conn, status, body)
    end

    match _ do
      send_resp(conn, 404, "not found")
    end

    defp json_resp(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp lookup_response(conn, endpoint) do
      table = conn.private[:mock_table]

      case :ets.lookup(table, endpoint) do
        [{^endpoint, response}] -> response
        [] -> {500, %{"error" => "no mock configured for #{endpoint}"}}
      end
    end
  end

  # Plug wrapper that injects the ETS table ref into conn.private
  defmodule ConfigurableMockPlug do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      table = Keyword.fetch!(opts, :table)

      conn
      |> Plug.Conn.put_private(:mock_table, table)
      |> ConfigurableMockServer.call(ConfigurableMockServer.init([]))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_mock_server(plug) do
    {:ok, server} = Bandit.start_link(plug: plug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base_url = "http://127.0.0.1:#{port}"
    {server, base_url}
  end

  defp start_configurable_server do
    table = :ets.new(:mock_responses, [:set, :public])
    {server, base_url} = start_mock_server({ConfigurableMockPlug, table: table})
    {server, base_url, table}
  end

  defp mock_response(table, endpoint, status, body) do
    :ets.insert(table, {endpoint, {status, body}})
  end

  defp sample_issue do
    %{
      id: "issue-api-test",
      identifier: "VIN-200",
      title: "Test API issue",
      description: "Integration test issue for AppleSlicerAPI",
      state: "Todo",
      url: "https://linear.app/test/VIN-200",
      labels: ["backend-test"],
      assigned_to_worker: true
    }
  end

  defp api_config(base_url) do
    %{
      base_url: base_url,
      poll_interval_ms: 10,
      run_timeout_ms: 5_000,
      max_turns: 5
    }
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "start_session/3" do
    test "POSTs to /api/symphony/runs and returns session with run_id" do
      {server, base_url} = start_mock_server(MockServer)

      issue = sample_issue()
      config = api_config(base_url)

      assert {:ok, session} = AppleSlicerAPI.start_session(issue, "/tmp/workspace", config)
      assert is_binary(session.run_id)
      assert session.issue == issue
      assert session.workspace == "/tmp/workspace"
      assert session.status == "pending"
      assert %Req.Request{} = session.req

      Supervisor.stop(server)
    end

    test "returns error on 409 conflict" do
      {server, base_url, table} = start_configurable_server()
      mock_response(table, :create_run, 409, %{"error" => "already_running"})

      config = api_config(base_url)

      assert {:error, {:already_running, "already_running"}} =
               AppleSlicerAPI.start_session(sample_issue(), "/tmp/ws", config)

      :ets.delete(table)
      Supervisor.stop(server)
    end

    test "returns error on 503 unavailable" do
      {server, base_url, table} = start_configurable_server()
      mock_response(table, :create_run, 503, %{"error" => "service_unavailable"})

      config = api_config(base_url)

      assert {:error, {:unavailable, "service_unavailable"}} =
               AppleSlicerAPI.start_session(sample_issue(), "/tmp/ws", config)

      :ets.delete(table)
      Supervisor.stop(server)
    end
  end

  describe "run_turn/3" do
    test "POSTs turn and polls until completed" do
      {server, base_url} = start_mock_server(MockServer)

      config = api_config(base_url)
      {:ok, session} = AppleSlicerAPI.start_session(sample_issue(), "/tmp/workspace", config)

      messages = :ets.new(:messages, [:bag, :public])
      on_message = fn msg -> :ets.insert(messages, {:msg, msg}) end

      assert {:ok, result} =
               AppleSlicerAPI.run_turn(session, "fix the bug", on_message: on_message)

      assert result.result == :turn_completed
      assert result.session_id == "sess-abc"
      assert is_binary(result.turn_id)

      all_messages = :ets.lookup(messages, :msg) |> Enum.map(&elem(&1, 1))
      events = Enum.map(all_messages, & &1.event)
      assert :turn_started in events
      assert :run_status_update in events

      :ets.delete(messages)
      Supervisor.stop(server)
    end

    test "returns error when run not found (404)" do
      {server, base_url, table} = start_configurable_server()

      mock_response(table, :create_run, 201, %{
        "run" => %{"id" => "run-404", "status" => "pending"}
      })

      mock_response(table, :trigger_turn, 404, %{})

      config = api_config(base_url)
      {:ok, session} = AppleSlicerAPI.start_session(sample_issue(), "/tmp/ws", config)

      assert {:error, :run_not_found} = AppleSlicerAPI.run_turn(session, "prompt", [])

      :ets.delete(table)
      Supervisor.stop(server)
    end

    test "returns error when run fails" do
      {server, base_url, table} = start_configurable_server()

      mock_response(table, :create_run, 201, %{
        "run" => %{"id" => "run-fail", "status" => "pending"}
      })

      mock_response(table, :trigger_turn, 202, %{
        "turn" => %{
          "turn_number" => 1,
          "triggered_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "run_id" => "run-fail"
        }
      })

      mock_response(table, :get_run, 200, %{
        "run" => %{
          "id" => "run-fail",
          "status" => "failed",
          "error" => "out_of_tokens",
          "turn_count" => 1
        }
      })

      config = api_config(base_url)
      {:ok, session} = AppleSlicerAPI.start_session(sample_issue(), "/tmp/ws", config)

      assert {:error, {:run_failed, "out_of_tokens"}} =
               AppleSlicerAPI.run_turn(session, "prompt", [])

      :ets.delete(table)
      Supervisor.stop(server)
    end
  end

  describe "stop_session/1" do
    test "DELETEs run and returns :ok" do
      {server, base_url} = start_mock_server(MockServer)

      config = api_config(base_url)
      {:ok, session} = AppleSlicerAPI.start_session(sample_issue(), "/tmp/workspace", config)

      assert :ok = AppleSlicerAPI.stop_session(session)

      Supervisor.stop(server)
    end

    test "skips DELETE when session is in terminal state" do
      session = %{
        run_id: "run-terminal",
        status: "completed",
        req: Req.new(base_url: "http://localhost:1")
      }

      assert :ok = AppleSlicerAPI.stop_session(session)
    end

    test "returns :ok even on unexpected HTTP status" do
      {server, base_url, table} = start_configurable_server()

      mock_response(table, :create_run, 201, %{
        "run" => %{"id" => "run-cleanup", "status" => "running"}
      })

      mock_response(table, :delete_run, 500, %{"error" => "internal"})

      config = api_config(base_url)
      {:ok, session} = AppleSlicerAPI.start_session(sample_issue(), "/tmp/ws", config)

      assert :ok = AppleSlicerAPI.stop_session(session)

      :ets.delete(table)
      Supervisor.stop(server)
    end

    test "returns :ok for nil/missing session" do
      assert :ok = AppleSlicerAPI.stop_session(%{})
    end
  end

  describe "full lifecycle" do
    test "start_session -> run_turn -> stop_session with all HTTP mocked" do
      {server, base_url} = start_mock_server(MockServer)

      issue = sample_issue()
      config = api_config(base_url)

      # 1. Start session
      assert {:ok, session} = AppleSlicerAPI.start_session(issue, "/tmp/lifecycle", config)
      assert is_binary(session.run_id)
      assert session.status == "pending"

      # 2. Run turn
      assert {:ok, result} = AppleSlicerAPI.run_turn(session, "implement the feature", [])
      assert result.result == :turn_completed
      assert result.session_id == "sess-abc"

      # 3. Stop session (completed runs skip DELETE)
      completed_session = %{session | status: "completed"}
      assert :ok = AppleSlicerAPI.stop_session(completed_session)

      Supervisor.stop(server)
    end
  end

  describe "get_run/1" do
    test "fetches current run status" do
      {server, base_url} = start_mock_server(MockServer)

      config = api_config(base_url)
      {:ok, session} = AppleSlicerAPI.start_session(sample_issue(), "/tmp/ws", config)

      assert {:ok, run} = AppleSlicerAPI.get_run(session)
      assert run["status"] == "completed"
      assert run["turn_count"] == 1

      Supervisor.stop(server)
    end

    test "returns error for missing run" do
      {server, base_url, table} = start_configurable_server()

      mock_response(table, :create_run, 201, %{
        "run" => %{"id" => "run-missing", "status" => "pending"}
      })

      mock_response(table, :get_run, 404, %{})

      config = api_config(base_url)
      {:ok, session} = AppleSlicerAPI.start_session(sample_issue(), "/tmp/ws", config)

      assert {:error, :not_found} = AppleSlicerAPI.get_run(session)

      :ets.delete(table)
      Supervisor.stop(server)
    end
  end
end
