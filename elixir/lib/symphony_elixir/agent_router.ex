defmodule SymphonyElixir.AgentRouter do
  @moduledoc """
  Resolves which Backend module to use for a given Linear issue based on its labels.

  Users label Linear issues with an agent type (e.g., "claude", "codex", "gemini")
  to route work to the appropriate backend. When no agent label is present, falls
  back to `Config.execution_backend()` (default: "codex").
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @agent_label_priority ["claude", "codex", "gemini"]

  @backend_modules %{
    "claude" => SymphonyElixir.Backends.Claude,
    "codex" => SymphonyElixir.Backends.Codex,
    "gemini" => SymphonyElixir.Backends.Gemini,
    "apple-slicer-api" => SymphonyElixir.Backends.AppleSlicerAPI
  }

  @spec resolve_backend(Issue.t()) :: {:ok, module()} | {:error, {:unknown_backend, String.t()}}
  def resolve_backend(%Issue{labels: labels}) do
    labels
    |> find_agent_label()
    |> Kernel.||(Config.execution_backend())
    |> lookup_backend()
  end

  def resolve_backend(_issue) do
    lookup_backend(Config.execution_backend())
  end

  @spec known_agent_labels() :: [String.t()]
  def known_agent_labels, do: @agent_label_priority

  @spec backend_for(String.t()) :: {:ok, module()} | {:error, {:unknown_backend, String.t()}}
  def backend_for(name), do: lookup_backend(name)

  defp find_agent_label(labels) when is_list(labels) do
    normalized = Enum.map(labels, &String.downcase/1)

    Enum.find(@agent_label_priority, fn agent_label ->
      agent_label in normalized
    end)
  end

  defp find_agent_label(_), do: nil

  defp lookup_backend(name) when is_binary(name) do
    case Map.fetch(@backend_modules, String.downcase(name)) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_backend, name}}
    end
  end
end
