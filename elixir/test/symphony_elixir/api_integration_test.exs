defmodule SymphonyElixir.ApiIntegrationTest do
  @moduledoc """
  Integration test for the full Symphony → AppleSlicerAPI flow.

  Exercises the Orchestrator GenServer and AgentRunner with the AppleSlicerAPI
  backend against a mock HTTP server (Bandit + Plug.Router), using
  Tracker.Memory for issue state.

  Flow tested:
  1. Configure memory tracker with a Todo issue
  2. Start mock HTTP server simulating apple-slicer endpoints
  3. Orchestrator polls, finds candidate, dispatches via AgentRunner
  4. AgentRunner resolves AppleSlicerAPI backend, creates run, triggers turn
  5. Backend polls mock server until completed
  6. AgentRunner finishes, Orchestrator records completion
  """
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Backends.AppleSlicerAPI
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator

  # ---------------------------------------------------------------------------
  # Mock apple-slicer HTTP server
  # ---------------------------------------------------------------------------

  defmodule MockAppleSlicerServer do
    @moduledoc false
    use Plug.Router

    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    post "/api/symphony/runs" do
      table = conn.private[:mock_table]
      run_id = "run-#{System.unique_integer([:positive])}"
      :ets.insert(table, {:last_run_id, run_id})
      :ets.insert(table, {:last_issue, conn.body_params["issue"]})

      json_resp(conn, 201, %{
        "run" => %{"id" => run_id, "status" => "pending", "turn_count" => 0}
      })
    end

    post "/api/symphony/runs/:id/turns" do
      table = conn.private[:mock_table]
      count = :ets.update_counter(table, :turn_count, {2, 1}, {:turn_count, 0})

      json_resp(conn, 202, %{
        "turn" => %{
          "turn_number" => count,
          "triggered_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "run_id" => id
        }
      })
    end

    get "/api/symphony/runs/:id" do
      table = conn.private[:mock_table]
      poll_count = :ets.update_counter(table, :poll_count, {2, 1}, {:poll_count, 0})

      # Return "running" for first poll, "completed" for subsequent
      status = if poll_count <= 1, do: "running", else: "completed"

      json_resp(conn, 200, %{
        "run" => %{
          "id" => id,
          "status" => status,
          "turn_count" => 1,
          "session_id" => "sess-integ-#{id}",
          "codex_input_tokens" => 1200,
          "codex_output_tokens" => 450,
          "codex_total_tokens" => 1650,
          "runtime_seconds" => 8
        }
      })
    end

    delete "/api/symphony/runs/:id" do
      table = conn.private[:mock_table]
      :ets.insert(table, {:deleted_run_id, id})
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

  defmodule MockAppleSlicerPlug do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      table = Keyword.fetch!(opts, :table)

      conn
      |> Plug.Conn.put_private(:mock_table, table)
      |> MockAppleSlicerServer.call(MockAppleSlicerServer.init([]))
    end
  end

  # ---------------------------------------------------------------------------
  # Failing mock server (returns failed run on poll)
  # ---------------------------------------------------------------------------

  defmodule FailingMockServer do
    @moduledoc false
    use Plug.Router

    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    post "/api/symphony/runs" do
      run_id = "run-fail-#{System.unique_integer([:positive])}"

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
          "status" => "failed",
          "error" => "agent_crashed",
          "turn_count" => 1
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

  defmodule FailingMockPlug do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      table = Keyword.fetch!(opts, :table)

      conn
      |> Plug.Conn.put_private(:mock_table, table)
      |> FailingMockServer.call(FailingMockServer.init([]))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_mock_server do
    table = :ets.new(:mock_state, [:set, :public])
    {:ok, server} = Bandit.start_link(plug: {MockAppleSlicerPlug, table: table}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base_url = "http://127.0.0.1:#{port}"
    {server, base_url, table}
  end

  defp make_issue(overrides \\ %{}) do
    Map.merge(
      %Issue{
        id: "integ-issue-#{System.unique_integer([:positive])}",
        identifier: "VIN-#{System.unique_integer([:positive])}",
        title: "Integration test feature",
        description: "Implement a feature via API backend",
        state: "Todo",
        url: "https://linear.app/test/VIN-500",
        labels: ["apple-slicer-api"],
        assigned_to_worker: true
      },
      overrides
    )
  end

  defp poll_until(fun, timeout_ms, interval_ms \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(fun, deadline, interval_ms)
  end

  defp do_poll_until(fun, deadline, interval_ms) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("poll_until timed out waiting for condition")
      else
        Process.sleep(interval_ms)
        do_poll_until(fun, deadline, interval_ms)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: direct AppleSlicerAPI backend calls
  # ---------------------------------------------------------------------------

  describe "direct AppleSlicerAPI backend calls" do
    test "issue dispatched through AppleSlicerAPI backend completes successfully" do
      {server, base_url, table} = start_mock_server()

      issue = make_issue()
      workspace = Path.join(System.tmp_dir!(), "integ-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)

      try do
        {:ok, session} = AppleSlicerAPI.start_session(issue, workspace, %{
          base_url: base_url,
          poll_interval_ms: 10,
          run_timeout_ms: 5_000,
          max_turns: 3
        })

        assert is_binary(session.run_id)
        assert session.status == "pending"

        # Run a turn
        {:ok, result} = AppleSlicerAPI.run_turn(session, "implement the feature", [])
        assert result.result == :turn_completed
        assert is_binary(result.session_id)

        # Stop session
        completed_session = %{session | status: "completed"}
        assert :ok = AppleSlicerAPI.stop_session(completed_session)

        # Verify mock server received the expected requests
        assert [{:last_run_id, run_id}] = :ets.lookup(table, :last_run_id)
        assert is_binary(run_id)

        [{:last_issue, submitted_issue}] = :ets.lookup(table, :last_issue)
        assert submitted_issue["identifier"] == issue.identifier
        assert submitted_issue["title"] == issue.title

        [{:turn_count, turns}] = :ets.lookup(table, :turn_count)
        assert turns >= 1

        [{:poll_count, polls}] = :ets.lookup(table, :poll_count)
        assert polls >= 2
      after
        File.rm_rf(workspace)
        :ets.delete(table)
        Supervisor.stop(server)
      end
    end

    test "backend handles run failure gracefully" do
      fail_table = :ets.new(:fail_state, [:set, :public])

      {:ok, fail_server} =
        Bandit.start_link(
          plug: {FailingMockPlug, table: fail_table},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(fail_server)
      fail_base_url = "http://127.0.0.1:#{port}"

      issue = make_issue()

      try do
        {:ok, session} = AppleSlicerAPI.start_session(issue, "/tmp/fail-ws", %{
          base_url: fail_base_url,
          poll_interval_ms: 10,
          run_timeout_ms: 5_000
        })

        assert {:error, {:run_failed, "agent_crashed"}} =
                 AppleSlicerAPI.run_turn(session, "do work", [])
      after
        :ets.delete(fail_table)
        Supervisor.stop(fail_server)
      end
    end
  end

  describe "full API flow via AgentRunner" do
    test "AgentRunner dispatches apple-slicer-api backend to AppleSlicerAPI" do
      {server, base_url, table} = start_mock_server()

      issue = make_issue(%{state: "In Progress"})
      done_issue = %{issue | state: "Done"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [done_issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      prev_url = System.get_env("APPLE_SLICER_URL")
      System.put_env("APPLE_SLICER_URL", base_url)

      workspace_root = Path.join(System.tmp_dir!(), "integ-agent-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "memory",
        execution_backend: "apple-slicer-api"
      )

      try do
        log =
          capture_log(fn ->
            AgentRunner.run(issue, self(), issue_state_fetcher: fn _ids -> {:ok, [done_issue]} end)
          end)

        assert log =~ "apple-slicer run created"
        assert log =~ "apple-slicer turn triggered"
        assert log =~ "apple-slicer run completed"
        assert log =~ "Completed agent run"

        # Verify mock server saw the requests
        [{:last_run_id, _run_id}] = :ets.lookup(table, :last_run_id)
        [{:turn_count, turns}] = :ets.lookup(table, :turn_count)
        assert turns >= 1
      after
        restore_env("APPLE_SLICER_URL", prev_url)
        File.rm_rf(workspace_root)
        :ets.delete(table)
        Supervisor.stop(server)
      end
    end

    test "issue state transitions are respected by AgentRunner" do
      {server, base_url, table} = start_mock_server()

      issue = make_issue(%{state: "Todo"})

      # First call returns active, second returns Done
      call_count = :counters.new(1, [:atomics])

      issue_state_fetcher = fn _ids ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if n == 0 do
          {:ok, [%{issue | state: "In Progress"}]}
        else
          {:ok, [%{issue | state: "Done"}]}
        end
      end

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      prev_url = System.get_env("APPLE_SLICER_URL")
      System.put_env("APPLE_SLICER_URL", base_url)

      workspace_root = Path.join(System.tmp_dir!(), "integ-state-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "memory",
        execution_backend: "apple-slicer-api"
      )

      try do
        log =
          capture_log(fn ->
            AgentRunner.run(issue, self(),
              issue_state_fetcher: issue_state_fetcher,
              max_turns: 5
            )
          end)

        assert log =~ "Completed agent run"

        [{:turn_count, turns}] = :ets.lookup(table, :turn_count)
        assert turns >= 2
      after
        restore_env("APPLE_SLICER_URL", prev_url)
        File.rm_rf(workspace_root)
        :ets.delete(table)
        Supervisor.stop(server)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: Orchestrator GenServer dispatches through AppleSlicerAPI
  # ---------------------------------------------------------------------------

  describe "Orchestrator GenServer integration" do
    @tag timeout: 30_000
    test "orchestrator discovers Todo issue and dispatches via AppleSlicerAPI" do
      {server, base_url, table} = start_mock_server()

      issue = make_issue(%{state: "Todo"})
      done_issue = %{issue | state: "Done"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      prev_url = System.get_env("APPLE_SLICER_URL")
      System.put_env("APPLE_SLICER_URL", base_url)

      workspace_root = Path.join(System.tmp_dir!(), "integ-orch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "memory",
        execution_backend: "apple-slicer-api",
        poll_interval_ms: 100,
        max_concurrent_agents: 1,
        max_turns: 1
      )

      orchestrator_name = Module.concat(__MODULE__, :"OrchestratorInteg#{System.unique_integer([:positive])}")

      try do
        # Trap exits so the linked orchestrator GenServer doesn't kill us
        Process.flag(:trap_exit, true)

        log =
          capture_log(fn ->
            {:ok, orch_pid} = Orchestrator.start_link(name: orchestrator_name)

            # Wait for the orchestrator to dispatch and the agent to complete.
            poll_until(fn ->
              state = :sys.get_state(orch_pid)
              MapSet.member?(state.completed, issue.id) or map_size(state.retry_attempts) > 0
            end, 15_000)

            # Transition issue to Done so continuation retry skips re-dispatch
            Application.put_env(:symphony_elixir, :memory_tracker_issues, [done_issue])

            # Let the retry fire and the orchestrator see Done state
            Process.sleep(2_000)

            GenServer.stop(orch_pid, :normal)
          end)

        assert log =~ "apple-slicer run created"
        assert log =~ "apple-slicer turn triggered"
        assert log =~ "apple-slicer run completed"
        assert log =~ "Dispatching issue to agent"
        assert log =~ "Agent task completed"

        [{:last_run_id, _run_id}] = :ets.lookup(table, :last_run_id)
        [{:turn_count, turns}] = :ets.lookup(table, :turn_count)
        assert turns >= 1
      after
        Process.flag(:trap_exit, false)
        restore_env("APPLE_SLICER_URL", prev_url)
        File.rm_rf(workspace_root)
        :ets.delete(table)
        Supervisor.stop(server)

        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) -> GenServer.stop(pid, :normal, 1_000)
          _ -> :ok
        end
      end
    end
  end
end
