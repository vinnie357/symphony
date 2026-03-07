defmodule SymphonyElixir.AgentRouterTeamTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.Linear.Issue

  describe "team-based routing" do
    setup do
      write_workflow_file!(workflow_file_path(),
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
            "backend" => "codex",
            "model" => "gpt-5.3-codex"
          }
        ]
      )

      :ok
    end

    test "team match routes to team-specified backend" do
      issue = %Issue{labels: ["frontend"]}
      assert {:ok, SymphonyElixir.Backends.Claude, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config.name == "frontend"
      assert team_config.backend == "claude"
    end

    test "team match takes priority over bare label match" do
      # Issue has both a team label ("frontend") and a bare agent label ("codex")
      # Team match should win
      issue = %Issue{labels: ["codex", "frontend"]}
      assert {:ok, SymphonyElixir.Backends.Claude, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config.name == "frontend"
    end

    test "team config includes model, skills_repo, and permission_mode" do
      issue = %Issue{labels: ["frontend"]}
      assert {:ok, _module, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config.model == "claude-sonnet-4-5-20250514"
      assert team_config.skills_repo == "https://github.com/example/frontend-skills"
      assert team_config.permission_mode == "plan"
    end

    test "second team matches its labels" do
      issue = %Issue{labels: ["api"]}
      assert {:ok, SymphonyElixir.Backends.Codex, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config.name == "backend"
    end

    test "unknown team label falls back to bare label match" do
      issue = %Issue{labels: ["gemini"]}
      assert {:ok, SymphonyElixir.Backends.Gemini, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config == %{}
    end

    test "no matching team or agent label falls back to default backend" do
      issue = %Issue{labels: ["infra", "docs"]}
      assert {:ok, _module, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config == %{}
    end

    test "empty labels falls back to default backend with empty config" do
      issue = %Issue{labels: []}
      assert {:ok, _module, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config == %{}
    end
  end

  describe "team routing with no teams configured" do
    test "bare label routing still works with empty team config" do
      issue = %Issue{labels: ["claude"]}
      assert {:ok, SymphonyElixir.Backends.Claude, team_config} = AgentRouter.resolve_backend(issue)
      assert team_config == %{}
    end

    test "nil issue falls back to default with empty config" do
      assert {:ok, _module, team_config} = AgentRouter.resolve_backend(nil)
      assert team_config == %{}
    end
  end

  defp workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path)
  end
end
