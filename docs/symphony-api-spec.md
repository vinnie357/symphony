# Symphony API Surface for apple-slicer

> Task 1.4 -- Defines the API contract between Symphony's orchestrator and
> apple-slicer, covering both a REST API (Option A) and an internal Elixir
> context API (Option B).

---

## 1. Background and Motivation

Symphony's orchestrator (`SymphonyElixir.Orchestrator`) is a GenServer that
polls a tracker (Linear) for candidate issues, dispatches them to
`SymphonyElixir.AgentRunner`, and manages the lifecycle of each run (start,
monitor, retry, cancel, reconcile terminal states). Today it operates as a
standalone Elixir application with its own terminal dashboard.

The goal of this spec is to define the API surface that apple-slicer needs so
that Symphony runs can be submitted, observed, cancelled, and continued from
apple-slicer -- either through HTTP endpoints (for external callers, webhooks,
or a future UI) or through in-process Elixir function calls (for LiveView
pages and internal Oban jobs).

---

## 2. Domain Model

The following data structures are derived from the existing Symphony codebase.

### 2.1 Issue (input to a run)

Source: `SymphonyElixir.Linear.Issue`

```elixir
%{
  id:                String.t(),          # tracker-assigned unique ID
  identifier:        String.t(),          # human-readable identifier, e.g. "PROJ-123"
  title:             String.t(),
  description:       String.t() | nil,
  priority:          integer() | nil,      # 1 (urgent) through 4 (low); nil = unset
  state:             String.t(),           # e.g. "Todo", "In Progress", "Done"
  branch_name:       String.t() | nil,
  url:               String.t() | nil,
  assignee_id:       String.t() | nil,
  labels:            [String.t()],
  assigned_to_worker: boolean(),
  created_at:        DateTime.t() | nil,
  updated_at:        DateTime.t() | nil
}
```

### 2.2 Run (output / state of execution)

A "run" represents a single orchestrator dispatch of an issue to the
AgentRunner. It maps to the `running` entry inside the orchestrator state.

```elixir
%{
  id:                   String.t(),      # unique run ID (could be UUID)
  issue_id:             String.t(),
  identifier:           String.t(),      # issue identifier, e.g. "PROJ-123"
  status:               :pending | :running | :completed | :failed | :cancelled | :retrying,
  session_id:           String.t() | nil,
  turn_count:           non_neg_integer(),
  codex_input_tokens:   non_neg_integer(),
  codex_output_tokens:  non_neg_integer(),
  codex_total_tokens:   non_neg_integer(),
  started_at:           DateTime.t() | nil,
  last_activity_at:     DateTime.t() | nil,
  last_codex_event:     atom() | nil,
  last_codex_message:   map() | nil,
  retry_attempt:        non_neg_integer(),
  error:                String.t() | nil,
  runtime_seconds:      non_neg_integer()
}
```

### 2.3 Turn (a single Codex turn within a run)

The AgentRunner can execute multiple turns within a single run (up to
`agent.max_turns`, default 20). Each turn corresponds to one
`AppServer.run_turn/4` call.

```elixir
%{
  turn_number:   pos_integer(),     # 1-indexed
  session_id:    String.t(),        # "{thread_id}-{turn_id}"
  thread_id:     String.t(),
  turn_id:       String.t(),
  result:        :turn_completed | :turn_failed | :turn_cancelled | nil,
  started_at:    DateTime.t(),
  completed_at:  DateTime.t() | nil
}
```

---

## 3. Option A -- REST API Contract

These endpoints would be added to apple-slicer's existing `scope "/api"` block
in `AppleSlicerWeb.Router`, following the existing controller patterns
(`ComputeController`, `PoolController`, etc.).

### 3.1 Router additions

```elixir
scope "/api", AppleSlicerWeb do
  pipe_through :api

  # ... existing routes ...

  post   "/symphony/runs",             SymphonyController, :create
  get    "/symphony/runs",             SymphonyController, :index
  get    "/symphony/runs/:id",         SymphonyController, :show
  delete "/symphony/runs/:id",         SymphonyController, :cancel
  post   "/symphony/runs/:id/turns",   SymphonyController, :trigger_turn
end
```

