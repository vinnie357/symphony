# Symphony Config to apple-slicer Mapping

This document maps every Symphony WORKFLOW.md configuration key to its apple-slicer equivalent (if one exists), identifies gaps, and recommends a config-sourcing strategy (WORKFLOW.md-parsed, DB-driven, or hybrid) for the integration.

## Architecture Overview

### Symphony config model

Symphony uses a **file-driven** configuration model:

- A single `WORKFLOW.md` file contains YAML front-matter (config sections) and a Liquid-template prompt body.
- `SymphonyElixir.Workflow` parses the file: splits `---` front-matter from the prompt template, decodes YAML via `YamlElixir`.
- `SymphonyElixir.WorkflowStore` (GenServer) caches the parsed workflow and polls the file every 1 second for changes (mtime + size + content-hash).
- `SymphonyElixir.Config` validates the parsed map through a `NimbleOptions` schema and exposes typed accessor functions.
- Environment variables can be referenced in the YAML via `$ENV_VAR` syntax (resolved at read time).

### apple-slicer config model

apple-slicer uses a **DB-driven + compile-time** configuration model:

- Compile-time config in `config/*.exs` and `config/runtime.exs` (Phoenix endpoint, Oban queues, FLAME pool sizing, Acorn socket).
- Runtime state in SQLite/Ecto: `workspaces`, `workspace_secrets`, `workspace_envs`, `stack_templates`, `stack_instances`, `slice_executions`, `pool_metrics`.
- No file-based workflow concept; workspaces provide secret/env grouping, and FLAME pools are hardcoded in `Application.flame_pools/0`.

---

## Section-by-Section Mapping

### 1. tracker

