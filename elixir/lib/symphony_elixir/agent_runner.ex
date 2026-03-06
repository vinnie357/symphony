defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace using the
  backend resolved from the issue's labels via `AgentRouter`.
  """

  require Logger
  alias SymphonyElixir.{AgentRouter, Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, codex_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, codex_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _codex_update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, backend} <- AgentRouter.resolve_backend(issue),
         {:ok, session} <- backend.start_session(issue, workspace, %{}) do
      send_codex_update(codex_update_recipient, issue, %{
        event: :backend_started,
        timestamp: DateTime.utc_now(),
        backend_name: backend_display_name(backend),
        execution_model: Config.execution_model()
      })

      ctx = %{
        backend: backend,
        session: session,
        workspace: workspace,
        recipient: codex_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        max_turns: max_turns
      }

      try do
        do_run_codex_turns(ctx, issue, 1)
      after
        backend.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(ctx, issue, turn_number) do
    prompt = build_turn_prompt(issue, ctx.opts, turn_number, ctx.max_turns)

    with {:ok, turn_session} <-
           ctx.backend.run_turn(
             ctx.session,
             prompt,
             issue: issue,
             on_message: codex_message_handler(ctx.recipient, issue)
           ) do
      Logger.info(
        "Completed agent run for #{issue_context(issue)}" <>
          " session_id=#{turn_session[:session_id]}" <>
          " workspace=#{ctx.workspace} turn=#{turn_number}/#{ctx.max_turns}"
      )

      maybe_continue(ctx, issue, turn_number)
    end
  end

  defp maybe_continue(ctx, issue, turn_number) do
    case continue_with_issue?(issue, ctx.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < ctx.max_turns ->
        Logger.info(
          "Continuing agent run for #{issue_context(refreshed_issue)}" <>
            " after normal turn completion turn=#{turn_number}/#{ctx.max_turns}"
        )

        do_run_codex_turns(ctx, refreshed_issue, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info(
          "Reached agent.max_turns for #{issue_context(refreshed_issue)}" <>
            " with issue still active; returning control to orchestrator"
        )

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  @backend_display_names %{
    SymphonyElixir.Backends.Claude => "Claude",
    SymphonyElixir.Backends.Codex => "Codex",
    SymphonyElixir.Backends.Gemini => "Gemini",
    SymphonyElixir.Backends.AppleSlicerAPI => "Apple Slicer"
  }

  defp backend_display_name(module) when is_atom(module) do
    Map.get(@backend_display_names, module, inspect(module))
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