### 3.2 POST /api/symphony/runs

Submit an issue for agent execution.

**Request body:**

```json
{
  "issue": {
    "id": "abc-123-uuid",
    "identifier": "PROJ-42",
    "title": "Fix login timeout on mobile",
    "description": "Users report that...",
    "priority": 2,
    "state": "In Progress",
    "branch_name": "vinnie/proj-42-fix-login",
    "url": "https://linear.app/team/issue/PROJ-42",
    "assignee_id": "user-uuid",
    "labels": ["bug", "mobile"],
    "blocked_by": []
  },
  "options": {
    "max_turns": 10,
    "workspace_root": "/tmp/symphony_workspaces"
  }
}
```

**Response `201 Created`:**

```json
{
  "run": {
    "id": "run_01JEXAMPLE",
    "issue_id": "abc-123-uuid",
    "identifier": "PROJ-42",
    "status": "pending",
    "session_id": null,
    "turn_count": 0,
    "started_at": "2026-03-05T12:00:00Z",
    "retry_attempt": 0,
    "error": null
  }
}
```

**Error responses:**

| Status | Condition |
|--------|-----------|
| `400`  | Missing required fields (`id`, `identifier`, `title`, `state`) |
| `409`  | A run for this `issue_id` is already active |
| `422`  | Validation failure (e.g., issue in terminal state) |
| `503`  | Orchestrator unavailable or no slots available |

### 3.3 GET /api/symphony/runs

List runs with optional filters.

**Query parameters:**

| Param    | Type   | Description |
|----------|--------|-------------|
| `status` | string | Filter by status: `pending`, `running`, `completed`, `failed`, `cancelled`, `retrying` |
| `limit`  | int    | Max results (default 50, max 200) |
| `offset` | int    | Pagination offset (default 0) |

**Response `200 OK`:**

```json
{
  "runs": [
    {
      "id": "run_01JEXAMPLE",
      "issue_id": "abc-123-uuid",
      "identifier": "PROJ-42",
      "status": "running",
      "session_id": "thread-abc-turn-1",
      "turn_count": 3,
      "codex_input_tokens": 15420,
      "codex_output_tokens": 8230,
      "codex_total_tokens": 23650,
      "started_at": "2026-03-05T12:00:00Z",
      "last_activity_at": "2026-03-05T12:05:30Z",
      "runtime_seconds": 330,
      "retry_attempt": 0,
      "error": null
    }
  ],
  "total": 1,
  "polling": {
    "checking": false,
    "next_poll_in_ms": 12500,
    "poll_interval_ms": 30000
  }
}
```

### 3.4 GET /api/symphony/runs/:id

Get detailed status for a single run.

**Response `200 OK`:**

```json
{
  "run": {
    "id": "run_01JEXAMPLE",
    "issue_id": "abc-123-uuid",
    "identifier": "PROJ-42",
    "status": "running",
    "session_id": "thread-abc-turn-1",
    "turn_count": 3,
    "codex_input_tokens": 15420,
    "codex_output_tokens": 8230,
    "codex_total_tokens": 23650,
    "started_at": "2026-03-05T12:00:00Z",
    "last_activity_at": "2026-03-05T12:05:30Z",
    "last_codex_event": "notification",
    "last_codex_message": {
      "event": "notification",
      "message": "Writing tests...",
      "timestamp": "2026-03-05T12:05:30Z"
    },
    "runtime_seconds": 330,
    "retry_attempt": 0,
    "error": null
  }
}
```

**Error responses:**

| Status | Condition |
|--------|-----------|
| `404`  | Run not found |

### 3.5 DELETE /api/symphony/runs/:id

Cancel a running or pending run. This terminates the associated agent task and
cleans up the workspace.

**Response `200 OK`:**

