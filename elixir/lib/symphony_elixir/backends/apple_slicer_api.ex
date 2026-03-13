defmodule SymphonyElixir.Backends.AppleSlicerAPI do
  @moduledoc """
  Backend that delegates agent execution to apple-slicer's REST API.

  Instead of spawning a local Codex process via JSON-RPC over stdio, this
  backend submits runs to an apple-slicer instance and polls for completion.

  ## Configuration

  The backend reads its configuration from the `config` map passed to
  `start_session/3`. The following keys are recognized:

    * `:base_url` -- Base URL of the apple-slicer instance
      (e.g., `"http://localhost:4000"`). Falls back to the
      `APPLE_SLICER_URL` environment variable, then to
      `"http://localhost:4000"`.

    * `:poll_interval_ms` -- Milliseconds between status polls while
      waiting for a run or turn to complete. Defaults to `2_000`.

    * `:run_timeout_ms` -- Maximum time to wait for a run to reach a
      terminal state before returning a timeout error. Defaults to
      `3_600_000` (1 hour).

    * `:max_turns` -- Maximum number of turns to allow. Defaults to `20`.

    * `:workspace_root` -- Override for the workspace root directory
      sent to apple-slicer.

  ## Session Structure

  The session returned by `start_session/3` is a map with the following keys:

    * `:run_id` -- The apple-slicer run ID
    * `:issue` -- The original issue map
    * `:workspace` -- The workspace path
    * `:config` -- The merged configuration
    * `:req` -- A pre-configured `Req` client
    * `:status` -- The last known run status

  ## API Endpoints Used

    * `POST /api/symphony/runs` -- Submit a new run
    * `GET /api/symphony/runs/:id` -- Poll run status
    * `POST /api/symphony/runs/:id/turns` -- Trigger the next turn
    * `DELETE /api/symphony/runs/:id` -- Cancel a run
  """

  @behaviour SymphonyElixir.Backend

  require Logger

  @default_base_url "http://localhost:4000"
  @default_poll_interval_ms 2_000
  @default_run_timeout_ms 3_600_000
  @default_max_turns 20

  @terminal_statuses ~w(completed failed cancelled)

  # ---------------------------------------------------------------------------
  # Backend callbacks
  # ---------------------------------------------------------------------------

  @impl SymphonyElixir.Backend
  def start_session(issue, workspace, config \\ %{}) do
    merged_config = merge_config(config)
    req = build_req_client(merged_config)

    body = build_create_run_body(issue, workspace, merged_config)

    case Req.post(req, url: "/api/symphony/runs", json: body) do
      {:ok, %Req.Response{status: 201, body: %{"run" => run}}} ->
        run_id = run["id"]
        Logger.info("apple-slicer run created: run_id=#{run_id} issue=#{issue_identifier(issue)}")

        session = %{
          run_id: run_id,
          issue: issue,
          workspace: workspace,
          config: merged_config,
          req: req,
          status: run["status"] || "pending"
        }

        {:ok, session}

      {:ok, %Req.Response{status: 409, body: body}} ->
        {:error, {:already_running, body["error"] || "already_running"}}

      {:ok, %Req.Response{status: 503, body: body}} ->
        {:error, {:unavailable, body["error"] || "service_unavailable"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @impl SymphonyElixir.Backend
  def run_turn(session, prompt, opts \\ []) do
    %{run_id: run_id, req: req, config: config} = session
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    body =
      %{}
      |> maybe_put("prompt_override", prompt)
      |> maybe_put("max_remaining_turns", Keyword.get(opts, :max_remaining_turns))

    case Req.post(req, url: "/api/symphony/runs/#{run_id}/turns", json: body) do
      {:ok, %Req.Response{status: 202, body: %{"turn" => turn}}} ->
        turn_number = turn["turn_number"]
        Logger.info("apple-slicer turn triggered: run_id=#{run_id} turn=#{turn_number}")

        emit_message(on_message, :turn_started, %{
          run_id: run_id,
          turn_number: turn_number,
          triggered_at: turn["triggered_at"]
        })

        poll_until_complete(session, on_message, config)

      {:ok, %Req.Response{status: 404}} ->
        {:error, :run_not_found}

      {:ok, %Req.Response{status: 409, body: body}} ->
        {:error, {:not_continuable, body["error"] || "not_continuable"}}

      {:ok, %Req.Response{status: 503, body: body}} ->
        {:error, {:unavailable, body["error"] || "service_unavailable"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @impl SymphonyElixir.Backend
  def stop_session(%{run_id: run_id, req: req, status: status}) do
    if status in @terminal_statuses do
      :ok
    else
      case Req.delete(req, url: "/api/symphony/runs/#{run_id}") do
        {:ok, %Req.Response{status: 200}} ->
          Logger.info("apple-slicer run cancelled: run_id=#{run_id}")
          :ok

        {:ok, %Req.Response{status: 409}} ->
          # Already in a terminal state, nothing to do
          :ok

        {:ok, %Req.Response{status: 404}} ->
          # Run not found, nothing to clean up
          :ok

        {:ok, %Req.Response{status: status_code, body: body}} ->
          Logger.warning("Unexpected response cancelling apple-slicer run: run_id=#{run_id} status=#{status_code} body=#{inspect(body)}")

          :ok

        {:error, reason} ->
          Logger.warning("Failed to cancel apple-slicer run: run_id=#{run_id} error=#{inspect(reason)}")

          :ok
      end
    end
  end

  def stop_session(_session), do: :ok

  # ---------------------------------------------------------------------------
  # Public helpers (useful for callers that need direct API access)
  # ---------------------------------------------------------------------------

  @doc """
  Fetch the current status of a run from apple-slicer.

  Returns `{:ok, run_map}` or `{:error, reason}`.
  """
  @spec get_run(map()) :: {:ok, map()} | {:error, term()}
  def get_run(%{run_id: run_id, req: req}) do
    case Req.get(req, url: "/api/symphony/runs/#{run_id}") do
      {:ok, %Req.Response{status: 200, body: %{"run" => run}}} ->
        {:ok, run}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  List runs from apple-slicer with optional filters.

  `opts` may include `:status`, `:limit`, and `:offset`.
  """
  @spec list_runs(Req.Request.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_runs(req_or_session, opts \\ [])

  def list_runs(%{req: req}, opts), do: list_runs(req, opts)

  def list_runs(%Req.Request{} = req, opts) do
    params =
      %{}
      |> maybe_put("status", Keyword.get(opts, :status))
      |> maybe_put("limit", Keyword.get(opts, :limit))
      |> maybe_put("offset", Keyword.get(opts, :offset))

    case Req.get(req, url: "/api/symphony/runs", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp merge_config(config) when is_map(config) do
    %{
      base_url: resolve_base_url(config),
      poll_interval_ms: Map.get(config, :poll_interval_ms, @default_poll_interval_ms),
      run_timeout_ms: Map.get(config, :run_timeout_ms, @default_run_timeout_ms),
      max_turns: Map.get(config, :max_turns, @default_max_turns),
      workspace_root: Map.get(config, :workspace_root)
    }
  end

  defp resolve_base_url(config) do
    case Map.get(config, :base_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        case System.get_env("APPLE_SLICER_URL") do
          url when is_binary(url) and url != "" ->
            String.trim_trailing(url, "/")

          _ ->
            @default_base_url
        end
    end
  end

  defp build_req_client(config) do
    Req.new(
      base_url: config.base_url,
      headers: [
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ],
      receive_timeout: config.run_timeout_ms,
      retry: :transient,
      max_retries: 3
    )
  end

  defp build_create_run_body(issue, workspace, config) do
    issue_payload = serialize_issue(issue)

    options =
      %{}
      |> maybe_put("max_turns", config.max_turns)
      |> maybe_put("workspace_root", config.workspace_root || workspace_root_from(workspace))

    %{
      "issue" => issue_payload,
      "options" => options
    }
  end

  defp serialize_issue(%{__struct__: _} = issue) do
    issue
    |> Map.from_struct()
    |> serialize_issue()
  end

  defp serialize_issue(issue) when is_map(issue) do
    %{}
    |> maybe_put("id", map_get(issue, [:id]))
    |> maybe_put("identifier", map_get(issue, [:identifier]))
    |> maybe_put("title", map_get(issue, [:title]))
    |> maybe_put("description", map_get(issue, [:description]))
    |> maybe_put("priority", map_get(issue, [:priority]))
    |> maybe_put("state", map_get(issue, [:state]))
    |> maybe_put("branch_name", map_get(issue, [:branch_name]))
    |> maybe_put("url", map_get(issue, [:url]))
    |> maybe_put("assignee_id", map_get(issue, [:assignee_id]))
    |> maybe_put("labels", map_get(issue, [:labels]))
    |> maybe_put("blocked_by", map_get(issue, [:blocked_by]))
  end

  defp map_get(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp workspace_root_from(workspace) when is_binary(workspace) do
    Path.dirname(Path.expand(workspace))
  end

  defp workspace_root_from(_workspace), do: nil

  defp poll_until_complete(session, on_message, config) do
    deadline = System.monotonic_time(:millisecond) + config.run_timeout_ms
    poll_interval = config.poll_interval_ms

    do_poll(session, on_message, poll_interval, deadline)
  end

  defp do_poll(session, on_message, poll_interval, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :run_timeout}
    else
      Process.sleep(poll_interval)

      case get_run(session) do
        {:ok, run} ->
          handle_poll_result(session, run, on_message, poll_interval, deadline)

        {:error, reason} ->
          Logger.warning("Failed to poll apple-slicer run status: run_id=#{session.run_id} error=#{inspect(reason)}")

          # Retry polling on transient errors
          do_poll(session, on_message, poll_interval, deadline)
      end
    end
  end

  defp handle_poll_result(session, run, on_message, poll_interval, deadline) do
    status = run["status"]
    updated_session = %{session | status: status}

    emit_message(on_message, :run_status_update, %{
      run_id: session.run_id,
      status: status,
      turn_count: run["turn_count"],
      codex_input_tokens: run["codex_input_tokens"],
      codex_output_tokens: run["codex_output_tokens"],
      codex_total_tokens: run["codex_total_tokens"],
      last_codex_event: run["last_codex_event"],
      runtime_seconds: run["runtime_seconds"]
    })

    case status do
      "completed" ->
        Logger.info("apple-slicer run completed: run_id=#{session.run_id}")

        {:ok,
         %{
           result: :turn_completed,
           session_id: run["session_id"],
           thread_id: run["session_id"],
           turn_id: to_string(run["turn_count"]),
           run: run
         }}

      "failed" ->
        error = run["error"] || "unknown_error"
        Logger.warning("apple-slicer run failed: run_id=#{session.run_id} error=#{error}")
        {:error, {:run_failed, error}}

      "cancelled" ->
        Logger.info("apple-slicer run cancelled: run_id=#{session.run_id}")
        {:error, {:run_cancelled, run}}

      _active ->
        do_poll(updated_session, on_message, poll_interval, deadline)
    end
  end

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message =
      details
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp issue_identifier(%{identifier: id}) when is_binary(id), do: id
  defp issue_identifier(%{id: id}) when is_binary(id), do: id
  defp issue_identifier(_issue), do: "unknown"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
