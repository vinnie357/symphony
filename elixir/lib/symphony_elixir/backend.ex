defmodule SymphonyElixir.Backend do
  @moduledoc """
  Behaviour defining the interface for Symphony agent backends.

  A backend is responsible for managing agent sessions and executing turns.
  The default implementation (`SymphonyElixir.Codex.AppServer`) communicates
  with Codex via JSON-RPC over stdio. Alternative implementations (e.g.,
  `SymphonyElixir.Backends.AppleSlicerAPI`) can delegate to an external
  service over HTTP.

  ## Session Lifecycle

      {:ok, session} = Backend.start_session(issue, workspace, config)
      {:ok, result}  = Backend.run_turn(session, prompt, opts)
      :ok            = Backend.stop_session(session)

  ## Implementing a Backend

  Modules that implement this behaviour must define three callbacks:

    * `start_session/3` -- Initialize a new agent session for the given issue
      and workspace. Returns an opaque session term that is threaded through
      subsequent calls.

    * `run_turn/3` -- Execute a single agent turn within the session. The
      `prompt` is the text input for the turn, and `opts` can carry
      backend-specific options such as `:on_message` callbacks.

    * `stop_session/1` -- Tear down the session and release any resources
      (ports, HTTP connections, temporary state).
  """

  @type issue :: map()
  @type workspace :: Path.t()
  @type config :: map()
  @type session :: term()
  @type turn_result :: map()

  @doc """
  Start a new agent session for the given issue and workspace.

  The `config` map may contain backend-specific settings (e.g., endpoint URL,
  approval policies, sandbox configuration).

  Returns `{:ok, session}` where `session` is an opaque term passed to
  `run_turn/3` and `stop_session/1`, or `{:error, reason}`.
  """
  @callback start_session(issue(), workspace(), config()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Execute a single agent turn within the given session.

  The `prompt` is the text input for the agent. `opts` is a keyword list
  that may include:

    * `:on_message` -- `(map() -> :ok)` callback for streaming events
    * `:tool_executor` -- `(String.t(), map() -> map())` for dynamic tool calls

  Returns `{:ok, result}` with a map containing at least `:result`,
  `:session_id`, `:thread_id`, and `:turn_id` keys, or `{:error, reason}`.
  """
  @callback run_turn(session(), prompt :: String.t(), opts :: keyword()) ::
              {:ok, turn_result()} | {:error, term()}

  @doc """
  Stop the session and release associated resources.

  This should be safe to call multiple times (idempotent).
  """
  @callback stop_session(session()) :: :ok
end