Symphony's `tracker` section configures issue-tracker integration (currently Linear-only, plus a `memory` test backend).

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `tracker.kind` | `string \| nil`, default `nil` | Tracker backend (`"linear"`, `"memory"`) | None | **New** |
| `tracker.endpoint` | `string`, default `"https://api.linear.app/graphql"` | Linear GraphQL endpoint | None | **New** |
| `tracker.api_key` | `string \| nil`, default `nil`; resolves `$LINEAR_API_KEY` | Linear API token | `Workspace.Secret` with key `"LINEAR_API_KEY"` | **Partial** -- secret storage exists, but no tracker-specific schema |
| `tracker.project_slug` | `string \| nil` | Linear project filter | None | **New** |
| `tracker.assignee` | `string \| nil`; resolves `$LINEAR_ASSIGNEE` | Filter issues by assignee | None | **New** |
| `tracker.active_states` | `list(string)`, default `["Todo", "In Progress"]` | Issue states that trigger agent work | None | **New** |
| `tracker.terminal_states` | `list(string)`, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]` | Issue states that halt agent work | None | **New** |

**Recommendation**: **Hybrid**. Store `tracker.kind`, `tracker.endpoint`, `tracker.project_slug`, `tracker.assignee`, `tracker.active_states`, `tracker.terminal_states` as DB columns on a new `workflow_configs` or `orchestration_configs` table (editable via the Phoenix UI). Store `tracker.api_key` in the existing `workspace_secrets` table. Support optional WORKFLOW.md override: if a WORKFLOW.md file is present in the workspace root, its tracker section takes precedence (allows per-repo customization in checked-in files).

---

### 2. polling

Symphony's `polling` section controls how frequently the orchestrator checks the issue tracker for new/changed issues.

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `polling.interval_ms` | `integer`, default `30_000` | Poll interval for issue tracker | Oban cron schedules (fixed at `"* * * * *"` = 60s) | **Analogous** -- Oban cron exists but is task-type-specific, not configurable per-workflow |

**Recommendation**: **DB-driven**. Add `poll_interval_ms` to the orchestration config table. At runtime, use either a recurring Oban job with dynamic scheduling or a dedicated GenServer with `Process.send_after/3` (matching Symphony's `WorkflowStore` pattern). Oban's `Cron` plugin does not natively support sub-minute or dynamic intervals, so a GenServer poller is more appropriate for the 5-30 second range Symphony typically uses.

---

### 3. workspace

Symphony's `workspace` section defines where agent workspaces (git clones) are created on disk.

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `workspace.root` | `string \| nil`, default `System.tmp_dir!/symphony_workspaces` | Root directory for agent working copies | `Workspaces.Workspace` (DB-managed, no filesystem root concept) | **Different abstraction** |

**Context**: In Symphony, a "workspace" is a filesystem directory (typically a shallow git clone) where an agent executes. In apple-slicer, a "workspace" is a DB record grouping secrets and envs passed to FLAME workers. These are fundamentally different concepts that happen to share a name.

**Recommendation**: **WORKFLOW.md-parsed** (or env var). The filesystem root for agent working copies is host-specific and should not live in the DB. Either parse it from WORKFLOW.md or default from an env var like `SYMPHONY_WORKSPACE_ROOT`. Rename apple-slicer's workspace concept to avoid collision (e.g., `credential_set` or `env_profile`), or namespace Symphony's as `agent_workspace_root`.

---

### 4. agent

Symphony's `agent` section controls concurrency and retry behavior for the orchestrator's agent pool.

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `agent.max_concurrent_agents` | `integer`, default `10` | Global concurrency limit | FLAME pool `max` (per-pool, e.g., `ClaudePool max: 3`) | **Analogous** -- FLAME pool sizing is compile-time, not runtime-configurable |
| `agent.max_turns` | `pos_integer`, default `20` | Max LLM turns per agent run | None | **New** |
| `agent.max_retry_backoff_ms` | `pos_integer`, default `300_000` | Max backoff between retries | None (Oban has `max_attempts` but no backoff config exposed) | **New** |
| `agent.max_concurrent_agents_by_state` | `map(string, pos_integer)`, default `%{}` | Per-state concurrency limits (e.g., `{"In Progress": 5, "Rework": 2}`) | None | **New** |

**Recommendation**: **Hybrid**. Store `max_concurrent_agents`, `max_turns`, `max_retry_backoff_ms`, and `max_concurrent_agents_by_state` in the DB config table for UI-editable runtime tuning. Allow WORKFLOW.md override for per-repo customization. The FLAME pool `max` setting is a different concern (infrastructure capacity) and should remain in compile-time config; the Symphony agent concurrency limits are application-level throttles layered above FLAME.

---

### 5. codex

Symphony's `codex` section configures the OpenAI Codex CLI process that acts as the coding agent backend.

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `codex.command` | `string`, default `"codex app-server"` | Shell command to start the agent backend | Hardcoded `claude -p --model #{model}` in `AppleSlicer.Claude.run_claude_cli/3` | **Different tool** |
| `codex.turn_timeout_ms` | `integer`, default `3_600_000` (1h) | Max time per agent turn | `@default_timeout` = `120_000` (2min) in `AppleSlicer.Claude` | **Analogous** -- exists but much shorter, not configurable per-workflow |
| `codex.read_timeout_ms` | `integer`, default `5_000` | Timeout for reading agent stdout | None | **New** |
| `codex.stall_timeout_ms` | `integer`, default `300_000` (5min) | Max idle time before declaring agent stalled | None | **New** |
| `codex.approval_policy` | `string \| map`, default `%{"reject" => %{"sandbox_approval" => true, "rules" => true, "mcp_elicitations" => true}}` | Codex approval policy for tool calls | None | **New** (Claude Code has `--allowedTools` but different mechanism) |
| `codex.thread_sandbox` | `string`, default `"workspace-write"` | Codex thread-level sandbox mode | None | **New** |
| `codex.turn_sandbox_policy` | `map`, default computed (workspaceWrite with writable roots) | Per-turn filesystem sandbox policy | None | **New** |

**Context**: Symphony drives OpenAI Codex via a JSON-RPC `app-server` protocol. apple-slicer drives Claude CLI via stdin/stdout piping. The codex section is tightly coupled to the Codex protocol. If apple-slicer adopts Symphony's orchestration, the agent backend config needs to be abstracted to support both Codex and Claude Code (or any future agent backend).

**Recommendation**: **Hybrid with backend abstraction**. Create an `agent_backend` config concept:
- `agent_backend.type`: `"codex"` | `"claude_code"` | `"custom"`
- `agent_backend.command`: the shell command
- `agent_backend.turn_timeout_ms`, `stall_timeout_ms`, `read_timeout_ms`: timeouts
- `agent_backend.sandbox_policy`: backend-specific sandbox config (map)

