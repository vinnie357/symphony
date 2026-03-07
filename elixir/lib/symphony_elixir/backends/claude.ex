defmodule SymphonyElixir.Backends.Claude do
  @moduledoc """
  Backend that executes agent turns via the Claude Code CLI.

  Launches `claude` as a subprocess with `--output-format stream-json` and
  `--print` mode. Configuration is read from the `claude` section of
  WORKFLOW.md via `Config.claude_*` accessors.

  The `cmd_runner` is configurable via application env for test mocking:

      config :symphony_elixir, :cmd_runner, MyMockModule
  """

  @behaviour SymphonyElixir.Backend

  require Logger

  alias SymphonyElixir.Config

  @impl true
  def start_session(_issue, workspace, config) do
    {:ok, %{workspace: workspace, skills_repo: Map.get(config, :skills_repo)}}
  end

  @impl true
  def run_turn(session, prompt, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    workspace = session.workspace

    command = Config.claude_command()
    permission_mode = Config.claude_permission_mode()
    output_format = Config.claude_output_format()
    model = Config.execution_model()

    skills_repo = session[:skills_repo]

    args =
      build_args(prompt, permission_mode, output_format, model, skills_repo)

    env = build_env(workspace)

    Logger.info("Claude backend: running turn in #{workspace} with command=#{command}")

    case cmd_runner().cmd(command, args, stderr_to_stdout: true, cd: workspace, env: env) do
      {output, 0} ->
        on_message.(%{type: :turn_completed, output: output})
        {:ok, %{result: output, session_id: session_id(), turn_id: turn_id()}}

      {error, code} ->
        Logger.error("Claude CLI failed (exit #{code}): #{String.slice(error, 0, 500)}")
        {:error, {:claude_cli_failed, code, error}}
    end
  rescue
    e ->
      Logger.error("Claude CLI execution error: #{inspect(e)}")
      {:error, {:claude_cli_error, Exception.message(e)}}
  end

  @impl true
  def stop_session(_session), do: :ok

  defp build_args(prompt, permission_mode, output_format, model, skills_repo) do
    args = ["--print", "--output-format", output_format]

    args =
      if permission_mode do
        args ++ ["--permission-mode", permission_mode]
      else
        args
      end

    args =
      if model do
        args ++ ["--model", model]
      else
        args
      end

    args =
      if skills_repo do
        args ++ ["--add-skill-repo", skills_repo]
      else
        args
      end

    args ++ [prompt]
  end

  defp build_env(workspace) do
    base = [
      {"CLAUDECODE", nil},
      {"CLAUDE_CODE_ENTRYPOINT", nil},
      {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", nil}
    ]

    if is_binary(workspace) and workspace != "" do
      [{"CLAUDE_WORKSPACE", workspace} | base]
    else
      base
    end
  end

  defp session_id, do: "claude-#{System.unique_integer([:positive])}"
  defp turn_id, do: "turn-#{System.unique_integer([:positive])}"

  defp cmd_runner, do: Application.get_env(:symphony_elixir, :cmd_runner, System)
end
