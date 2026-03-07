defmodule SymphonyElixir.ConfigTeamsTest do
  use SymphonyElixir.TestSupport

  describe "Config.teams/0" do
    test "returns empty list when no teams configured" do
      assert Config.teams() == []
    end

    test "returns parsed team definitions" do
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
            "backend" => "codex"
          }
        ]
      )

      teams = Config.teams()
      assert length(teams) == 2

      [frontend, backend] = teams
      assert frontend.name == "frontend"
      assert frontend.labels == ["frontend", "ui"]
      assert frontend.backend == "claude"
      assert frontend.model == "claude-sonnet-4-5-20250514"
      assert frontend.skills_repo == "https://github.com/example/frontend-skills"
      assert frontend.permission_mode == "plan"

      assert backend.name == "backend"
      assert backend.labels == ["backend", "api"]
      assert backend.backend == "codex"
      assert backend.model == nil
      assert backend.skills_repo == nil
      assert backend.permission_mode == nil
    end
  end

  describe "Config.team_for_labels/1" do
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

    test "matches team when issue has a matching label" do
      {:ok, team} = Config.team_for_labels(["frontend"])
      assert team.name == "frontend"
      assert team.backend == "claude"
    end

    test "matches team when issue has one of several matching labels" do
      {:ok, team} = Config.team_for_labels(["ui"])
      assert team.name == "frontend"
    end

    test "matches first team when multiple labels match different teams" do
      {:ok, team} = Config.team_for_labels(["frontend", "backend"])
      assert team.name == "frontend"
    end

    test "returns :none when no team matches" do
      assert Config.team_for_labels(["infra"]) == :none
    end

    test "returns :none for empty label list" do
      assert Config.team_for_labels([]) == :none
    end

    test "matched team provides backend, model, skills_repo, and permission_mode" do
      {:ok, team} = Config.team_for_labels(["api"])
      assert team.name == "backend"
      assert team.backend == "codex"
      assert team.model == "gpt-5.3-codex"
      assert team.skills_repo == nil
      assert team.permission_mode == nil
    end

    test "ignores non-matching labels on the issue" do
      {:ok, team} = Config.team_for_labels(["infra", "ui", "urgent"])
      assert team.name == "frontend"
    end
  end

  defp workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path)
  end
end
