defmodule SymphonyElixir.AgentRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.Linear.Issue

  describe "resolve_backend/1" do
    test "routes claude-labeled issue to Claude backend" do
      issue = %Issue{labels: ["claude"]}
      assert {:ok, SymphonyElixir.Backends.Claude} = AgentRouter.resolve_backend(issue)
    end

    test "routes codex-labeled issue to Codex backend" do
      issue = %Issue{labels: ["codex"]}
      assert {:ok, SymphonyElixir.Backends.Codex} = AgentRouter.resolve_backend(issue)
    end

    test "routes gemini-labeled issue to Gemini backend" do
      issue = %Issue{labels: ["gemini"]}
      assert {:ok, SymphonyElixir.Backends.Gemini} = AgentRouter.resolve_backend(issue)
    end

    test "case-insensitive label matching" do
      assert {:ok, SymphonyElixir.Backends.Claude} =
               AgentRouter.resolve_backend(%Issue{labels: ["Claude"]})

      assert {:ok, SymphonyElixir.Backends.Codex} =
               AgentRouter.resolve_backend(%Issue{labels: ["CODEX"]})

      assert {:ok, SymphonyElixir.Backends.Gemini} =
               AgentRouter.resolve_backend(%Issue{labels: ["Gemini"]})
    end

    test "multiple agent labels uses priority order (claude > codex > gemini)" do
      issue = %Issue{labels: ["gemini", "claude", "codex"]}
      assert {:ok, SymphonyElixir.Backends.Claude} = AgentRouter.resolve_backend(issue)

      issue = %Issue{labels: ["gemini", "codex"]}
      assert {:ok, SymphonyElixir.Backends.Codex} = AgentRouter.resolve_backend(issue)
    end

    test "non-agent labels are ignored, falls back to default" do
      issue = %Issue{labels: ["bug", "frontend", "priority:high"]}
      assert {:ok, _module} = AgentRouter.resolve_backend(issue)
    end

    test "empty labels falls back to default" do
      issue = %Issue{labels: []}
      assert {:ok, _module} = AgentRouter.resolve_backend(issue)
    end

    test "nil issue falls back to default" do
      assert {:ok, _module} = AgentRouter.resolve_backend(nil)
    end

    test "agent label mixed with other labels" do
      issue = %Issue{labels: ["bug", "gemini", "priority:high"]}
      assert {:ok, SymphonyElixir.Backends.Gemini} = AgentRouter.resolve_backend(issue)
    end
  end

  describe "backend_for/1" do
    test "returns module for known backends" do
      assert {:ok, SymphonyElixir.Backends.Claude} = AgentRouter.backend_for("claude")
      assert {:ok, SymphonyElixir.Backends.Codex} = AgentRouter.backend_for("codex")
      assert {:ok, SymphonyElixir.Backends.Gemini} = AgentRouter.backend_for("gemini")
      assert {:ok, SymphonyElixir.Backends.AppleSlicerAPI} = AgentRouter.backend_for("apple-slicer-api")
    end

    test "returns error for unknown backend" do
      assert {:error, {:unknown_backend, "unknown"}} = AgentRouter.backend_for("unknown")
    end

    test "case-insensitive lookup" do
      assert {:ok, SymphonyElixir.Backends.Claude} = AgentRouter.backend_for("Claude")
      assert {:ok, SymphonyElixir.Backends.Claude} = AgentRouter.backend_for("CLAUDE")
    end
  end

  describe "known_agent_labels/0" do
    test "returns all supported agent labels" do
      labels = AgentRouter.known_agent_labels()
      assert "claude" in labels
      assert "codex" in labels
      assert "gemini" in labels
    end
  end
end