Store in DB for UI editability. Allow WORKFLOW.md override for per-repo agent tuning. The existing `AppleSlicer.Claude` module becomes one implementation of the agent backend interface.

---

### 6. hooks

Symphony's `hooks` section defines shell commands run at workspace lifecycle points.

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `hooks.after_create` | `string \| nil` | Run after workspace directory is created (e.g., `git clone`, `mix deps.get`) | None | **New** |
| `hooks.before_run` | `string \| nil` | Run before agent starts working in workspace | None | **New** |
| `hooks.after_run` | `string \| nil` | Run after agent completes | None | **New** |
| `hooks.before_remove` | `string \| nil` | Run before workspace directory is deleted | None | **New** |
| `hooks.timeout_ms` | `pos_integer`, default `60_000` | Max time for any hook to run | None | **New** |

**Context**: In the sample WORKFLOW.md, `after_create` clones the repo and installs dependencies; `before_remove` runs cleanup. These are critical for the orchestrator's workspace lifecycle.

**Recommendation**: **WORKFLOW.md-parsed**. Hooks are inherently per-repo (the clone URL, build commands, and cleanup steps differ per project). They should primarily come from the WORKFLOW.md file checked into the repository, not the DB. Store a `hooks_timeout_ms` override in the DB config for global tuning. Hooks run as shell subprocesses in the workspace directory.

---

### 7. observability

Symphony's `observability` section configures the live dashboard for monitoring agent activity.

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `observability.dashboard_enabled` | `boolean`, default `true` | Enable/disable the TUI/web dashboard | Always enabled (Phoenix LiveView) | **Exists** -- apple-slicer always serves the web dashboard |
| `observability.refresh_ms` | `integer`, default `1_000` | Data refresh interval | `@monitor_interval` = `5_000` in `PoolMonitor`; `@health_check_interval` = `30_000` | **Analogous** -- hardcoded, not configurable |
| `observability.render_interval_ms` | `integer`, default `16` (~60fps) | UI render interval | Phoenix LiveView push interval (not explicitly configurable) | **Analogous** -- LiveView handles this differently |

**Context**: Symphony originally had a Ratatui TUI dashboard (Rust), then moved to Phoenix LiveView. apple-slicer already has a Phoenix LiveView dashboard with pool monitoring, metrics history, and health checks.

**Recommendation**: **DB-driven**. Store `refresh_ms` and `render_interval_ms` (if needed) in the DB config table. The `dashboard_enabled` flag is less relevant since apple-slicer always runs Phoenix; it could control whether the orchestration dashboard tab is visible. The existing `PoolMonitor` GenServer intervals should be made configurable.

---

### 8. server

Symphony's `server` section configures the Phoenix HTTP server.

| Symphony Key | Type / Default | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|---|
| `server.port` | `non_neg_integer \| nil` | HTTP listen port | `PORT` env var, default `4000` in `runtime.exs` | **Exists** |
| `server.host` | `string`, default `"127.0.0.1"` | HTTP listen host | `PHX_HOST` env var, default `"localhost"` in `runtime.exs` | **Exists** |

**Recommendation**: **Keep existing** (env vars). apple-slicer already handles server config via standard Phoenix env vars (`PORT`, `PHX_HOST`). No need to duplicate this in WORKFLOW.md or DB. If Symphony's WORKFLOW.md provides `server` overrides, they can be mapped to the existing env-var-based config at startup.

---

### 9. prompt_template (body of WORKFLOW.md)

The content after the YAML front-matter `---` fence in WORKFLOW.md is treated as a Liquid template for the agent system prompt.

| Symphony Concept | Purpose | apple-slicer Equivalent | Status |
|---|---|---|---|
| Prompt template body | Liquid template with `{{ issue.identifier }}`, `{{ issue.title }}`, `{{ issue.description }}`, `{{ issue.state }}`, `{{ issue.labels }}`, `{{ issue.url }}`, `{{ attempt }}` | Hardcoded `@task_prompts` map in `AppleSlicer.Claude` | **Different design** |

**Context**: Symphony's prompt template is extremely rich (see the sample WORKFLOW.md): it defines the full agent behavior including status-map routing, workpad management, PR feedback sweeps, rework handling, and guardrails. This is the core "personality" of the orchestrator. apple-slicer's prompts are simple task-type templates (`code_review`, `bug_analysis`, etc.) with `{code}` and `{context}` placeholders.

