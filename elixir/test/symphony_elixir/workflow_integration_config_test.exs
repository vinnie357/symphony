defmodule SymphonyElixir.WorkflowIntegrationConfigTest do
  @moduledoc """
  Validates the integration test WORKFLOW.md fixture against the
  NimbleOptions schema and verifies expected config values.

  Bead: symphony-9h6.2.2
  """

  use ExUnit.Case

  alias SymphonyElixir.{Config, Workflow, WorkflowStore}

  @fixture_path Path.join([__DIR__, "..", "fixtures", "WORKFLOW.integration.md"])

  setup do
    prev_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    Application.put_env(:symphony_elixir, :workflow_file_path, @fixture_path)
    Workflow.set_workflow_file_path(@fixture_path)
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

    on_exit(fn ->
      if prev_path,
        do: Application.put_env(:symphony_elixir, :workflow_file_path, prev_path),
        else: Application.delete_env(:symphony_elixir, :workflow_file_path)

      if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()
    end)

    :ok
  end

  describe "integration WORKFLOW.md fixture" do
    test "loads and parses without error" do
      assert {:ok, %{config: config, prompt_template: prompt}} = Workflow.current()
      assert is_map(config)
      assert is_binary(prompt)
      assert prompt =~ "integration test session"
    end

    test "passes Config.validate!" do
      assert :ok = Config.validate!()
    end

    test "tracker config uses memory adapter" do
      assert Config.tracker_kind() == "memory"
    end

    test "active and terminal states are configured" do
      assert Config.linear_active_states() == ["Todo", "In Progress"]

      terminal = Config.linear_terminal_states()
      assert "Done" in terminal
      assert "Closed" in terminal
      assert "Cancelled" in terminal
    end

    test "polling interval is set for fast integration testing" do
      assert Config.poll_interval_ms() == 1_000
    end

    test "workspace root is configured" do
      assert Config.workspace_root() == "/tmp/symphony-integration-workspaces"
    end

    test "agent concurrency and turn limits are constrained" do
      assert Config.max_concurrent_agents() == 2
      assert Config.agent_max_turns() == 3
      assert Config.max_retry_backoff_ms() == 5_000
    end

    test "execution backend is claude with model" do
      assert Config.execution_backend() == "claude"
      assert Config.execution_model() == "claude-sonnet-4-20250514"
      assert Config.execution_max_turns() == 3
      assert Config.execution_timeout_ms() == 300_000
    end

    test "claude CLI config is set" do
      assert Config.claude_command() == "claude"
      assert Config.claude_output_format() == "stream-json"
      assert Config.claude_permission_mode() == "plan"
    end

    test "observability is disabled for test runs" do
      refute Config.observability_enabled?()
    end

    test "prompt template includes Liquid variables" do
      assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
      assert Config.workflow_prompt() =~ "{{ issue.title }}"
      assert Config.workflow_prompt() =~ "{{ issue.state }}"
    end
  end
end
