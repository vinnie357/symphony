# Symphony Ecto Schema Design

Design document for persisting Symphony orchestrator state via Ecto schemas.
Covers the two new schemas (`SymphonyRun`, `SymphonySession`), their
relationship to the existing apple-slicer `Workspace` schema, and the
boundary between in-memory GenServer state and database-persisted records.

---

## 1. Schema Relationship Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                      apple-slicer (existing)                        │
│                                                                     │
│  ┌──────────────┐    ┌───────────────────┐    ┌──────────────────┐  │
│  │  workspaces   │───<│  workspace_secrets │    │  stack_templates │  │
│  │              │    └───────────────────┘    │                  │  │
│  │  id (PK)     │                             │  workspace_id FK │  │
│  │  name        │    ┌───────────────────┐    └──────────────────┘  │
│  │  emoji       │───<│  workspace_envs    │                         │
│  │  is_default  │    └───────────────────┘    ┌──────────────────┐  │
│  │  timestamps  │                             │  stack_instances  │  │
│  └──────┬───────┘    ┌───────────────────┐    │  workspace_id FK │  │
│         │           <│  slice_executions  │    └──────────────────┘  │
│         │            │  workspace_id FK   │                         │
│         │            └───────────────────┘                         │
└─────────┼───────────────────────────────────────────────────────────┘
          │
          │  FK (workspace_id)
          │
┌─────────┼───────────────────────────────────────────────────────────┐
│         │               symphony (new)                              │
│         ▼                                                           │
│  ┌──────────────────┐         ┌───────────────────────┐             │
│  │  symphony_runs    │────────<│  symphony_sessions     │             │
│  │                  │         │                       │             │
│  │  id (PK)         │         │  id (PK)              │             │
│  │  workspace_id FK │         │  symphony_run_id FK   │             │
│  │  issue_id        │         │  turn_number          │             │
│  │  issue_identifier│         │  prompt_hash          │             │
│  │  issue_title     │         │  status               │             │
│  │  issue_state     │         │  input_tokens         │             │
│  │  status          │         │  output_tokens        │             │
│  │  attempt_number  │         │  duration_ms          │             │
│  │  turn_count      │         │  error                │             │
│  │  input_tokens    │         │  started_at           │             │
│  │  output_tokens   │         │  completed_at         │             │
│  │  error           │         │  timestamps           │             │
│  │  started_at      │         └───────────────────────┘             │
│  │  completed_at    │                                               │
│  │  metadata        │                                               │
│  │  timestamps      │                                               │
│  └──────────────────┘                                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. SymphonyRun Schema

One record per issue dispatch. A single Linear issue may produce multiple
`SymphonyRun` rows across retries (each retry is a new run with an
incremented `attempt_number`).

### 2.1 Table: `symphony_runs`

| Column             | Ecto Type        | DB Type          | Nullable | Default     | Notes |
|--------------------|------------------|------------------|----------|-------------|-------|
| `id`               | `:id`            | `bigint` (PK)    | no       | auto        | Auto-increment primary key (matches apple-slicer convention) |
| `workspace_id`     | `references`     | `bigint`         | yes      | `nil`       | FK to `workspaces.id`; nullable because symphony may run before apple-slicer workspace exists |
| `issue_id`         | `:string`        | `varchar`        | no       |             | Linear issue UUID (e.g. `"abc-123-def"`) |
| `issue_identifier` | `:string`        | `varchar`        | no       |             | Human-readable Linear identifier (e.g. `"PROJ-42"`) |
| `issue_title`      | `:string`        | `text`           | no       |             | Issue title at dispatch time |
| `issue_state`      | `:string`        | `varchar`        | yes      | `nil`       | Linear workflow state name at dispatch (e.g. `"In Progress"`) |
| `status`           | `:string`        | `varchar`        | no       | `"pending"` | One of: `pending`, `running`, `completed`, `failed` |
| `attempt_number`   | `:integer`       | `integer`        | no       | `0`         | Retry attempt counter; `0` = first attempt |
| `turn_count`       | `:integer`       | `integer`        | no       | `0`         | Total Codex turns executed in this run |
| `input_tokens`     | `:integer`       | `integer`        | no       | `0`         | Cumulative input/prompt tokens |
| `output_tokens`    | `:integer`       | `integer`        | no       | `0`         | Cumulative output/completion tokens |
| `error`            | `:string`        | `text`           | yes      | `nil`       | Error message if status is `failed` |
| `started_at`       | `:utc_datetime`  | `utc_datetime`   | yes      | `nil`       | When the agent task was spawned |
| `completed_at`     | `:utc_datetime`  | `utc_datetime`   | yes      | `nil`       | When the agent task exited (success or failure) |
| `metadata`         | `:map`           | `json` / `map`   | yes      | `%{}`       | Extensible bag for session_id, thread_id, codex_app_server_pid, labels, priority, branch_name |
| `inserted_at`      | `:utc_datetime`  | `utc_datetime`   | no       | auto        | Ecto `timestamps()` |
| `updated_at`       | `:utc_datetime`  | `utc_datetime`   | no       | auto        | Ecto `timestamps()` |

