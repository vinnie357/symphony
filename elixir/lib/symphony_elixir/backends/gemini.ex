defmodule SymphonyElixir.Backends.Gemini do
  @moduledoc """
  Backend that executes agent turns via the Gemini CLI.

  Launches `gemini` as a subprocess. Configuration is read from the `gemini`
  section of WORKFLOW.md via `Config.gemini_*` accessors.

  The `cmd_runner` is configurable via application env for test mocking:

      config :symphony_elixir, :cmd_runner, MyMockModule
  """

  @behaviour SymphonyElixir.Backend

  require Logger

  alias SymphonyElixir.Config

  @impl true
  def start_session(_issue, workspace, _config) do
    {:ok, %{workspace: workspace}}
  end

  @impl true
  def run_turn(session, prompt, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    workspace = session.workspace

    command = Config.gemini_command()
    model = Config.gemini_model()

    args = build_args(prompt, model)

    Logger.info("Gemini backend: running turn in #{workspace} with command=#{command}")

    case cmd_runner().cmd(command, args, stderr_to_stdout: true, cd: workspace) do
      {output, 0} ->
        on_message.(%{type: :turn_completed, output: output})
        {:ok, %{result: output, session_id: session_id(), turn_id: turn_id()}}

      {error, code} ->
        Logger.error("Gemini CLI failed (exit #{code}): #{String.slice(error, 0, 500)}")
        {:error, {:gemini_cli_failed, code, error}}
    end
  rescue
    e ->
      Logger.error("Gemini CLI execution error: #{inspect(e)}")
      {:error, {:gemini_cli_error, Exception.message(e)}}
  end

  @impl true
  def stop_session(_session), do: :ok

  defp build_args(prompt, model) do
    args =
      if model do
        ["--model", model]
      else
        []
      end

    args ++ [prompt]
  end

  defp session_id, do: "gemini-#{System.unique_integer([:positive])}"
  defp turn_id, do: "turn-#{System.unique_integer([:positive])}"

  defp cmd_runner, do: Application.get_env(:symphony_elixir, :cmd_runner, System)
end
