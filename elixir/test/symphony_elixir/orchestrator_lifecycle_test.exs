defmodule SymphonyElixir.OrchestratorLifecycleTest do
  @moduledoc """
  Unit tests for the full issue lifecycle through the orchestrator,
  mocking the Tracker and Backend boundaries.

  Bead: symphony-9h6.2.1
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.Linear.Issue

  # ---------------------------------------------------------------------------
  # Mock Backend
  # ---------------------------------------------------------------------------

  defmodule MockBackend do
    @moduledoc false
    @behaviour SymphonyElixir.Backend

    @impl true
    def start_session(issue, workspace, _config) do
      send_event({:mock_backend_start_session, issue, workspace})
      {:ok, %{issue: issue, workspace: workspace, session_id: "mock-session-1"}}
    end

    @impl true
    def run_turn(session, _prompt, opts) do
      send_event({:mock_backend_run_turn, session})

      if on_message = Keyword.get(opts, :on_message) do
        on_message.(%{event: :turn_completed, timestamp: DateTime.utc_now()})
      end

      {:ok,
       %{
         result: "PR opened: https://github.com/test/repo/pull/42",
         session_id: session.session_id,
         thread_id: "mock-thread-1",
         turn_id: "mock-turn-1"
       }}
    end

    @impl true
    def stop_session(_session) do
      send_event(:mock_backend_stop_session)
      :ok
    end

    defp send_event(message) do
      case Process.get({__MODULE__, :recipient}) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_issue(attrs \\ %{}) do
    defaults = %{
      id: "issue-lifecycle-1",
      identifier: "MT-500",
      title: "Add widget feature",
      description: "Implement the widget",
      state: "Todo",
      priority: 2,
      url: "https://linear.app/test/MT-500",
      labels: ["claude"],
      branch_name: "feat/widget",
      project_slug: "test-project",
      created_at: DateTime.utc_now()
    }

    struct(Issue, Map.merge(defaults, attrs))
  end

  defp configure_memory_tracker!(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
  end

  defp write_memory_workflow!(overrides \\ []) do
    defaults = [
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed", "Cancelled"],
      execution_backend: "claude",
      max_turns: 1
    ]

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(defaults, overrides)
    )
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "issue lifecycle" do
    setup do
      write_memory_workflow!()
      Process.put({MockBackend, :recipient}, self())
      :ok
    end

    test "Tracker mock returns candidate issues in Todo state" do
      todo_issue = make_issue(%{state: "Todo"})
      in_progress_issue = make_issue(%{id: "issue-2", identifier: "MT-501", state: "In Progress"})
      done_issue = make_issue(%{id: "issue-3", identifier: "MT-502", state: "Done"})

      configure_memory_tracker!([todo_issue, in_progress_issue, done_issue])

      assert {:ok, candidates} = Tracker.fetch_candidate_issues()
      assert length(candidates) == 3

      todo_candidates = Enum.filter(candidates, &(&1.state == "Todo"))
      assert length(todo_candidates) == 1
      assert hd(todo_candidates).id == "issue-lifecycle-1"
    end

    test "Orchestrator dispatch picks up Todo issue and claims it" do
      issue = make_issue(%{state: "Todo"})
      configure_memory_tracker!([issue])

      orchestrator_name = Module.concat(__MODULE__, :DispatchOrchestrator)

      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      # Allow the orchestrator to complete its initial poll cycle
      Process.sleep(200)

      state = :sys.get_state(pid)
      # The issue should be claimed (even if the agent task may have started/completed)
      assert MapSet.member?(state.claimed, "issue-lifecycle-1") or
               MapSet.member?(state.completed, "issue-lifecycle-1") or
               Map.has_key?(state.running, "issue-lifecycle-1")
    end

    test "AgentRouter resolves correct backend from issue labels" do
      claude_issue = make_issue(%{labels: ["claude", "bug"]})
      assert {:ok, SymphonyElixir.Backends.Claude} = AgentRouter.resolve_backend(claude_issue)

      codex_issue = make_issue(%{labels: ["codex"]})
      assert {:ok, SymphonyElixir.Backends.Codex} = AgentRouter.resolve_backend(codex_issue)

      gemini_issue = make_issue(%{labels: ["gemini"]})
      assert {:ok, SymphonyElixir.Backends.Gemini} = AgentRouter.resolve_backend(gemini_issue)

      # No agent label falls back to config default
      unlabeled_issue = make_issue(%{labels: ["frontend"]})
      assert {:ok, SymphonyElixir.Backends.Claude} = AgentRouter.resolve_backend(unlabeled_issue)
    end

    test "Backend mock start_session + run_turn returns PR result" do
      issue = make_issue()

      assert {:ok, session} = MockBackend.start_session(issue, "/tmp/test-workspace", %{})
      assert session.session_id == "mock-session-1"

      assert_received {:mock_backend_start_session, ^issue, "/tmp/test-workspace"}

      assert {:ok, result} = MockBackend.run_turn(session, "Fix the bug", [])
      assert result.result =~ "PR opened"
      assert result.session_id == "mock-session-1"

      assert_received {:mock_backend_run_turn, ^session}
    end

    test "Tracker.Memory create_comment sends event to recipient" do
      configure_memory_tracker!([])

      assert :ok = Tracker.create_comment("issue-lifecycle-1", "PR: https://github.com/test/repo/pull/42")

      assert_received {:memory_tracker_comment, "issue-lifecycle-1",
                       "PR: https://github.com/test/repo/pull/42"}
    end

    test "Tracker.Memory update_issue_state sends event to recipient" do
      configure_memory_tracker!([])

      assert :ok = Tracker.update_issue_state("issue-lifecycle-1", "In Review")

      assert_received {:memory_tracker_state_update, "issue-lifecycle-1", "In Review"}
    end

    test "issue in terminal state (Done) is not dispatched" do
      done_issue = make_issue(%{state: "Done"})
      configure_memory_tracker!([done_issue])

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{}
      }

      refute Orchestrator.should_dispatch_issue_for_test(done_issue, state)
    end

    test "issue in terminal state (Cancelled) is not dispatched" do
      cancelled_issue = make_issue(%{state: "Cancelled"})
      configure_memory_tracker!([cancelled_issue])

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{}
      }

      refute Orchestrator.should_dispatch_issue_for_test(cancelled_issue, state)
    end

    test "already-completed issue is not re-picked-up" do
      issue = make_issue(%{state: "Todo"})
      configure_memory_tracker!([issue])

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(["issue-lifecycle-1"]),
        claimed: MapSet.new(["issue-lifecycle-1"]),
        retry_attempts: %{}
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "reconcile removes running issue that moved to terminal state" do
      issue = make_issue(%{state: "Done"})
      ref = make_ref()

      # Use a dummy pid that won't cause EXIT when terminated
      dummy_pid = spawn(fn -> Process.sleep(:infinity) end)

      running_entry = %{
        pid: dummy_pid,
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        project_slug: issue.project_slug,
        session_id: nil,
        turn_count: 0,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        started_at: DateTime.utc_now(),
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        retry_attempt: nil,
        codex_app_server_pid: nil,
        backend_name: nil,
        execution_model: nil
      }

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{issue.id => running_entry},
        completed: MapSet.new(),
        claimed: MapSet.new([issue.id]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue.id)
      refute MapSet.member?(updated_state.claimed, issue.id)
    end
  end
end