```json
{
  "run": {
    "id": "run_01JEXAMPLE",
    "status": "cancelled",
    "cancelled_at": "2026-03-05T12:10:00Z"
  }
}
```

**Error responses:**

| Status | Condition |
|--------|-----------|
| `404`  | Run not found |
| `409`  | Run already in a terminal state (`completed`, `failed`, `cancelled`) |

### 3.6 POST /api/symphony/runs/:id/turns

Manually trigger the next turn for a run. This is useful when external logic
decides the issue needs continued work, bypassing the automatic
`continue_with_issue?` check.

**Request body (optional):**

```json
{
  "prompt_override": "Focus on writing tests for the login module.",
  "max_remaining_turns": 5
}
```

**Response `202 Accepted`:**

```json
{
  "turn": {
    "run_id": "run_01JEXAMPLE",
    "turn_number": 4,
    "status": "started",
    "triggered_at": "2026-03-05T12:10:00Z"
  }
}
```

**Error responses:**

| Status | Condition |
|--------|-----------|
| `404`  | Run not found |
| `409`  | Run is not in a continuable state |
| `503`  | Orchestrator unavailable |

---

## 4. Option B -- Internal Elixir Context API

These functions would live in an `AppleSlicer.Symphony` context module, usable
from LiveView processes, Oban workers, or IEx. This option is more natural for
apple-slicer since the orchestrator runs in the same BEAM node (or a connected
node).

### 4.1 Module: `AppleSlicer.Symphony`

The top-level context module. Manages run persistence and delegates execution
to the AgentRunner.

```elixir
defmodule AppleSlicer.Symphony do
  @moduledoc """
  Context module for Symphony agent runs within apple-slicer.
  """

  @type run_id :: String.t()
  @type issue_params :: %{
    id: String.t(),
    identifier: String.t(),
    title: String.t(),
    description: String.t() | nil,
    priority: integer() | nil,
    state: String.t(),
    branch_name: String.t() | nil,
    url: String.t() | nil,
    assignee_id: String.t() | nil,
    labels: [String.t()],
    blocked_by: [map()]
  }
  @type run_opts :: [
    max_turns: pos_integer(),
    workspace_root: String.t()
  ]

  @doc """
  Create a new Symphony run for the given issue.

  Validates the issue, creates a run record, and dispatches
  the agent task via the AgentRunner.

  Returns `{:ok, run}` with a run struct containing the assigned
  run ID, or `{:error, reason}`.
  """
  @spec create_run(issue_params(), run_opts()) ::
    {:ok, Run.t()} | {:error, term()}
  def create_run(issue_params, opts \\ [])

  @doc """
  Fetch the current state of a run by its ID.

  Returns the run struct with live token counts, turn count,
  and latest codex event information.
  """
  @spec get_run(run_id()) :: {:ok, Run.t()} | {:error, :not_found}
  def get_run(run_id)

  @doc """
  Cancel an active run.

  Terminates the agent process, optionally cleans up the workspace,
  and marks the run as cancelled.
  """
  @spec cancel_run(run_id()) :: {:ok, Run.t()} | {:error, term()}
  def cancel_run(run_id)

  @doc """
  List runs with optional filters.

  ## Options
    * `:status` - filter by run status atom
    * `:limit` - max results (default 50)
    * `:offset` - pagination offset (default 0)
  """
  @spec list_runs(keyword()) :: {:ok, [Run.t()], meta :: map()}
  def list_runs(opts \\ [])

  @doc """
  Request an immediate poll cycle from the orchestrator.

  Returns a map with `queued: true` and whether the request
  was coalesced with an already-pending poll.
  """
  @spec request_refresh() :: map() | :unavailable
  def request_refresh()

  @doc """
  Get a full snapshot of orchestrator state.

  Returns running issues, retrying issues, aggregate token totals,
  rate limit info, and polling status.
  """
  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot()
end
```

### 4.2 Module: `AppleSlicer.Symphony.AgentRunner`