### 2.2 Indexes

```
index(:symphony_runs, [:status])
index(:symphony_runs, [:issue_id])
index(:symphony_runs, [:issue_identifier])
index(:symphony_runs, [:workspace_id])
index(:symphony_runs, [:inserted_at])
unique_index(:symphony_runs, [:issue_id, :attempt_number])
```

The unique index on `[:issue_id, :attempt_number]` prevents duplicate run
records for the same issue+attempt combination.

### 2.3 Schema Module

```elixir
defmodule Symphony.Runs.SymphonyRun do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running completed failed)

  schema "symphony_runs" do
    field :issue_id, :string
    field :issue_identifier, :string
    field :issue_title, :string
    field :issue_state, :string
    field :status, :string, default: "pending"
    field :attempt_number, :integer, default: 0
    field :turn_count, :integer, default: 0
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :error, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :workspace, AppleSlicer.Workspaces.Workspace

    has_many :sessions, Symphony.Runs.SymphonySession

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :issue_id,
      :issue_identifier,
      :issue_title,
      :issue_state,
      :status,
      :attempt_number,
      :turn_count,
      :input_tokens,
      :output_tokens,
      :error,
      :started_at,
      :completed_at,
      :metadata
    ])
    |> validate_required([:issue_id, :issue_identifier, :issue_title, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:issue_id, :attempt_number])
  end
end
```

### 2.4 Mapping from Orchestrator State

The orchestrator `running` map entry (see `do_dispatch_issue/3` at line 598
of `orchestrator.ex`) contains the following fields that map to
`SymphonyRun` columns:

| Orchestrator running_entry key | SymphonyRun column | Notes |
|--------------------------------|--------------------|-------|
| (map key)                      | `issue_id`         | The `issue_id` key in `state.running` |
| `:identifier`                  | `issue_identifier` | From `issue.identifier` |
| `:issue` -> `.title`           | `issue_title`      | From `Issue.title` |
| `:issue` -> `.state`           | `issue_state`      | From `Issue.state` |
| `:retry_attempt`               | `attempt_number`   | Normalized to `0` for first attempt |
| `:turn_count`                  | `turn_count`       | Incremented on `:session_started` events |
| `:codex_input_tokens`          | `input_tokens`     | Accumulated from delta computation |
| `:codex_output_tokens`         | `output_tokens`    | Accumulated from delta computation |
| `:started_at`                  | `started_at`       | `DateTime.utc_now()` at dispatch |
| `:session_id`                  | `metadata.session_id` | Set when first Codex session starts |
| `:codex_app_server_pid`        | `metadata.codex_app_server_pid` | OS PID of Codex process |

The `status` column is derived from orchestrator lifecycle events:
- Inserted as `"pending"` when `do_dispatch_issue/3` creates the task
- Updated to `"running"` on first `:session_started` Codex event
- Updated to `"completed"` when `:DOWN` with reason `:normal`
- Updated to `"failed"` when `:DOWN` with non-normal reason

---

## 3. SymphonySession Schema

One record per Codex turn within a run. The `AgentRunner.do_run_codex_turns/7`
function loops through turns 1..max_turns; each iteration produces one
`SymphonySession` row.

### 3.1 Table: `symphony_sessions`

