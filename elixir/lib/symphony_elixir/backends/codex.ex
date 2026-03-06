defmodule SymphonyElixir.Backends.Codex do
  @moduledoc """
  Backend adapter wrapping the existing `Codex.AppServer` to conform to the
  `Backend` behaviour interface.

  This bridges the signature gap between AppServer's current API and the
  Backend callbacks, threading the issue through session state for `run_turn/3`.
  """

  @behaviour SymphonyElixir.Backend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(_issue, workspace, _config) do
    case AppServer.start_session(workspace) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run_turn(session, prompt, opts) do
    issue = Keyword.fetch!(opts, :issue)
    on_message = Keyword.get(opts, :on_message)

    run_opts =
      if on_message, do: [on_message: on_message], else: []

    AppServer.run_turn(session, prompt, issue, run_opts)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end
end
