defmodule SymphonyElixir.TeamRoutingIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the team routing pipeline:

    WORKFLOW.md teams config
      -> Config.teams/0 + Config.team_for_labels/1
      -> AgentRouter.resolve_backend/1
      -> AgentRunner dispatch
      -> Claude backend with --add-skill-repo
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.Backends.Claude
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  # Mock command runner that captures CLI invocations
  defmodule MockCmd do
    def cmd(command, args, _opts) do
      recipient = Application.get_env(:symphony_elixir, :team_integration_test_recipient)
      if recipient, do: send(recipient, {:mock_cmd, command, args})
      {"mock output", 0}
    end
  end

  setup do
    prev_cmd = Application.get_env(:symphony_elixir, :cmd_runner)
    Application.put_env(:symphony_elixir, :cmd_runner, MockCmd)
    Application.put_env(:symphony_elixir, :team_integration_test_recipient, self())

    on_exit(fn ->
      if prev_cmd,
        do: Application.put_env(:symphony_elixir, :cmd_runner, prev_cmd),
        else: Application.delete_env(:symphony_elixir, :cmd_runner)

      Application.delete_env(:symphony_elixir, :team_integration_test_recipient)
    end)

    :ok
  end

  describe "full team routing pipeline" do
    setup do
      write_workflow_file!(workflow_file_path(),
        execution_backend: "claude",
        execution_model: "claude-sonnet-4-5-20250514",
        claude_command: "claude",
        claude_output_format: "stream-json",
        teams: [
          %{
            "name" => "frontend",
            "labels" => ["frontend", "ui"],
            "backend" => "claude",
            "model" => "claude-sonnet-4-5-20250514",
            "skills_repo" => "https://github.com/example/frontend-skills",
            "permission_mode" => "plan"
          },
          %{
            "name" => "backend",
            "labels" => ["backend", "api"],
            "backend" => "claude",
            "model" => "claude-opus-4-5-20250514"
          }
        ]
      )

      :ok
    end

    test "frontend label routes through team config to Claude with skills_repo" do
      issue = %Issue{id: "issue-1", identifier: "FE-101", labels: ["frontend"]}

      # Step 1: Config parses teams from WORKFLOW.md
      teams = Config.teams()
      assert length(teams) == 2
      frontend_team = Enum.find(teams, &(&1.name == "frontend"))
      assert frontend_team.skills_repo == "https://github.com/example/frontend-skills"

      # Step 2: Config matches issue labels to team
      assert {:ok, matched_team} = Config.team_for_labels(issue.labels)
      assert matched_team.name == "frontend"

      # Step 3: AgentRouter resolves backend with team config
      assert {:ok, Claude, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config.name == "frontend"
      assert team_config.skills_repo == "https://github.com/example/frontend-skills"

      # Step 4: Claude backend receives team config and includes --add-skill-repo
      {:ok, session} = Claude.start_session(issue, "/tmp/ws", team_config)
      assert session.skills_repo == "https://github.com/example/frontend-skills"

      Claude.run_turn(session, "implement feature", [])

      assert_receive {:mock_cmd, "claude", args}
      assert "--add-skill-repo" in args
      skill_idx = Enum.find_index(args, &(&1 == "--add-skill-repo"))
      assert Enum.at(args, skill_idx + 1) == "https://github.com/example/frontend-skills"
      assert "--print" in args
    end

    test "backend team routes without skills_repo" do
      issue = %Issue{id: "issue-2", identifier: "BE-201", labels: ["api"]}

      assert {:ok, Claude, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config.name == "backend"
      assert team_config.skills_repo == nil

      {:ok, session} = Claude.start_session(issue, "/tmp/ws", team_config)
      assert session.skills_repo == nil

      Claude.run_turn(session, "fix endpoint", [])

      assert_receive {:mock_cmd, "claude", args}
      refute "--add-skill-repo" in args
    end

    test "unknown label falls back to default backend with empty team config" do
      issue = %Issue{id: "issue-3", identifier: "MISC-301", labels: ["infra"]}

      assert :none = Config.team_for_labels(issue.labels)
      assert {:ok, Claude, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config == %{}

      {:ok, session} = Claude.start_session(issue, "/tmp/ws", team_config)
      assert session.skills_repo == nil

      Claude.run_turn(session, "provision infra", [])

      assert_receive {:mock_cmd, "claude", args}
      refute "--add-skill-repo" in args
    end

    test "AgentRunner dispatches through full pipeline with team config" do
      issue = %Issue{
        id: "issue-4",
        identifier: "FE-401",
        labels: ["frontend"],
        title: "Add button",
        description: "Add a submit button",
        state: "Done"
      }

      workspace_root = Config.workspace_root()
      File.mkdir_p!(workspace_root)

      log =
        capture_log(fn ->
          AgentRunner.run(issue, nil,
            max_turns: 1,
            issue_state_fetcher: fn _ids ->
              {:ok, [%Issue{issue | state: "Done"}]}
            end
          )
        end)

      assert log =~ "Starting agent run"
      assert log =~ "Completed agent run"

      assert_receive {:mock_cmd, "claude", args}
      assert "--add-skill-repo" in args
      skill_idx = Enum.find_index(args, &(&1 == "--add-skill-repo"))
      assert Enum.at(args, skill_idx + 1) == "https://github.com/example/frontend-skills"
    end

    test "AgentRunner dispatches with no skills_repo when team has none" do
      issue = %Issue{
        id: "issue-5",
        identifier: "BE-501",
        labels: ["api"],
        title: "Fix endpoint",
        description: "Fix the /users endpoint",
        state: "Done"
      }

      workspace_root = Config.workspace_root()
      File.mkdir_p!(workspace_root)

      capture_log(fn ->
        AgentRunner.run(issue, nil,
          max_turns: 1,
          issue_state_fetcher: fn _ids ->
            {:ok, [%Issue{issue | state: "Done"}]}
          end
        )
      end)

      assert_receive {:mock_cmd, "claude", args}
      refute "--add-skill-repo" in args
    end

    test "AgentRunner dispatches with empty team config for unmatched labels" do
      issue = %Issue{
        id: "issue-6",
        identifier: "OPS-601",
        labels: ["ops"],
        title: "Update CI",
        description: "Update CI pipeline",
        state: "Done"
      }

      workspace_root = Config.workspace_root()
      File.mkdir_p!(workspace_root)

      capture_log(fn ->
        AgentRunner.run(issue, nil,
          max_turns: 1,
          issue_state_fetcher: fn _ids ->
            {:ok, [%Issue{issue | state: "Done"}]}
          end
        )
      end)

      assert_receive {:mock_cmd, "claude", args}
      refute "--add-skill-repo" in args
    end
  end

  describe "team routing with no teams configured" do
    test "full pipeline works without teams section" do
      issue = %Issue{id: "issue-7", identifier: "X-701", labels: ["claude"]}

      assert Config.teams() == []
      assert :none = Config.team_for_labels(issue.labels)
      assert {:ok, Claude, %{}} = AgentRouter.resolve_backend(issue)

      {:ok, session} = Claude.start_session(issue, "/tmp/ws", %{})
      assert session.skills_repo == nil
    end
  end

  defp workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path)
  end
end