| Column             | Ecto Type        | DB Type          | Nullable | Default     | Notes |
|--------------------|------------------|------------------|----------|-------------|-------|
| `id`               | `:id`            | `bigint` (PK)    | no       | auto        | Auto-increment primary key |
| `symphony_run_id`  | `references`     | `bigint`         | no       |             | FK to `symphony_runs.id` |
| `turn_number`      | `:integer`       | `integer`        | no       |             | 1-based turn index within the run |
| `prompt_hash`      | `:string`        | `varchar`        | yes      | `nil`       | SHA-256 hex of the prompt text sent to Codex (for dedup/audit) |
| `status`           | `:string`        | `varchar`        | no       | `"pending"` | One of: `pending`, `running`, `completed`, `failed` |
| `input_tokens`     | `:integer`       | `integer`        | yes      | `0`         | Tokens consumed by this turn's prompt |
| `output_tokens`    | `:integer`       | `integer`        | yes      | `0`         | Tokens produced by this turn's completion |
| `duration_ms`      | `:integer`       | `integer`        | yes      | `nil`       | Wall-clock milliseconds for this turn |
| `error`            | `:string`        | `text`           | yes      | `nil`       | Error message if the turn failed |
| `started_at`       | `:utc_datetime`  | `utc_datetime`   | yes      | `nil`       | When `AppServer.run_turn` was called |
| `completed_at`     | `:utc_datetime`  | `utc_datetime`   | yes      | `nil`       | When the turn completed or failed |
| `inserted_at`      | `:utc_datetime`  | `utc_datetime`   | no       | auto        | Ecto `timestamps()` |
| `updated_at`       | `:utc_datetime`  | `utc_datetime`   | no       | auto        | Ecto `timestamps()` |

### 3.2 Indexes

```
index(:symphony_sessions, [:symphony_run_id])
index(:symphony_sessions, [:status])
index(:symphony_sessions, [:inserted_at])
unique_index(:symphony_sessions, [:symphony_run_id, :turn_number])
```

### 3.3 Schema Module

```elixir
defmodule Symphony.Runs.SymphonySession do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running completed failed)

  schema "symphony_sessions" do
    field :turn_number, :integer
    field :prompt_hash, :string
    field :status, :string, default: "pending"
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :duration_ms, :integer
    field :error, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :symphony_run, Symphony.Runs.SymphonyRun

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :symphony_run_id,
      :turn_number,
      :prompt_hash,
      :status,
      :input_tokens,
      :output_tokens,
      :duration_ms,
      :error,
      :started_at,
      :completed_at
    ])
    |> validate_required([:symphony_run_id, :turn_number, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:turn_number, greater_than: 0)
    |> foreign_key_constraint(:symphony_run_id)
    |> unique_constraint([:symphony_run_id, :turn_number])
  end
end
```

### 3.4 Mapping from AgentRunner / AppServer

The `AgentRunner.do_run_codex_turns/7` recurses with `turn_number` 1..max_turns.
Each iteration calls `AppServer.run_turn/4` which returns a map containing:

| AppServer return key | SymphonySession column | Notes |
|----------------------|------------------------|-------|
| N/A (parameter)      | `turn_number`          | The `turn_number` parameter passed through recursion |
| N/A (computed)       | `prompt_hash`          | `:crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)` |
| `:session_id`        | (via parent run)       | Format: `"#{thread_id}-#{turn_id}"` |
| (from Codex events)  | `input_tokens`         | Extracted from token usage events during the turn |
| (from Codex events)  | `output_tokens`        | Extracted from token usage events during the turn |
| (computed)           | `duration_ms`          | `DateTime.diff(completed_at, started_at, :millisecond)` |

---

## 4. Relationship to Existing apple-slicer Schemas

### 4.1 Workspace FK

`SymphonyRun.workspace_id` is an optional FK to `workspaces.id`. This allows
querying all symphony runs associated with a given workspace, and enables the
apple-slicer UI to show symphony activity alongside slice executions.

The FK is nullable because:
- Symphony may operate before a workspace record exists in the database
- The workspace concept in symphony (`Workspace.create_for_issue/1`) creates
  filesystem directories, not necessarily database rows
- A future migration can backfill workspace_ids once the mapping is established

### 4.2 Parallel to SliceExecution

`SymphonyRun` mirrors the role of `SliceExecution` in apple-slicer:

| Concept              | apple-slicer         | symphony              |
|----------------------|----------------------|-----------------------|
| Execution record     | `slice_executions`   | `symphony_runs`       |
| Per-turn detail      | (N/A, single-turn)   | `symphony_sessions`   |
| Workspace link       | `workspace_id` (req) | `workspace_id` (opt)  |
| Status values        | `pending/running/completed/failed` | `pending/running/completed/failed` |
| Token tracking       | N/A                  | `input_tokens`, `output_tokens` |
| Error capture        | `error` (string)     | `error` (string)      |
| Duration             | `duration_ms`        | Computed from `started_at`/`completed_at` |
| Extensible metadata  | `input`/`output` maps| `metadata` map        |

### 4.3 Conventions Followed from apple-slicer

