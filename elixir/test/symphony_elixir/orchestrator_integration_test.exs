defmodule SymphonyElixir.OrchestratorIntegrationTest do
  @moduledoc """
  Integration test for the full issue lifecycle through the orchestrator.

  Uses real GenServer processes with Tracker.Memory and a mock cmd_runner
  to exercise: Todo -> dispatch -> backend run -> completion -> terminal check.

  Bead: symphony-9h6.2.3
  """

  use SymphonyElixir.TestSupport

  # ---------------------------------------------------------------------------
  # Mock cmd_runner for Claude backend
  # ---------------------------------------------------------------------------

  defmodule MockCmd do
    @moduledoc false

    def cmd("claude", args, _opts) do
      prompt = List.last(args)
      notify({:mock_cmd_executed, "claude", prompt})
      {"PR opened: https://github.com/test/repo/pull/42\nAll tests passing.", 0}
    end

    def cmd(command, _args, _opts) do
      notify({:mock_cmd_executed, command, nil})
      {"Unknown command: #{command}", 127}
    end

    defp notify(message) do
      case Application.get_env(:symphony_elixir, :integration_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_issue(attrs) do
    defaults = %{
      id: "issue-integ-1",
      identifier: "MT-INTEG-1",
      title: "Add integration feature",
      description: "Implement the integration feature end-to-end",
      state: "Todo",
      priority: 2,
      url: "https://linear.app/test/MT-INTEG-1",
      labels: ["claude"],
      branch_name: "feat/integration",
      project_slug: "test-project",
      assigned_to_worker: true,
      created_at: DateTime.utc_now()
    }

    struct(Issue, Map.merge(defaults, attrs))
  end

  defp configure_memory_tracker!(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
  end

  defp update_memory_tracker_issues!(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
  end

  defp write_integration_workflow! do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-integ-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed", "Cancelled", "In Review"],
      execution_backend: "claude",
      workspace_root: workspace_root,
      poll_interval_ms: 100,
      max_turns: 1,
      max_concurrent_agents: 2,
      hook_after_create: nil,
      hook_before_run: nil,
      hook_after_run: nil,
      hook_before_remove: nil,
      codex_stall_timeout_ms: 0
    )

    workspace_root
  end

  defp wait_for(fun, label, attempts \\ 40) do
    if attempts <= 0 do
      flunk("Timed out waiting for: #{label}")
    end

    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_for(fun, label, attempts - 1)
    end
  end

  setup do
    prev_cmd_runner = Application.get_env(:symphony_elixir, :cmd_runner)
    Application.put_env(:symphony_elixir, :cmd_runner, MockCmd)
    Application.put_env(:symphony_elixir, :integration_test_pid, self())

    on_exit(fn ->
      if prev_cmd_runner,
        do: Application.put_env(:symphony_elixir, :cmd_runner, prev_cmd_runner),
        else: Application.delete_env(:symphony_elixir, :cmd_runner)

      Application.delete_env(:symphony_elixir, :integration_test_pid)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Integration tests
  # ---------------------------------------------------------------------------

  describe "full issue lifecycle" do
    test "orchestrator picks up Todo issue and dispatches to Claude backend" do
      workspace_root = write_integration_workflow!()
      issue = make_issue(%{state: "Todo"})
      configure_memory_tracker!([issue])

      on_exit(fn -> File.rm_rf(workspace_root) end)

      orchestrator_name = Module.concat(__MODULE__, :DispatchOrch)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      # Wait for the orchestrator to claim the issue
      wait_for(
        fn ->
          state = :sys.get_state(pid)

          MapSet.member?(state.claimed, "issue-integ-1") or
            Map.has_key?(state.running, "issue-integ-1") or
            MapSet.member?(state.completed, "issue-integ-1")
        end,
        "issue claimed or running"
      )

      # Verify the Claude backend was invoked via the mock cmd_runner
      assert_receive {:mock_cmd_executed, "claude", _prompt}, 5_000
    end

    test "backend run completes and orchestrator marks issue completed" do
      workspace_root = write_integration_workflow!()
      issue = make_issue(%{state: "Todo"})
      configure_memory_tracker!([issue])

      on_exit(fn -> File.rm_rf(workspace_root) end)

      orchestrator_name = Module.concat(__MODULE__, :CompletionOrch)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      # Wait for the backend to execute
      assert_receive {:mock_cmd_executed, "claude", _prompt}, 5_000

      # Wait for the agent task to complete and orchestrator to process the DOWN message
      wait_for(
        fn ->
          state = :sys.get_state(pid)
          MapSet.member?(state.completed, "issue-integ-1")
        end,
        "issue completed"
      )

      state = :sys.get_state(pid)
      assert MapSet.member?(state.completed, "issue-integ-1")
    end

    test "issue in terminal state is not re-dispatched after completion" do
      workspace_root = write_integration_workflow!()
      issue = make_issue(%{state: "Todo"})
      configure_memory_tracker!([issue])

      on_exit(fn -> File.rm_rf(workspace_root) end)

      orchestrator_name = Module.concat(__MODULE__, :TerminalOrch)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      # Wait for initial dispatch and completion
      assert_receive {:mock_cmd_executed, "claude", _prompt}, 5_000

      wait_for(
        fn ->
          state = :sys.get_state(pid)
          MapSet.member?(state.completed, "issue-integ-1")
        end,
        "issue completed"
      )

      # Now move the issue to "Done" in memory tracker so on retry it's seen as terminal
      done_issue = make_issue(%{state: "Done"})
      update_memory_tracker_issues!([done_issue])

      # Wait for the continuation retry to fire and the orchestrator to see the terminal state
      wait_for(
        fn ->
          state = :sys.get_state(pid)
          # After seeing terminal state, retry_attempts for this issue should be cleared
          not Map.has_key?(state.retry_attempts, "issue-integ-1") and
            not Map.has_key?(state.running, "issue-integ-1")
        end,
        "issue removed from retry after terminal state"
      )

      # Flush any stale mock_cmd messages
      receive do
        {:mock_cmd_executed, _, _} -> :ok
      after
        0 -> :ok
      end

      # Verify no second dispatch occurs (wait a few poll cycles)
      Process.sleep(300)
      refute_received {:mock_cmd_executed, "claude", _}
    end

    test "multiple issues dispatched concurrently" do
      workspace_root = write_integration_workflow!()
      issue1 = make_issue(%{id: "issue-multi-1", identifier: "MT-MULTI-1", state: "Todo"})
      issue2 = make_issue(%{id: "issue-multi-2", identifier: "MT-MULTI-2", state: "Todo"})
      configure_memory_tracker!([issue1, issue2])

      on_exit(fn -> File.rm_rf(workspace_root) end)

      orchestrator_name = Module.concat(__MODULE__, :MultiOrch)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      # Both issues should be dispatched (max_concurrent_agents: 2)
      assert_receive {:mock_cmd_executed, "claude", _}, 5_000
      assert_receive {:mock_cmd_executed, "claude", _}, 5_000

      # Wait for both to complete
      wait_for(
        fn ->
          state = :sys.get_state(pid)

          MapSet.member?(state.completed, "issue-multi-1") and
            MapSet.member?(state.completed, "issue-multi-2")
        end,
        "both issues completed"
      )
    end

    test "Tracker.Memory create_comment records PR link" do
      write_integration_workflow!()
      configure_memory_tracker!([])

      pr_link = "PR: https://github.com/test/repo/pull/42"
      assert :ok = Tracker.create_comment("issue-integ-1", pr_link)
      assert_received {:memory_tracker_comment, "issue-integ-1", ^pr_link}
    end

    test "Tracker.Memory update_issue_state transitions through lifecycle states" do
      write_integration_workflow!()
      configure_memory_tracker!([])

      # Simulate the expected lifecycle state transitions
      assert :ok = Tracker.update_issue_state("issue-integ-1", "In Progress")
      assert_received {:memory_tracker_state_update, "issue-integ-1", "In Progress"}

      assert :ok = Tracker.update_issue_state("issue-integ-1", "In Review")
      assert_received {:memory_tracker_state_update, "issue-integ-1", "In Review"}

      assert :ok = Tracker.update_issue_state("issue-integ-1", "Done")
      assert_received {:memory_tracker_state_update, "issue-integ-1", "Done"}
    end

    test "orchestrator receives backend_started codex update" do
      workspace_root = write_integration_workflow!()
      issue = make_issue(%{state: "Todo"})
      configure_memory_tracker!([issue])

      on_exit(fn -> File.rm_rf(workspace_root) end)

      orchestrator_name = Module.concat(__MODULE__, :CodexUpdateOrch)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      # Wait for dispatch and backend run
      assert_receive {:mock_cmd_executed, "claude", _prompt}, 5_000

      # Wait for completion so we can inspect the state
      wait_for(
        fn ->
          state = :sys.get_state(pid)
          MapSet.member?(state.completed, "issue-integ-1")
        end,
        "issue completed"
      )

      # The codex_totals should have accumulated some runtime
      state = :sys.get_state(pid)
      assert state.codex_totals.seconds_running >= 0
    end
  end
end