Wraps `SymphonyElixir.AgentRunner` with apple-slicer-specific concerns
(FLAME integration, workspace credential injection, run state updates).

```elixir
defmodule AppleSlicer.Symphony.AgentRunner do
  @moduledoc """
  Agent execution within apple-slicer's runtime.
  """

  @doc """
  Execute a single turn of the agent for the given run.

  This starts (or continues) a Codex session in the run's workspace
  and executes one turn. The caller receives status updates via the
  `on_message` callback.

  ## Options
    * `:prompt_override` - custom prompt for this turn
    * `:max_remaining_turns` - cap on remaining turns
    * `:on_message` - `(map() -> :ok)` callback for codex stream events
    * `:workspace` - apple-slicer workspace for credential injection
  """
  @spec run_turn(run_id :: String.t(), keyword()) ::
    {:ok, map()} | {:error, term()}
  def run_turn(run_id, opts \\ [])

  @doc """
  Execute a full run (all turns until completion or max_turns).

  This is the equivalent of `SymphonyElixir.AgentRunner.run/3` but
  integrated with apple-slicer's run tracking.
  """
  @spec run(run_id :: String.t(), keyword()) :: :ok | {:error, term()}
  def run(run_id, opts \\ [])
end
```

### 4.3 Module: `AppleSlicer.Symphony.Run`

The run schema / struct.

```elixir
defmodule AppleSlicer.Symphony.Run do
  @moduledoc """
  Schema for a Symphony agent run.
  """

  @type status :: :pending | :running | :completed | :failed | :cancelled | :retrying

  @type t :: %__MODULE__{
    id:                   String.t(),
    issue_id:             String.t(),
    identifier:           String.t(),
    status:               status(),
    session_id:           String.t() | nil,
    turn_count:           non_neg_integer(),
    codex_input_tokens:   non_neg_integer(),
    codex_output_tokens:  non_neg_integer(),
    codex_total_tokens:   non_neg_integer(),
    started_at:           DateTime.t() | nil,
    completed_at:         DateTime.t() | nil,
    last_activity_at:     DateTime.t() | nil,
    last_codex_event:     atom() | nil,
    last_codex_message:   map() | nil,
    runtime_seconds:      non_neg_integer(),
    retry_attempt:        non_neg_integer(),
    error:                String.t() | nil,
    issue:                map() | nil
  }

  defstruct [
    :id, :issue_id, :identifier, :session_id,
    :started_at, :completed_at, :last_activity_at,
    :last_codex_event, :last_codex_message,
    :error, :issue,
    status: :pending,
    turn_count: 0,
    codex_input_tokens: 0,
    codex_output_tokens: 0,
    codex_total_tokens: 0,
    runtime_seconds: 0,
    retry_attempt: 0
  ]
end
```

---

## 5. Mapping Between Options

The REST API (Option A) and Context API (Option B) serve complementary roles.
In practice, the REST controller is a thin wrapper over the context module.

| REST Endpoint                        | Context Function                               | Notes |
|--------------------------------------|-------------------------------------------------|-------|
| `POST /api/symphony/runs`            | `AppleSlicer.Symphony.create_run/2`             | Controller validates JSON, casts to issue params, delegates |
| `GET /api/symphony/runs`             | `AppleSlicer.Symphony.list_runs/1`              | Controller maps query params to keyword opts |
| `GET /api/symphony/runs/:id`         | `AppleSlicer.Symphony.get_run/1`                | Direct delegation |
| `DELETE /api/symphony/runs/:id`      | `AppleSlicer.Symphony.cancel_run/1`             | Controller returns 409 if already terminal |
| `POST /api/symphony/runs/:id/turns`  | `AppleSlicer.Symphony.AgentRunner.run_turn/2`   | Controller extracts prompt_override, max_remaining_turns |
| (n/a -- used by LiveView directly)   | `AppleSlicer.Symphony.request_refresh/0`        | Triggers immediate orchestrator poll cycle |
| (n/a -- used by LiveView directly)   | `AppleSlicer.Symphony.snapshot/0`               | Full orchestrator state for dashboard rendering |

