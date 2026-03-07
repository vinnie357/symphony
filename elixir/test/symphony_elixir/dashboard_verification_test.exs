defmodule SymphonyElixir.DashboardVerificationTest do
  @moduledoc """
  Verifies that the web LiveView dashboard and TUI status dashboard
  render session/issue status data and update on state changes.

  Bead: symphony-9h6.2.4
  """

  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixirWeb.ObservabilityPubSub

  @endpoint SymphonyElixirWeb.Endpoint
  @terminal_columns 115

  # ---------------------------------------------------------------------------
  # Static orchestrator mock (same pattern as extensions_test.exs)
  # ---------------------------------------------------------------------------

  defmodule StaticOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_snapshot(overrides \\ %{}) do
    defaults = %{
      running: [
        %{
          issue_id: "issue-dash-1",
          identifier: "MT-DASH-1",
          state: "In Progress",
          project_slug: "test-project",
          session_id: "session-abc",
          turn_count: 3,
          codex_app_server_pid: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 1_200,
          codex_output_tokens: 800,
          codex_total_tokens: 2_000,
          backend_name: "Claude",
          execution_model: "claude-sonnet-4-20250514",
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-dash-2",
          identifier: "MT-DASH-2",
          attempt: 3,
          due_in_ms: 5_000,
          error: "rate limit exceeded"
        }
      ],
      codex_totals: %{input_tokens: 1_200, output_tokens: 800, total_tokens: 2_000, seconds_running: 120},
      rate_limits: nil
    }

    Map.merge(defaults, overrides)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  # ---------------------------------------------------------------------------
  # Web LiveView dashboard tests
  # ---------------------------------------------------------------------------

  describe "web LiveView dashboard" do
    test "renders running session with issue identifier and state" do
      snapshot = make_snapshot()
      orchestrator_name = Module.concat(__MODULE__, :WebRunningOrch)

      {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Operations Dashboard"
      assert html =~ "MT-DASH-1"
      assert html =~ "In Progress"
      assert html =~ "Copy ID"
    end

    test "renders retry queue entries" do
      snapshot = make_snapshot()
      orchestrator_name = Module.concat(__MODULE__, :WebRetryOrch)

      {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "MT-DASH-2"
      assert html =~ "rate limit exceeded"
      assert html =~ "Retry queue"
    end

    test "renders token usage metrics" do
      snapshot = make_snapshot()
      orchestrator_name = Module.concat(__MODULE__, :WebTokensOrch)

      {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "2,000"
      assert html =~ "1,200"
      assert html =~ "800"
      assert html =~ "Total tokens"
    end

    test "renders empty state when no sessions are running" do
      snapshot = make_snapshot(%{running: [], retrying: []})
      orchestrator_name = Module.concat(__MODULE__, :WebEmptyOrch)

      {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "No active sessions"
      assert html =~ "No issues are currently backing off"
    end

    test "updates when orchestrator state changes via PubSub" do
      snapshot = make_snapshot()
      orchestrator_name = Module.concat(__MODULE__, :WebUpdateOrch)

      {:ok, orch_pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, html} = live(build_conn(), "/")
      assert html =~ "MT-DASH-1"
      refute html =~ "MT-DASH-3"

      updated_snapshot =
        make_snapshot(%{
          running: [
            %{
              issue_id: "issue-dash-3",
              identifier: "MT-DASH-3",
              state: "Todo",
              project_slug: "test-project",
              session_id: "session-xyz",
              turn_count: 1,
              codex_app_server_pid: nil,
              last_codex_message: nil,
              last_codex_timestamp: nil,
              last_codex_event: nil,
              codex_input_tokens: 0,
              codex_output_tokens: 0,
              codex_total_tokens: 0,
              backend_name: "Claude",
              execution_model: "claude-sonnet-4-20250514",
              started_at: DateTime.utc_now()
            }
          ]
        })

      :sys.replace_state(orch_pid, fn state ->
        Keyword.put(state, :snapshot, updated_snapshot)
      end)

      StatusDashboard.notify_update()

      assert_eventually(fn ->
        rendered = render(view)
        rendered =~ "MT-DASH-3"
      end)
    end

    test "renders error state when orchestrator is unavailable" do
      orchestrator_name = Module.concat(__MODULE__, :WebUnavailableOrch)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5)

      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ "Snapshot unavailable"
    end
  end

  # ---------------------------------------------------------------------------
  # TUI status dashboard tests
  # ---------------------------------------------------------------------------

  describe "TUI status dashboard" do
    test "renders running session with issue identifier and tokens" do
      snapshot_data =
        {:ok,
         %{
           running: [
             %{
               identifier: "MT-TUI-1",
               state: "In Progress",
               session_id: "thread-tui-1",
               codex_app_server_pid: "5555",
               codex_total_tokens: 15_000,
               runtime_seconds: 300,
               turn_count: 5,
               last_codex_event: "turn_completed",
               last_codex_message: %{
                 event: :notification,
                 message: %{
                   "method" => "turn/completed",
                   "params" => %{"turn" => %{"status" => "completed"}}
                 }
               },
               backend_name: "Claude",
               execution_model: "claude-sonnet-4-20250514"
             }
           ],
           retrying: [],
           codex_totals: %{input_tokens: 10_000, output_tokens: 5_000, total_tokens: 15_000, seconds_running: 300},
           rate_limits: nil
         }}

      rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 2.5, @terminal_columns)

      assert rendered =~ "MT-TUI-1"
      assert rendered =~ "15,000"
    end

    test "renders retry queue with backoff info" do
      snapshot_data =
        {:ok,
         %{
           running: [],
           retrying: [
             %{
               issue_id: "issue-tui-2",
               identifier: "MT-TUI-2",
               attempt: 4,
               due_in_ms: 3_000,
               error: "API timeout"
             }
           ],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil
         }}

      rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, @terminal_columns)

      assert rendered =~ "MT-TUI-2"
      assert rendered =~ "API timeout"
    end

    test "renders idle state with no sessions" do
      snapshot_data =
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil
         }}

      rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, @terminal_columns)

      assert rendered =~ "No active agents"
      assert rendered =~ "No queued retries"
    end

    test "updates when snapshot data changes" do
      initial_snapshot =
        {:ok,
         %{
           running: [
             %{
               identifier: "MT-TUI-3",
               state: "In Progress",
               session_id: "thread-tui-3",
               codex_app_server_pid: nil,
               codex_total_tokens: 500,
               runtime_seconds: 60,
               turn_count: 1,
               last_codex_event: nil,
               last_codex_message: nil,
               backend_name: "Claude",
               execution_model: nil
             }
           ],
           retrying: [],
           codex_totals: %{input_tokens: 300, output_tokens: 200, total_tokens: 500, seconds_running: 60},
           rate_limits: nil
         }}

      updated_snapshot =
        {:ok,
         %{
           running: [
             %{
               identifier: "MT-TUI-3",
               state: "In Progress",
               session_id: "thread-tui-3",
               codex_app_server_pid: nil,
               codex_total_tokens: 8_500,
               runtime_seconds: 240,
               turn_count: 4,
               last_codex_event: "turn_completed",
               last_codex_message: %{
                 event: :notification,
                 message: %{
                   "method" => "turn/completed",
                   "params" => %{"turn" => %{"status" => "completed"}}
                 }
               },
               backend_name: "Claude",
               execution_model: nil
             }
           ],
           retrying: [],
           codex_totals: %{input_tokens: 5_000, output_tokens: 3_500, total_tokens: 8_500, seconds_running: 240},
           rate_limits: nil
         }}

      initial_render = StatusDashboard.format_snapshot_content_for_test(initial_snapshot, 0.0, @terminal_columns)
      updated_render = StatusDashboard.format_snapshot_content_for_test(updated_snapshot, 1.5, @terminal_columns)

      # Same issue identifier appears in both renders
      assert initial_render =~ "MT-TUI-3"
      assert updated_render =~ "MT-TUI-3"

      # Token counts reflect the change
      assert initial_render =~ "500"
      assert updated_render =~ "8,500"
    end

    test "renders rate limit information when available" do
      snapshot_data =
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: %{
             limit_id: "gpt-5",
             primary: %{remaining: 5_000, limit: 20_000, reset_in_seconds: 30}
           }
         }}

      rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, @terminal_columns)

      assert rendered =~ "5,000"
      assert rendered =~ "20,000"
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub integration
  # ---------------------------------------------------------------------------

  describe "PubSub notification flow" do
    test "ObservabilityPubSub delivers updates to subscribers" do
      assert :ok = ObservabilityPubSub.subscribe()
      assert :ok = ObservabilityPubSub.broadcast_update()
      assert_receive :observability_updated
    end

    test "StatusDashboard.notify_update broadcasts via PubSub" do
      assert :ok = ObservabilityPubSub.subscribe()
      StatusDashboard.notify_update()
      assert_receive :observability_updated
    end
  end
end