**Recommendation**: **WORKFLOW.md-parsed**. The prompt template must come from WORKFLOW.md (or a similar file). It is the single most important piece of per-repo configuration and is version-controlled alongside the codebase. Store a DB-level "default prompt template" as a fallback, but always prefer the file-based version. The Liquid template engine (`Solid` in Elixir) should be integrated for variable interpolation.

---

## Consolidated Mapping Table

| # | Symphony Section.Key | Default | apple-slicer Equivalent | Gap | Recommended Source |
|---|---|---|---|---|---|
| 1 | `tracker.kind` | `nil` | -- | New | DB |
| 2 | `tracker.endpoint` | `https://api.linear.app/graphql` | -- | New | DB |
| 3 | `tracker.api_key` | `nil` / `$LINEAR_API_KEY` | `Workspace.Secret` | Partial | DB (secrets table) |
| 4 | `tracker.project_slug` | `nil` | -- | New | DB |
| 5 | `tracker.assignee` | `nil` / `$LINEAR_ASSIGNEE` | -- | New | DB |
| 6 | `tracker.active_states` | `["Todo", "In Progress"]` | -- | New | DB |
| 7 | `tracker.terminal_states` | `["Closed", ...]` | -- | New | DB |
| 8 | `polling.interval_ms` | `30_000` | Oban cron (60s fixed) | Analogous | DB |
| 9 | `workspace.root` | `$TMPDIR/symphony_workspaces` | -- (different concept) | New | Env var / WORKFLOW.md |
| 10 | `agent.max_concurrent_agents` | `10` | FLAME `max` (compile-time) | Analogous | DB |
| 11 | `agent.max_turns` | `20` | -- | New | DB |
| 12 | `agent.max_retry_backoff_ms` | `300_000` | -- | New | DB |
| 13 | `agent.max_concurrent_agents_by_state` | `%{}` | -- | New | DB |
| 14 | `codex.command` | `"codex app-server"` | Hardcoded `claude -p` | Different tool | DB + WORKFLOW.md |
| 15 | `codex.turn_timeout_ms` | `3_600_000` | `@default_timeout` (120s) | Analogous | DB |
| 16 | `codex.read_timeout_ms` | `5_000` | -- | New | DB |
| 17 | `codex.stall_timeout_ms` | `300_000` | -- | New | DB |
| 18 | `codex.approval_policy` | `%{reject: ...}` | -- | New | DB + WORKFLOW.md |
| 19 | `codex.thread_sandbox` | `"workspace-write"` | -- | New | DB + WORKFLOW.md |
| 20 | `codex.turn_sandbox_policy` | Computed map | -- | New | DB + WORKFLOW.md |
| 21 | `hooks.after_create` | `nil` | -- | New | WORKFLOW.md |
| 22 | `hooks.before_run` | `nil` | -- | New | WORKFLOW.md |
| 23 | `hooks.after_run` | `nil` | -- | New | WORKFLOW.md |
| 24 | `hooks.before_remove` | `nil` | -- | New | WORKFLOW.md |
| 25 | `hooks.timeout_ms` | `60_000` | -- | New | DB |
| 26 | `observability.dashboard_enabled` | `true` | Always on (Phoenix) | Exists | DB (optional toggle) |
| 27 | `observability.refresh_ms` | `1_000` | `5_000` hardcoded | Analogous | DB |
| 28 | `observability.render_interval_ms` | `16` | LiveView-managed | Analogous | DB |
| 29 | `server.port` | `nil` | `PORT` env var | Exists | Env var (keep) |
| 30 | `server.host` | `"127.0.0.1"` | `PHX_HOST` env var | Exists | Env var (keep) |
| 31 | Prompt template (body) | Liquid template | `@task_prompts` (hardcoded) | Different design | WORKFLOW.md |

---

## Config Source Strategy Summary

### WORKFLOW.md-parsed (file-driven)

Best for per-repo, version-controlled settings that change with the codebase:
- `hooks.*` (after_create, before_run, after_run, before_remove)
- `workspace.root`
- Prompt template body
- `codex.approval_policy`, `codex.thread_sandbox`, `codex.turn_sandbox_policy` (overrides)

### DB-driven

