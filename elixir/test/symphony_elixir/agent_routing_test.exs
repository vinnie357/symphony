defmodule SymphonyElixir.AgentRoutingTest do
  @moduledoc """
  Integration tests for the full label-based agent routing pipeline:
  AgentRouter -> Backend dispatch -> AgentRunner turn loop.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.Linear.Issue

  describe "label-based routing end-to-end" do
    test "issue labeled 'claude' resolves to Claude backend" do
      issue = %Issue{id: "1", identifier: "TEST-1", labels: ["claude"]}
      assert {:ok, SymphonyElixir.Backends.Claude, _} = AgentRouter.resolve_backend(issue)
    end

    test "issue labeled 'codex' resolves to Codex backend" do
      issue = %Issue{id: "2", identifier: "TEST-2", labels: ["codex"]}
      assert {:ok, SymphonyElixir.Backends.Codex, _} = AgentRouter.resolve_backend(issue)
    end

    test "issue labeled 'gemini' resolves to Gemini backend" do
      issue = %Issue{id: "3", identifier: "TEST-3", labels: ["gemini"]}
      assert {:ok, SymphonyElixir.Backends.Gemini, _} = AgentRouter.resolve_backend(issue)
    end

    test "issue with no agent label defaults to config backend" do
      write_workflow_file!(Workflow.workflow_file_path(), execution_backend: "codex")
      issue = %Issue{id: "4", identifier: "TEST-4", labels: ["bug", "priority:high"]}
      assert {:ok, SymphonyElixir.Backends.Codex, _} = AgentRouter.resolve_backend(issue)
    end

    test "issue with no agent label and default config resolves to codex" do
      issue = %Issue{id: "5", identifier: "TEST-5", labels: []}
      # Default execution_backend is "codex"
      assert {:ok, SymphonyElixir.Backends.Codex, _} = AgentRouter.resolve_backend(issue)
    end

    test "config execution_backend override changes default" do
      write_workflow_file!(Workflow.workflow_file_path(), execution_backend: "claude")
      issue = %Issue{id: "6", identifier: "TEST-6", labels: []}
      assert {:ok, SymphonyElixir.Backends.Claude, _} = AgentRouter.resolve_backend(issue)
    end

    test "config execution_backend gemini changes default" do
      write_workflow_file!(Workflow.workflow_file_path(), execution_backend: "gemini")
      issue = %Issue{id: "7", identifier: "TEST-7", labels: ["frontend"]}
      assert {:ok, SymphonyElixir.Backends.Gemini, _} = AgentRouter.resolve_backend(issue)
    end

    test "agent label overrides config default" do
      write_workflow_file!(Workflow.workflow_file_path(), execution_backend: "codex")
      issue = %Issue{id: "8", identifier: "TEST-8", labels: ["claude", "bug"]}
      # Label wins over config default
      assert {:ok, SymphonyElixir.Backends.Claude, _} = AgentRouter.resolve_backend(issue)
    end

    test "case-insensitive label matching works" do
      assert {:ok, SymphonyElixir.Backends.Claude, _} =
               AgentRouter.resolve_backend(%Issue{id: "9", labels: ["Claude"]})

      assert {:ok, SymphonyElixir.Backends.Codex, _} =
               AgentRouter.resolve_backend(%Issue{id: "10", labels: ["CODEX"]})

      assert {:ok, SymphonyElixir.Backends.Gemini, _} =
               AgentRouter.resolve_backend(%Issue{id: "11", labels: ["Gemini"]})
    end

    test "priority order: claude > codex > gemini when multiple agent labels" do
      issue = %Issue{id: "12", identifier: "TEST-12", labels: ["gemini", "claude", "codex"]}
      assert {:ok, SymphonyElixir.Backends.Claude, _} = AgentRouter.resolve_backend(issue)

      issue = %Issue{id: "13", identifier: "TEST-13", labels: ["gemini", "codex"]}
      assert {:ok, SymphonyElixir.Backends.Codex, _} = AgentRouter.resolve_backend(issue)
    end

    test "apple-slicer-api backend is reachable via backend_for" do
      assert {:ok, SymphonyElixir.Backends.AppleSlicerAPI} =
               AgentRouter.backend_for("apple-slicer-api")
    end

    test "unknown backend returns error" do
      assert {:error, {:unknown_backend, "llama"}} = AgentRouter.backend_for("llama")
    end

    test "all backends implement the Backend behaviour" do
      for {_name, module} <- [
            {"claude", SymphonyElixir.Backends.Claude},
            {"gemini", SymphonyElixir.Backends.Gemini},
            {"codex", SymphonyElixir.Backends.Codex},
            {"apple-slicer-api", SymphonyElixir.Backends.AppleSlicerAPI}
          ] do
        behaviours =
          module.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert SymphonyElixir.Backend in behaviours,
               "#{inspect(module)} does not implement Backend behaviour"
      end
    end
  end
end