### Which approach feeds which use case?

- **REST API (Option A)** is the right choice for:
  - External integrations (Linear webhooks, GitHub Actions, CI pipelines)
  - Future standalone frontends or mobile apps
  - Multi-node deployments where the caller is not on the same BEAM cluster
  - Testing and debugging via `curl` or Postman

- **Context API (Option B)** is the right choice for:
  - apple-slicer LiveView pages (real-time dashboard, run management UI)
  - Oban background jobs (e.g., scheduled polling, cleanup)
  - IEx console debugging
  - Internal process-to-process communication within the same node
  - PubSub-driven real-time updates (the context module can broadcast events)

- **Recommended approach**: Implement Option B first, then add Option A as a
  thin controller layer. The LiveView pages will consume the context API
  directly, and the REST endpoints provide an external integration surface.

---

## 6. Integration Points with Existing apple-slicer Patterns

### 6.1 Router

The new routes fit within the existing `scope "/api"` block alongside
`/api/pools/status`, `/api/metrics`, and `/api/compute/:type`. The `:api`
pipeline already handles JSON content negotiation.

### 6.2 Controller Pattern

Following `ComputeController`, which accepts a request, enqueues work, and
returns a status response:

```elixir
defmodule AppleSlicerWeb.SymphonyController do
  use AppleSlicerWeb, :controller

  alias AppleSlicer.Symphony

  def create(conn, %{"issue" => issue_params} = params) do
    opts = Map.get(params, "options", %{})

    case Symphony.create_run(issue_params, opts) do
      {:ok, run} ->
        conn
        |> put_status(:created)
        |> json(%{run: serialize_run(run)})

      {:error, :no_slots_available} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "no_slots_available"})

      {:error, :already_running} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "already_running"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  # ... index, show, cancel, trigger_turn follow the same pattern
end
```

### 6.3 LiveView Pattern

Following `ClaudeLive`, a new `SymphonyLive` page would mount, subscribe to
PubSub updates, and call context functions:

```elixir
defmodule AppleSlicerWeb.SymphonyLive do
  use AppleSlicerWeb, :live_view

  alias AppleSlicer.Symphony

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AppleSlicer.PubSub, "symphony:runs")
    end

    {:ok, runs, meta} = Symphony.list_runs()
    snapshot = Symphony.snapshot()

    {:ok,
     socket
     |> assign(:runs, runs)
     |> assign(:snapshot, snapshot)}
  end

  def handle_info({:symphony_run_update, run}, socket) do
    # Update the specific run in the list
    {:noreply, update_run_in_assigns(socket, run)}
  end
end
```

### 6.4 Workspace Integration

apple-slicer's `AppleSlicer.Workspaces` module manages workspace credentials
and environment variables. The Symphony context should accept an optional
workspace parameter so credentials (API keys, GitHub tokens) can be injected
into the agent's subprocess environment, following the same pattern as
`AppleSlicer.Claude.execute_task/4`:

```elixir
# In AppleSlicer.Symphony.create_run/2:
workspace = Keyword.get(opts, :workspace)
env = AppleSlicer.Workspaces.build_subprocess_env(workspace)
# Pass env to the AgentRunner workspace hooks
```

### 6.5 FLAME Pool Integration

For deployments where agent execution should happen on FLAME workers (rather
than the host process), the `AgentRunner.run/2` call can be wrapped in a
`FLAME.call/3` targeting a dedicated pool (e.g., `AppleSlicer.SymphonyPool`),
following the same pattern as `AppleSlicer.Claude.execute_task/4`.

---

## 7. Event Streaming

The orchestrator already emits codex updates via process messages
(`{:codex_worker_update, issue_id, message}`). To surface these in apple-slicer:

1. The `AppleSlicer.Symphony` context should broadcast events to a PubSub
   topic (`symphony:runs` or `symphony:runs:{run_id}`).