Best for runtime-tunable, UI-editable settings shared across workflows:
- `tracker.*` (kind, endpoint, project_slug, assignee, active_states, terminal_states)
- `polling.interval_ms`
- `agent.*` (max_concurrent_agents, max_turns, max_retry_backoff_ms, max_concurrent_agents_by_state)
- `codex.command`, `codex.turn_timeout_ms`, `codex.read_timeout_ms`, `codex.stall_timeout_ms`
- `observability.*`
- `hooks.timeout_ms`

### Env var (keep existing)

Best for infrastructure/host-level settings:
- `server.port` (already `PORT`)
- `server.host` (already `PHX_HOST`)
- `tracker.api_key` (via `workspace_secrets` or `$LINEAR_API_KEY`)

### Hybrid (DB default + WORKFLOW.md override)

For settings that benefit from both a UI-editable baseline and per-repo customization:
- `agent.*` settings
- `codex.*` / agent backend settings
- `tracker.active_states`, `tracker.terminal_states`

---

## Key Design Decisions Needed

### 1. Naming collision: "workspace"

Symphony workspace = filesystem directory for an agent run (git clone).
apple-slicer workspace = DB record grouping secrets/envs for FLAME workers.

**Options**:
- (a) Rename apple-slicer's concept to `CredentialSet` or `EnvProfile`.
- (b) Namespace Symphony's concept as `AgentWorkspace` and keep apple-slicer's as-is.
- (c) Merge: extend apple-slicer `Workspace` with a `root_path` field so it serves both purposes.

**Recommendation**: Option (c) -- extend apple-slicer's `Workspace` schema with an optional `root_path` field and hook commands. This keeps one `Workspace` concept that covers both secret management and filesystem configuration.

### 2. Agent backend abstraction

Symphony is built around OpenAI Codex (`codex app-server` JSON-RPC protocol). apple-slicer currently uses Claude CLI (`claude -p`). The integration should abstract the agent backend.

**Proposed interface**:
```elixir
@callback start(workspace_path :: String.t(), config :: map()) :: {:ok, pid()} | {:error, term()}
@callback send_turn(pid(), prompt :: String.t(), opts :: keyword()) :: {:ok, response()} | {:error, term()}
@callback stop(pid()) :: :ok
```

### 3. WorkflowStore hot-reload in a web context

Symphony's `WorkflowStore` polls WORKFLOW.md every 1 second. In apple-slicer's Phoenix context, this still works but should also broadcast changes via PubSub so LiveView dashboards update without page refresh.

### 4. NimbleOptions validation

Symphony's NimbleOptions schema should be preserved for validating WORKFLOW.md content regardless of whether the config source is file or DB. For DB-sourced config, the same schema can validate before persisting.

---

## Key Source Files Referenced

### Symphony

- `/Users/vinnie/github/symphony/elixir/lib/symphony_elixir/config.ex` -- Config module with NimbleOptions schema, env resolution, typed accessors
- `/Users/vinnie/github/symphony/elixir/lib/symphony_elixir/workflow.ex` -- WORKFLOW.md parser (YAML front-matter + prompt template)
- `/Users/vinnie/github/symphony/elixir/lib/symphony_elixir/workflow_store.ex` -- GenServer cache with file-polling hot-reload
- `/Users/vinnie/github/symphony/elixir/WORKFLOW.md` -- Sample workflow file (Linear + Codex + hooks)

### apple-slicer

- `/Users/vinnie/github/apple-slicer/config/config.exs` -- Compile-time config (Oban, FLAME pools, endpoint)
- `/Users/vinnie/github/apple-slicer/config/runtime.exs` -- Runtime config (PORT, PHX_HOST, Acorn, database)
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/application.ex` -- Supervision tree, FLAME pool definitions
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/claude.ex` -- Claude CLI integration (hardcoded command, timeouts)
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/workspaces.ex` -- Workspace context (secrets, envs, subprocess env building)
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/workspaces/workspace.ex` -- Workspace schema (name, emoji, is_default)
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/workspaces/secret.ex` -- Secret schema (AES-256-GCM encrypted)
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/workspaces/env.ex` -- Env schema (plaintext key-value)
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/monitoring/pool_monitor.ex` -- Pool monitoring GenServer (5s interval, health checks)
- `/Users/vinnie/github/apple-slicer/lib/apple_slicer/metrics/pool_metric.ex` -- Pool metrics Ecto schema (persisted snapshots)