- **Primary keys**: Default auto-increment bigint `id` (no UUIDs)
- **Timestamps**: `timestamps()` producing `inserted_at` / `updated_at`
- **Status pattern**: String field with module-level `@statuses` list and `validate_inclusion`
- **Foreign keys**: `references(:table, on_delete: ...)` with explicit `foreign_key_constraint`
- **Changeset style**: Single `changeset/2` function with `cast` then `validate_required` then type/inclusion validations then constraint checks
- **Module nesting**: `Symphony.Runs.SymphonyRun`, `Symphony.Runs.SymphonySession` (parallel to `AppleSlicer.Slices.SliceExecution`)

---

## 5. In-Memory vs Persisted Analysis

### 5.1 Stays In-Memory Only (Orchestrator GenServer)

These fields exist in the `Orchestrator.State` struct and the per-issue
`running` map entries. They are process-local, ephemeral, and not
meaningful to persist:

| Field / Concept                  | Why In-Memory Only |
|----------------------------------|--------------------|
| `state.running` (full map)       | PID/ref keyed; process-local supervision |
| `running_entry.pid`              | Erlang PID; meaningless after process death |
| `running_entry.ref`              | Monitor reference; tied to process lifecycle |
| `running_entry.last_codex_message` | Transient display data for dashboard |
| `running_entry.last_codex_timestamp` | Stall detection; only relevant while running |
| `running_entry.last_codex_event` | Transient event type for dashboard |
| `running_entry.codex_last_reported_*_tokens` | Delta computation bookkeeping; final totals are persisted |
| `state.claimed` (MapSet)         | Coordination set; reconstructible from DB status |
| `state.completed` (MapSet)       | Coordination set; derivable from DB completed records |
| `state.poll_interval_ms`         | Runtime config; re-read from `Config` on each tick |
| `state.max_concurrent_agents`    | Runtime config; re-read from `Config` on each tick |
| `state.next_poll_due_at_ms`      | Monotonic timer; only meaningful within the process |
| `state.poll_check_in_progress`   | Transient flag; reset on restart |
| `state.codex_totals`             | Aggregated session-level totals; can be re-derived from DB via `SUM()` |
| `state.codex_rate_limits`        | Transient API rate limit info from Codex; changes constantly |
| `retry_attempts.*.timer_ref`     | `Process.send_after` reference; process-local |
| `retry_attempts.*.due_at_ms`     | Monotonic timestamp; only meaningful within the process |

### 5.2 Persisted to Database

These represent the durable record of what happened and are written to the
`symphony_runs` and `symphony_sessions` tables:

| Data                              | Schema              | Column(s) |
|-----------------------------------|----------------------|-----------|
| Which issue was worked on         | `SymphonyRun`        | `issue_id`, `issue_identifier`, `issue_title` |
| Issue state at dispatch time      | `SymphonyRun`        | `issue_state` |
| Run lifecycle status              | `SymphonyRun`        | `status` |
| Retry tracking                    | `SymphonyRun`        | `attempt_number` |
| How many turns were executed      | `SymphonyRun`        | `turn_count` |
| Cumulative token consumption      | `SymphonyRun`        | `input_tokens`, `output_tokens` |
| Run timing                        | `SymphonyRun`        | `started_at`, `completed_at` |
| Error details                     | `SymphonyRun`        | `error` |
| Session/thread IDs, labels, etc.  | `SymphonyRun`        | `metadata` |
| Per-turn prompt fingerprint       | `SymphonySession`    | `prompt_hash` |
| Per-turn token usage              | `SymphonySession`    | `input_tokens`, `output_tokens` |
| Per-turn timing                   | `SymphonySession`    | `started_at`, `completed_at`, `duration_ms` |
| Per-turn status                   | `SymphonySession`    | `status` |
| Per-turn error                    | `SymphonySession`    | `error` |

### 5.3 Reconstruction on Restart

When the orchestrator GenServer restarts (supervisor recovery), it currently
rebuilds state from a fresh Linear poll. With the persistence layer:

1. On init, query `symphony_runs WHERE status = 'running'` to find runs that
   were interrupted by a crash.
2. Mark those runs as `failed` with `error: "orchestrator_restart"`.
3. The `claimed` MapSet can be seeded from runs with `status IN ('pending', 'running')`.
4. The `completed` MapSet can be seeded from runs with `status = 'completed'`
   for the current issue set.
5. The `retry_attempts` map is NOT restored; the next poll cycle will
   naturally re-dispatch eligible issues.

---

## 6. Migration Naming Conventions

Following the apple-slicer pattern observed in `priv/repo/migrations/`:

```
20260222220919_create_pool_metrics.exs
20260225133641_create_workspaces.exs
20260301000001_create_stacks.exs
20260301000002_create_slice_executions.exs
20260304124435_create_workspace_envs.exs
```