2. LiveView pages subscribe to the topic and receive real-time updates.

3. The REST API can optionally support Server-Sent Events (SSE) or WebSocket
   streaming for external consumers, but this is not required for the initial
   implementation.

### Event types to broadcast:

| Event                    | Source in Orchestrator                              | Payload |
|--------------------------|-----------------------------------------------------|---------|
| `run_started`            | `do_dispatch_issue/3`                               | Run struct |
| `run_completed`          | `:DOWN` handler with `:normal` reason               | Run struct |
| `run_failed`             | `:DOWN` handler with error reason                   | Run struct + error |
| `run_cancelled`          | `terminate_running_issue/3`                         | Run struct |
| `run_retrying`           | `schedule_issue_retry/4`                            | Run struct + attempt |
| `codex_update`           | `handle_info({:codex_worker_update, ...})`          | Token counts, event, message |
| `turn_started`           | `AppServer` `:session_started` event                | Session ID, turn number |
| `turn_completed`         | `AppServer` `:turn_completed` event                 | Session ID, result |

---

## 8. State Storage

### Initial implementation (in-memory)

For the first iteration, run state can be held in the orchestrator's GenServer
state (as it already is). The context API reads from `Orchestrator.snapshot/0`.

### Future: persistent storage

If apple-slicer needs runs to survive restarts, an Ecto schema + Postgres table
can back the `Run` struct. The Oban job system already provides a Postgres
connection and migration infrastructure.

```
Table: symphony_runs
  id              UUID PRIMARY KEY
  issue_id        TEXT NOT NULL
  identifier      TEXT NOT NULL
  status          TEXT NOT NULL DEFAULT 'pending'
  session_id      TEXT
  turn_count      INTEGER DEFAULT 0
  codex_input_tokens    INTEGER DEFAULT 0
  codex_output_tokens   INTEGER DEFAULT 0
  codex_total_tokens    INTEGER DEFAULT 0
  started_at      TIMESTAMPTZ
  completed_at    TIMESTAMPTZ
  last_activity_at TIMESTAMPTZ
  retry_attempt   INTEGER DEFAULT 0
  error           TEXT
  issue_data      JSONB
  inserted_at     TIMESTAMPTZ NOT NULL
  updated_at      TIMESTAMPTZ NOT NULL
```

---

## 9. Authentication and Authorization

The existing apple-slicer API endpoints (`/api/pools/status`, `/api/metrics`,
`/api/compute/:type`) do not currently use authentication -- they rely on
network-level access control. The Symphony endpoints should follow the same
pattern initially, with a note that token-based auth (bearer token via a plug)
should be added before any production deployment that exposes these endpoints
externally.

A future `AppleSlicerWeb.Plugs.ApiAuth` plug can be inserted into the `:api`
pipeline:

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug AppleSlicerWeb.Plugs.ApiAuth  # future addition
end
```

---

## 10. Open Questions

1. **Run ID generation**: Should run IDs be UUIDs, ULIDs, or derived from the
   issue ID + attempt number? ULIDs are time-sortable and avoid the need for a
   sequence.

2. **Multi-node orchestration**: If apple-slicer and Symphony run on different
   nodes in the same cluster, should the context API use `:rpc.call/4` or
   distributed GenServer calls? Or should the REST API be the cross-node
   boundary?

3. **Run persistence**: Should runs be persisted to the database from day one,
   or is in-memory state (backed by `Orchestrator.snapshot/0`) sufficient for
   the initial integration?

4. **Workspace lifecycle**: Who owns workspace creation and teardown --
   apple-slicer or Symphony? Currently `SymphonyElixir.Workspace` handles this.
   If apple-slicer manages workspaces, the AgentRunner needs to accept an
   already-created workspace path.

5. **FLAME vs local execution**: Should the AgentRunner always run on the host
   process, or should there be a FLAME pool option for isolating agent execution
   (matching the `execute_mode` pattern in `ClaudeLive`)?
