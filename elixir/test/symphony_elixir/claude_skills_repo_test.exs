defmodule SymphonyElixir.ClaudeSkillsRepoTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Backends.Claude
  alias SymphonyElixir.Linear.Issue

  defmodule MockCmd do
    def cmd(command, args, _opts) do
      recipient = Application.get_env(:symphony_elixir, :skills_test_recipient)
      if recipient, do: send(recipient, {:mock_cmd, command, args})
      {"mock output", 0}
    end
  end

  setup do
    prev = Application.get_env(:symphony_elixir, :cmd_runner)
    Application.put_env(:symphony_elixir, :cmd_runner, MockCmd)
    Application.put_env(:symphony_elixir, :skills_test_recipient, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:symphony_elixir, :cmd_runner, prev),
        else: Application.delete_env(:symphony_elixir, :cmd_runner)

      Application.delete_env(:symphony_elixir, :skills_test_recipient)
    end)

    :ok
  end

  describe "skills_repo passthrough" do
    test "start_session stores skills_repo from team config" do
      team_config = %{skills_repo: "https://github.com/example/skills"}
      {:ok, session} = Claude.start_session(%Issue{}, "/tmp/ws", team_config)
      assert session.skills_repo == "https://github.com/example/skills"
    end

    test "start_session with no skills_repo stores nil" do
      {:ok, session} = Claude.start_session(%Issue{}, "/tmp/ws", %{})
      assert session.skills_repo == nil
    end

    test "run_turn includes --add-skill-repo flag when skills_repo is set" do
      team_config = %{skills_repo: "https://github.com/example/skills"}
      {:ok, session} = Claude.start_session(%Issue{}, "/tmp/ws", team_config)

      Claude.run_turn(session, "do work", [])

      assert_receive {:mock_cmd, "claude", args}
      assert "--add-skill-repo" in args
      skill_idx = Enum.find_index(args, &(&1 == "--add-skill-repo"))
      assert Enum.at(args, skill_idx + 1) == "https://github.com/example/skills"
    end

    test "run_turn omits --add-skill-repo flag when skills_repo is nil" do
      {:ok, session} = Claude.start_session(%Issue{}, "/tmp/ws", %{})

      Claude.run_turn(session, "do work", [])

      assert_receive {:mock_cmd, "claude", args}
      refute "--add-skill-repo" in args
    end

    test "run_turn includes --add-skill-repo alongside other flags" do
      write_workflow_file!(workflow_file_path(),
        claude_command: "claude",
        claude_permission_mode: "plan",
        claude_output_format: "stream-json",
        execution_model: "claude-sonnet-4-5-20250514"
      )

      team_config = %{skills_repo: "https://github.com/example/skills"}
      {:ok, session} = Claude.start_session(%Issue{}, "/tmp/ws", team_config)

      Claude.run_turn(session, "do work", [])

      assert_receive {:mock_cmd, "claude", args}
      assert "--print" in args
      assert "--permission-mode" in args
      assert "--add-skill-repo" in args
    end
  end

  defp workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path)
  end
end