**Pattern**: `{YYYYMMDDHHMMSS}_{action}_{table_name}.exs`

Symphony migrations should follow the same convention:

```
{timestamp}_create_symphony_runs.exs
{timestamp}_create_symphony_sessions.exs
```

### 6.1 Migration: `create_symphony_runs`

```elixir
defmodule Symphony.Repo.Migrations.CreateSymphonyRuns do
  use Ecto.Migration

  def change do
    create table(:symphony_runs) do
      add :workspace_id, references(:workspaces, on_delete: :nilify_all)
      add :issue_id, :string, null: false
      add :issue_identifier, :string, null: false
      add :issue_title, :text, null: false
      add :issue_state, :string
      add :status, :string, default: "pending", null: false
      add :attempt_number, :integer, default: 0, null: false
      add :turn_count, :integer, default: 0, null: false
      add :input_tokens, :integer, default: 0, null: false
      add :output_tokens, :integer, default: 0, null: false
      add :error, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps()
    end

    create index(:symphony_runs, [:status])
    create index(:symphony_runs, [:issue_id])
    create index(:symphony_runs, [:issue_identifier])
    create index(:symphony_runs, [:workspace_id])
    create index(:symphony_runs, [:inserted_at])
    create unique_index(:symphony_runs, [:issue_id, :attempt_number])
  end
end
```

### 6.2 Migration: `create_symphony_sessions`

```elixir
defmodule Symphony.Repo.Migrations.CreateSymphonySessions do
  use Ecto.Migration

  def change do
    create table(:symphony_sessions) do
      add :symphony_run_id, references(:symphony_runs, on_delete: :delete_all), null: false
      add :turn_number, :integer, null: false
      add :prompt_hash, :string
      add :status, :string, default: "pending", null: false
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :duration_ms, :integer
      add :error, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps()
    end

    create index(:symphony_sessions, [:symphony_run_id])
    create index(:symphony_sessions, [:status])
    create index(:symphony_sessions, [:inserted_at])
    create unique_index(:symphony_sessions, [:symphony_run_id, :turn_number])
  end
end
```

---

## 7. Write Path: When Records Are Created and Updated

### 7.1 SymphonyRun Lifecycle

```
Orchestrator.do_dispatch_issue/3
  └─ INSERT symphony_run (status: "pending", started_at: now)

Orchestrator.handle_info({:codex_worker_update, ...})
  └─ on first :session_started event:
       UPDATE symphony_run SET status = "running", metadata = %{session_id: ...}
  └─ on token usage events:
       UPDATE symphony_run SET input_tokens = ..., output_tokens = ...

Orchestrator.handle_info({:DOWN, ref, ...})
  └─ reason == :normal:
       UPDATE symphony_run SET status = "completed", completed_at: now, turn_count: ...
  └─ reason != :normal:
       UPDATE symphony_run SET status = "failed", completed_at: now, error: ...
```

### 7.2 SymphonySession Lifecycle

```
AgentRunner.do_run_codex_turns/7 (each turn iteration)
  └─ Before AppServer.run_turn:
       INSERT symphony_session (turn_number: N, status: "running", started_at: now, prompt_hash: ...)
  └─ After AppServer.run_turn returns {:ok, ...}:
       UPDATE symphony_session SET status = "completed", completed_at: now, duration_ms: ..., tokens: ...
  └─ After AppServer.run_turn returns {:error, ...}:
       UPDATE symphony_session SET status = "failed", completed_at: now, error: ...
```

---

## 8. Open Questions

1. **Shared Repo vs Separate Repo**: Should symphony share `AppleSlicer.Repo`
   or define its own `Symphony.Repo` pointing to the same database? Sharing
   simplifies FK enforcement; a separate repo allows independent deployment.

2. **workspace_id Backfill**: The filesystem workspace created by
   `SymphonyElixir.Workspace.create_for_issue/1` is not a database record
   today. A future task should reconcile these, either by creating workspace
   rows on dispatch or by running a backfill migration.

3. **Token Granularity**: The orchestrator accumulates tokens at the run level
   via delta computation. Per-session token attribution requires instrumenting
   `AgentRunner.do_run_codex_turns/7` to capture before/after token snapshots
   per turn.

4. **Metadata Schema Evolution**: The `metadata` map is intentionally
   unstructured. If specific fields (e.g., `session_id`, `thread_id`,
   `branch_name`, `labels`) are frequently queried, they should be promoted
   to top-level columns in a future migration.
