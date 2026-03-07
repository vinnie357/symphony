defmodule SymphonyElixir.ConfigTeamsSchemaTest do
  use SymphonyElixir.TestSupport

  describe "teams schema in NimbleOptions" do
    test "workflow without teams section validates successfully (backward compatible)" do
      # Default TestSupport workflow has no teams section
      assert Config.validate!() == :ok
    end

    test "workflow with empty teams list validates successfully" do
      write_workflow_file!(workflow_file_path(), teams: [])
      assert Config.validate!() == :ok
    end

    test "workflow with valid team definition validates successfully" do
      write_workflow_file!(workflow_file_path(),
        teams: [
          %{
            "name" => "frontend",
            "labels" => ["frontend", "ui"],
            "backend" => "claude",
            "model" => "claude-sonnet-4-5-20250514",
            "skills_repo" => "https://github.com/example/frontend-skills",
            "permission_mode" => "plan"
          }
        ]
      )

      assert Config.validate!() == :ok
    end

    test "workflow with multiple teams validates successfully" do
      write_workflow_file!(workflow_file_path(),
        teams: [
          %{
            "name" => "frontend",
            "labels" => ["frontend", "ui"],
            "backend" => "claude",
            "model" => "claude-sonnet-4-5-20250514"
          },
          %{
            "name" => "backend",
            "labels" => ["backend", "api"],
            "backend" => "codex"
          }
        ]
      )

      assert Config.validate!() == :ok
    end

    test "team definition requires name" do
      write_workflow_file!(workflow_file_path(),
        teams: [
          %{
            "labels" => ["frontend"],
            "backend" => "claude"
          }
        ]
      )

      assert_raise NimbleOptions.ValidationError, fn ->
        Config.validate!()
      end
    end

    test "team definition requires labels" do
      write_workflow_file!(workflow_file_path(),
        teams: [
          %{
            "name" => "frontend",
            "backend" => "claude"
          }
        ]
      )

      assert_raise NimbleOptions.ValidationError, fn ->
        Config.validate!()
      end
    end

    test "team with only name and labels validates (backend/model/etc are optional)" do
      write_workflow_file!(workflow_file_path(),
        teams: [
          %{
            "name" => "default-team",
            "labels" => ["general"]
          }
        ]
      )

      assert Config.validate!() == :ok
    end

    test "validated options include parsed teams data" do
      write_workflow_file!(workflow_file_path(),
        teams: [
          %{
            "name" => "frontend",
            "labels" => ["frontend", "ui"],
            "backend" => "claude",
            "model" => "claude-sonnet-4-5-20250514",
            "skills_repo" => "https://github.com/example/skills",
            "permission_mode" => "plan"
          }
        ]
      )

      # Validation should pass — actual Config.teams/0 accessor is bead 9h6.4.2
      assert Config.validate!() == :ok
    end
  end

  defp workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path)
  end
end
