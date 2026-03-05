# WORKFLOW.md `execution:` Section Schema

Task 1.6: Design the schema that replaces the current `codex:` section in WORKFLOW.md with a backend-agnostic `execution:` section supporting multiple execution backends.

**Date**: 2026-03-05

---

## 1. Design Context

### Why Replace `codex:`

The current `codex:` section in WORKFLOW.md is tightly coupled to the OpenAI Codex `app-server` JSON-RPC protocol. Symphony is migrating to Claude Code CLI as its agent backend. The new `execution:` section must:

1. Support Claude Code CLI invocation via multiple backends (direct API calls, FLAME pool offloading, future Acorn stack containers).
2. Be backend-agnostic at the top level while allowing backend-specific configuration.
3. Remain parseable by the existing `SymphonyElixir.Workflow` YAML front-matter parser.
4. Be validatable via `NimbleOptions` in `SymphonyElixir.Config`.

### Backend Viability (from Task 1.5 Acorn Evaluation)

| Backend | Status | Notes |
|---|---|---|
| `flame-pool` (Option B) | **Viable now** | FLAME pools are production-tested in apple-slicer. Requires FLAME backend modifications for long-running sessions. |
| `api` (Option A) | **Viable now** | Direct CLI invocation via Erlang `Port.open/2`. Simplest path; what Symphony already does (modulo Codex vs Claude Code). |
| `acorn-stack` (Option C) | **Not viable** | Acorn daemon supports 3 of 18 operations. All stack lifecycle commands (`spawn_stack`, `teardown_stack`, `stack_status`, `stack_service_discovery`, `scale_service`) are spec-only. `exec_container` cannot support long-running interactive sessions. |

The schema must work today with `flame-pool` and `api`, and be forward-compatible with `acorn-stack` when the Acorn daemon gaps are filled.

---

## 2. Full Schema Definition

### 2.1 YAML Structure

```yaml
execution:
  backend: api                       # "api" | "flame-pool" | "acorn-stack"
  model: claude-sonnet-4-20250514
  max_turns: 20
  timeout_ms: 600000
  stall_timeout_ms: 300000
  read_timeout_ms: 5000

  # Backend-specific: direct CLI invocation (Option A)
  api:
    base_url: null                   # Reserved for future HTTP API mode
    env_unset:                       # Env vars to unset in child process
      - CLAUDECODE
      - CLAUDE_CODE_ENTRYPOINT
      - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

  # Backend-specific: FLAME pool offloading (Option B)
  flame_pool:
    pool: SymphonyClaudePool
    idle_timeout_ms: 900000
    max_concurrency: 1
    min: 0
    max: 10

  # Backend-specific: Acorn stack containers (Option C -- NOT YET VIABLE)
  acorn_stack:
    template: symphony-claude
    image: flame-runner-claude:latest
    socket: /run/acorn/daemon.sock
    project: null
    services: {}

  permissions:
    mode: dangerously-skip           # "dangerously-skip" | "allowlist" | "default"
    allowed_tools: []
    disallowed_tools: []

  claude:
    output_format: stream-json       # "stream-json" | "json" | "text"
    system_prompt: null
    append_system_prompt: null
    mcp_config: null
    max_budget_usd: null
    effort: high                     # "low" | "medium" | "high"
    session_persistence: true
    include_partial_messages: true
    settings: null
    setting_sources: null
    agents: null
    agent: null
```

### 2.2 Key-by-Key Specification

#### Top-Level `execution:` Keys

| Key | NimbleOptions Type | Default | Required | Description |
|---|---|---|---|---|
| `backend` | `{:in, ["api", "flame-pool", "acorn-stack"]}` | `"api"` | No | Selects the execution backend. `"api"` runs Claude CLI locally via Port. `"flame-pool"` dispatches to a FLAME worker pool. `"acorn-stack"` is reserved for future Acorn container deployment. |
| `model` | `:string` | `"claude-sonnet-4-20250514"` | No | Claude model identifier. Accepts full names (`claude-sonnet-4-20250514`) or aliases (`sonnet`, `opus`). Passed as `--model` to the CLI. |
| `max_turns` | `:pos_integer` | `20` | No | Maximum number of agent turns per issue run. Each turn is a separate `--resume` invocation. Replaces `agent.max_turns` for the execution context. |
| `timeout_ms` | `:pos_integer` | `600_000` | No | Maximum wall-clock time for a single turn to complete. Replaces `codex.turn_timeout_ms`. |
| `stall_timeout_ms` | `:non_neg_integer` | `300_000` | No | Maximum idle time (no `stream-json` events) before declaring the agent stalled. `0` disables stall detection. Replaces `codex.stall_timeout_ms`. |
| `read_timeout_ms` | `:pos_integer` | `5_000` | No | Timeout for individual response reads during session initialization. Replaces `codex.read_timeout_ms`. |

#### `execution.api:` Keys (Option A)

| Key | NimbleOptions Type | Default | Description |
|---|---|---|---|
| `base_url` | `{:or, [:string, nil]}` | `nil` | Reserved. When set, Symphony would POST prompts to an HTTP API endpoint instead of spawning a local CLI process. Currently unused; the `api` backend always spawns a local `claude` process via `Port.open/2`. |
| `env_unset` | `{:list, :string}` | `["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"]` | Environment variables to unset in the child Claude CLI process. Prevents Claude Code from detecting it is running inside another Claude Code session. Follows the pattern established in apple-slicer's `Claude.run_claude_cli/3`. |

#### `execution.flame_pool:` Keys (Option B)

| Key | NimbleOptions Type | Default | Description |
|---|---|---|---|
| `pool` | `:string` | `"SymphonyClaudePool"` | Name of the FLAME pool module to dispatch work to. Must correspond to a pool started in the application supervision tree. |
| `idle_timeout_ms` | `:pos_integer` | `900_000` | How long an idle FLAME worker stays alive before being reclaimed. Set high for agent workloads to avoid container restart overhead between turns. |
| `max_concurrency` | `:pos_integer` | `1` | Maximum number of concurrent tasks per FLAME worker. `1` is correct for agent workloads (one Claude session per worker). |
| `min` | `:non_neg_integer` | `0` | Minimum number of FLAME workers to keep alive. `0` means scale-to-zero. |
| `max` | `:pos_integer` | `10` | Maximum number of FLAME workers. Should align with `agent.max_concurrent_agents`. |

#### `execution.acorn_stack:` Keys (Option C -- Future)

**Status: NOT YET VIABLE.** These keys are defined for forward compatibility. Validation will accept them but the `acorn-stack` backend will return an error at runtime until the Acorn daemon implements the required commands.

| Key | NimbleOptions Type | Default | Description |
|---|---|---|---|
| `template` | `:string` | `"symphony-claude"` | Name of the Acorn stack template. Maps to `StackTemplate.name` in apple-slicer. |
| `image` | `:string` | `"flame-runner-claude:latest"` | Container image for the worker service. |
| `socket` | `:string` | `"/run/acorn/daemon.sock"` | Path to the Acorn daemon Unix domain socket. Can be overridden via `ACORN_SOCKET` env var. |
| `project` | `{:or, [:string, nil]}` | `nil` | Acorn project name. If `nil`, auto-generated as `"symphony-<random_hex>"`. |
| `services` | `:map` | `%{}` | Compose-style service definitions passed to `spawn_stack`. Structure matches apple-slicer's `StackTemplate.services` field. |

**Acorn daemon gaps that block this backend** (from the Task 1.5 evaluation):

- `spawn_stack` -- not implemented in daemon
- `teardown_stack` -- not implemented in daemon
- `stack_status` -- not implemented in daemon
- `stack_service_discovery` -- not implemented in daemon
- `scale_service` -- not implemented in daemon
- `exec_container` -- 30s timeout, no streaming, no stdin forwarding (cannot support Claude sessions)

#### `execution.permissions:` Keys

| Key | NimbleOptions Type | Default | Description |
|---|---|---|---|
| `mode` | `{:in, ["dangerously-skip", "allowlist", "default"]}` | `"dangerously-skip"` | Permission mode. `"dangerously-skip"` passes `--dangerously-skip-permissions` (for sandboxed/trusted environments). `"allowlist"` uses `--allowedTools` and `--disallowedTools` for fine-grained control. `"default"` uses Claude Code's default permission behavior. |
| `allowed_tools` | `{:list, :string}` | `[]` | Tool allowlist when `mode` is `"allowlist"`. Each entry is a tool name or glob pattern (e.g., `"Bash(git:*)"`, `"Edit"`, `"mcp__symphony__linear_graphql"`). Passed as `--allowedTools`. Ignored when `mode` is not `"allowlist"`. |
| `disallowed_tools` | `{:list, :string}` | `[]` | Tool denylist. Entries are tool names or patterns to block. Passed as `--disallowedTools`. Applied regardless of `mode`. |

**Mapping to CLI flags:**

| `mode` value | CLI flag(s) |
|---|---|
| `"dangerously-skip"` | `--dangerously-skip-permissions` |
| `"allowlist"` | `--allowedTools "Tool1 Tool2 ..."` |
| `"default"` | (none -- uses Claude Code defaults) |

#### `execution.claude:` Keys

| Key | NimbleOptions Type | Default | Description |
|---|---|---|---|
| `output_format` | `{:in, ["stream-json", "json", "text"]}` | `"stream-json"` | Output format for Claude CLI. `"stream-json"` provides real-time structured events for the observability dashboard. `"json"` provides a single result object. `"text"` provides plain text (no structured metadata). Passed as `--output-format`. |
| `system_prompt` | `{:or, [:string, nil]}` | `nil` | Full system prompt override. When set, replaces Claude Code's built-in system prompt entirely. Passed as `--system-prompt`. Mutually exclusive with `append_system_prompt`. |
| `append_system_prompt` | `{:or, [:string, nil]}` | `nil` | Text appended to Claude Code's default system prompt. Passed as `--append-system-prompt`. Ignored if `system_prompt` is set. |
| `mcp_config` | `{:or, [:string, nil]}` | `nil` | Path to an MCP server configuration JSON file, or inline JSON string. Passed as `--mcp-config`. Used to expose Symphony's dynamic tools (e.g., `linear_graphql`) as MCP servers. |
| `max_budget_usd` | `{:or, [:float, nil]}` | `nil` | Per-invocation spending cap in USD. Passed as `--max-budget-usd`. Only effective with `--print` mode. `nil` means no cap. |
| `effort` | `{:in, ["low", "medium", "high"]}` | `"high"` | Reasoning effort level. Passed as `--effort`. Higher effort produces better results at higher cost/latency. |
| `session_persistence` | `:boolean` | `true` | Whether to persist session state to disk between turns. When `false`, passes `--no-session-persistence` and disables `--resume` across turns (each turn is fully independent). |
| `include_partial_messages` | `:boolean` | `true` | Whether to include partial message chunks in `stream-json` output. Passed as `--include-partial-messages`. Only effective when `output_format` is `"stream-json"`. |
| `settings` | `{:or, [:string, nil]}` | `nil` | Path to a Claude Code settings JSON file, or inline JSON string. Passed as `--settings`. |
| `setting_sources` | `{:or, [:string, nil]}` | `nil` | Comma-separated list of setting sources to load (`user`, `project`, `local`). Passed as `--setting-sources`. |
| `agents` | `{:or, [:string, nil]}` | `nil` | JSON object defining custom agents. Passed as `--agents`. |
| `agent` | `{:or, [:string, nil]}` | `nil` | Name of the agent to select for the session. Passed as `--agent`. |

---

## 3. NimbleOptions Validation Schema

The following is the complete NimbleOptions schema definition for the `execution:` section, designed to be added to `SymphonyElixir.Config`:

```elixir
@default_execution_backend "api"
@default_execution_model "claude-sonnet-4-20250514"
@default_execution_max_turns 20
@default_execution_timeout_ms 600_000
@default_execution_stall_timeout_ms 300_000
@default_execution_read_timeout_ms 5_000
@default_permissions_mode "dangerously-skip"
@default_output_format "stream-json"
@default_effort "high"
@default_env_unset [
  "CLAUDECODE",
  "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
]
@default_flame_pool "SymphonyClaudePool"
@default_flame_idle_timeout_ms 900_000
@default_flame_max_concurrency 1
@default_flame_min 0
@default_flame_max 10
@default_acorn_template "symphony-claude"
@default_acorn_image "flame-runner-claude:latest"
@default_acorn_socket "/run/acorn/daemon.sock"

# Add to @workflow_options_schema inside NimbleOptions.new!/1:
execution: [
  type: :map,
  default: %{},
  keys: [
    backend: [
      type: {:in, ["api", "flame-pool", "acorn-stack"]},
      default: @default_execution_backend,
      doc: "Execution backend: api (local CLI), flame-pool (FLAME workers), acorn-stack (future)"
    ],
    model: [
      type: :string,
      default: @default_execution_model,
      doc: "Claude model identifier or alias"
    ],
    max_turns: [
      type: :pos_integer,
      default: @default_execution_max_turns,
      doc: "Maximum agent turns per issue run"
    ],
    timeout_ms: [
      type: :pos_integer,
      default: @default_execution_timeout_ms,
      doc: "Maximum wall-clock time per turn in milliseconds"
    ],
    stall_timeout_ms: [
      type: :non_neg_integer,
      default: @default_execution_stall_timeout_ms,
      doc: "Maximum idle time before stall detection; 0 disables"
    ],
    read_timeout_ms: [
      type: :pos_integer,
      default: @default_execution_read_timeout_ms,
      doc: "Timeout for individual response reads during init"
    ],

    # Option A: direct CLI invocation
    api: [
      type: :map,
      default: %{},
      keys: [
        base_url: [type: {:or, [:string, nil]}, default: nil],
        env_unset: [type: {:list, :string}, default: @default_env_unset]
      ]
    ],

    # Option B: FLAME pool offloading
    flame_pool: [
      type: :map,
      default: %{},
      keys: [
        pool: [type: :string, default: @default_flame_pool],
        idle_timeout_ms: [type: :pos_integer, default: @default_flame_idle_timeout_ms],
        max_concurrency: [type: :pos_integer, default: @default_flame_max_concurrency],
        min: [type: :non_neg_integer, default: @default_flame_min],
        max: [type: :pos_integer, default: @default_flame_max]
      ]
    ],

    # Option C: Acorn stack containers (future)
    acorn_stack: [
      type: :map,
      default: %{},
      keys: [
        template: [type: :string, default: @default_acorn_template],
        image: [type: :string, default: @default_acorn_image],
        socket: [type: :string, default: @default_acorn_socket],
        project: [type: {:or, [:string, nil]}, default: nil],
        services: [type: :map, default: %{}]
      ]
    ],

    # Permission controls
    permissions: [
      type: :map,
      default: %{},
      keys: [
        mode: [
          type: {:in, ["dangerously-skip", "allowlist", "default"]},
          default: @default_permissions_mode
        ],
        allowed_tools: [type: {:list, :string}, default: []],
        disallowed_tools: [type: {:list, :string}, default: []]
      ]
    ],

    # Claude CLI-specific settings
    claude: [
      type: :map,
      default: %{},
      keys: [
        output_format: [
          type: {:in, ["stream-json", "json", "text"]},
          default: @default_output_format
        ],
        system_prompt: [type: {:or, [:string, nil]}, default: nil],
        append_system_prompt: [type: {:or, [:string, nil]}, default: nil],
        mcp_config: [type: {:or, [:string, nil]}, default: nil],
        max_budget_usd: [type: {:or, [:float, nil]}, default: nil],
        effort: [type: {:in, ["low", "medium", "high"]}, default: @default_effort],
        session_persistence: [type: :boolean, default: true],
        include_partial_messages: [type: :boolean, default: true],
        settings: [type: {:or, [:string, nil]}, default: nil],
        setting_sources: [type: {:or, [:string, nil]}, default: nil],
        agents: [type: {:or, [:string, nil]}, default: nil],
        agent: [type: {:or, [:string, nil]}, default: nil]
      ]
    ]
  ]
]
```

### 3.1 Custom Validation Rules

Beyond NimbleOptions type checks, the following rules should be enforced in `Config.validate!/0`:

```elixir
defp require_valid_execution_config do
  execution = get_in(validated_workflow_options(), [:execution])

  with :ok <- validate_backend_available(execution[:backend]),
       :ok <- validate_permissions_consistency(execution[:permissions]),
       :ok <- validate_claude_prompt_exclusivity(execution[:claude]),
       :ok <- validate_flame_pool_sizing(execution[:flame_pool], execution[:backend]) do
    :ok
  end
end

# Rule 1: acorn-stack backend is not yet available
defp validate_backend_available("acorn-stack") do
  {:error, {:backend_not_available, "acorn-stack",
    "Acorn stack backend is not yet viable. " <>
    "The Acorn daemon does not implement stack lifecycle commands. " <>
    "Use 'api' or 'flame-pool' instead."}}
end
defp validate_backend_available(_backend), do: :ok

# Rule 2: allowed_tools only meaningful with allowlist mode
defp validate_permissions_consistency(%{mode: mode, allowed_tools: tools})
     when mode != "allowlist" and tools != [] do
  {:error, {:permissions_inconsistency,
    "allowed_tools is set but mode is '#{mode}' (not 'allowlist'). " <>
    "Set mode to 'allowlist' or remove allowed_tools."}}
end
defp validate_permissions_consistency(_permissions), do: :ok

# Rule 3: system_prompt and append_system_prompt are mutually exclusive
defp validate_claude_prompt_exclusivity(%{system_prompt: sp, append_system_prompt: asp})
     when is_binary(sp) and is_binary(asp) do
  {:error, {:prompt_exclusivity,
    "system_prompt and append_system_prompt are mutually exclusive. " <>
    "Use system_prompt for a full override, or append_system_prompt to extend the default."}}
end
defp validate_claude_prompt_exclusivity(_claude), do: :ok

# Rule 4: FLAME pool max should be >= min
defp validate_flame_pool_sizing(%{min: min, max: max}, "flame-pool") when min > max do
  {:error, {:flame_pool_sizing, "flame_pool.min (#{min}) must be <= flame_pool.max (#{max})"}}
end
defp validate_flame_pool_sizing(_pool, _backend), do: :ok
```

---

## 4. Migration Path from `codex:` Section

### 4.1 Field Mapping

| Current (`codex:`) | New (`execution:`) | Notes |
|---|---|---|
| `codex.command` | Removed | No longer needed. Symphony constructs the `claude` CLI command from structured config. The `execution.backend` + `execution.claude.*` keys replace the raw command string. |
| `codex.turn_timeout_ms` | `execution.timeout_ms` | Renamed for clarity. Same semantics. |
| `codex.read_timeout_ms` | `execution.read_timeout_ms` | Moved up one level. Same semantics. |
| `codex.stall_timeout_ms` | `execution.stall_timeout_ms` | Moved up one level. Same semantics. |
| `codex.approval_policy` | `execution.permissions.mode` | `"never"` maps to `"dangerously-skip"`. Map-based policies map to `"allowlist"` with explicit tool lists. |
| `codex.thread_sandbox` | Removed | Claude Code CLI does not have a thread sandbox concept. Workspace-level isolation is handled by the `cd` option on `Port.open/2`. |
| `codex.turn_sandbox_policy` | Removed | Claude Code CLI does not support per-turn sandbox policies. Use `execution.permissions.mode` + OS-level containment instead. |
| `agent.max_turns` | `execution.max_turns` | Moved into `execution:` since it is an execution concern, not an agent-management concern. `agent.max_turns` remains as a deprecated alias during migration. |

### 4.2 Approval Policy Migration

The current `codex.approval_policy` supports two forms:

**String form** (`"never"`):
```yaml
# Before
codex:
  approval_policy: never

# After
execution:
  permissions:
    mode: dangerously-skip
```

**Map form** (selective rejection):
```yaml
# Before
codex:
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true

# After
execution:
  permissions:
    mode: allowlist
    allowed_tools:
      - Bash
      - Edit
      - Read
      - Write
      - Glob
      - Grep
      - WebFetch
      - mcp__symphony__linear_graphql
```

### 4.3 Backward Compatibility Strategy

During migration, Symphony should support both `codex:` and `execution:` sections with the following precedence:

1. If `execution:` is present, use it exclusively. Ignore `codex:` even if present.
2. If only `codex:` is present, map it to the `execution:` structure internally using the field mapping above. Log a deprecation warning.
3. If neither is present, use defaults (equivalent to `execution.backend: "api"` with all defaults).

Implementation in `Config.extract_workflow_options/1`:

```elixir
defp extract_workflow_options(config) do
  execution_section = section_map(config, "execution")
  codex_section = section_map(config, "codex")

  execution_opts =
    if map_size(execution_section) > 0 do
      extract_execution_options(execution_section)
    else
      if map_size(codex_section) > 0 do
        Logger.warning("WORKFLOW.md uses deprecated 'codex:' section. " <>
                       "Migrate to 'execution:' section. " <>
                       "See docs/workflow-stack-schema.md for the migration guide.")
        migrate_codex_to_execution(codex_section)
      else
        %{}
      end
    end

  %{
    tracker: extract_tracker_options(section_map(config, "tracker")),
    polling: extract_polling_options(section_map(config, "polling")),
    workspace: extract_workspace_options(section_map(config, "workspace")),
    agent: extract_agent_options(section_map(config, "agent")),
    execution: execution_opts,
    hooks: extract_hooks_options(section_map(config, "hooks")),
    observability: extract_observability_options(section_map(config, "observability")),
    server: extract_server_options(section_map(config, "server"))
  }
end

defp migrate_codex_to_execution(codex_section) do
  %{}
  |> put_if_present(:backend, "api")
  |> put_if_present(:timeout_ms, integer_value(Map.get(codex_section, "turn_timeout_ms")))
  |> put_if_present(:read_timeout_ms, integer_value(Map.get(codex_section, "read_timeout_ms")))
  |> put_if_present(:stall_timeout_ms, integer_value(Map.get(codex_section, "stall_timeout_ms")))
  |> put_if_present(:permissions, migrate_codex_approval_policy(codex_section))
end
```

### 4.4 `codex:` Section Removal Timeline

| Phase | Action |
|---|---|
| **Phase 1** (current) | Add `execution:` section support alongside `codex:`. `codex:` triggers a deprecation warning. |
| **Phase 2** (after all WORKFLOW.md files updated) | Remove `codex:` mapping code. `codex:` section is silently ignored. |
| **Phase 3** (cleanup) | Remove `codex:` parsing entirely. Remove `Config.codex_*` accessor functions. |

---

## 5. Example WORKFLOW.md with New Format

### 5.1 Minimal Configuration (API Backend)

```yaml
---
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
execution:
  backend: api
  model: claude-sonnet-4-20250514
  max_turns: 20
  timeout_ms: 600000
  permissions:
    mode: dangerously-skip
  claude:
    output_format: stream-json
    append_system_prompt: null
    mcp_config: .claude/symphony-mcp.json
---

You are working on a Linear ticket `{{ issue.identifier }}`
...
```

### 5.2 FLAME Pool Configuration (Distributed Execution)

```yaml
---
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
agent:
  max_concurrent_agents: 10
execution:
  backend: flame-pool
  model: claude-sonnet-4-20250514
  max_turns: 20
  timeout_ms: 600000
  stall_timeout_ms: 300000
  flame_pool:
    pool: SymphonyClaudePool
    idle_timeout_ms: 900000
    max_concurrency: 1
    min: 0
    max: 10
  permissions:
    mode: allowlist
    allowed_tools:
      - Bash
      - Edit
      - Read
      - Write
      - Glob
      - Grep
      - WebFetch
      - mcp__symphony__linear_graphql
    disallowed_tools:
      - "Bash(rm -rf:*)"
  claude:
    output_format: stream-json
    effort: high
    max_budget_usd: 5.00
    mcp_config: .claude/symphony-mcp.json
    include_partial_messages: true
---

You are working on a Linear ticket `{{ issue.identifier }}`
...
```

### 5.3 Future Acorn Stack Configuration (Not Yet Viable)

```yaml
---
# NOTE: This configuration will NOT work until the Acorn daemon implements
# stack lifecycle commands. See docs/acorn-stack-evaluation.md for details.
execution:
  backend: acorn-stack
  model: claude-sonnet-4-20250514
  max_turns: 20
  timeout_ms: 600000
  acorn_stack:
    template: symphony-claude
    image: flame-runner-claude:latest
    socket: /run/acorn/daemon.sock
    services:
      worker:
        image: flame-runner-claude:latest
        env:
          ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: "${DB_PASSWORD}"
  permissions:
    mode: dangerously-skip
  claude:
    output_format: stream-json
---
```

---

## 6. Config Accessor Functions

New accessor functions to add to `SymphonyElixir.Config`, replacing the `codex_*` family:

```elixir
# --- Execution backend ---

@spec execution_backend() :: String.t()
def execution_backend do
  get_in(validated_workflow_options(), [:execution, :backend])
end

@spec execution_model() :: String.t()
def execution_model do
  get_in(validated_workflow_options(), [:execution, :model])
end

@spec execution_max_turns() :: pos_integer()
def execution_max_turns do
  # Fall back to agent.max_turns for backward compatibility
  case get_in(validated_workflow_options(), [:execution, :max_turns]) do
    nil -> agent_max_turns()
    turns -> turns
  end
end

@spec execution_timeout_ms() :: pos_integer()
def execution_timeout_ms do
  get_in(validated_workflow_options(), [:execution, :timeout_ms])
end

@spec execution_stall_timeout_ms() :: non_neg_integer()
def execution_stall_timeout_ms do
  get_in(validated_workflow_options(), [:execution, :stall_timeout_ms]) |> max(0)
end

@spec execution_read_timeout_ms() :: pos_integer()
def execution_read_timeout_ms do
  get_in(validated_workflow_options(), [:execution, :read_timeout_ms])
end

# --- Permission mode ---

@spec execution_permissions_mode() :: String.t()
def execution_permissions_mode do
  get_in(validated_workflow_options(), [:execution, :permissions, :mode])
end

@spec execution_allowed_tools() :: [String.t()]
def execution_allowed_tools do
  get_in(validated_workflow_options(), [:execution, :permissions, :allowed_tools])
end

@spec execution_disallowed_tools() :: [String.t()]
def execution_disallowed_tools do
  get_in(validated_workflow_options(), [:execution, :permissions, :disallowed_tools])
end

# --- Claude CLI settings ---

@spec execution_output_format() :: String.t()
def execution_output_format do
  get_in(validated_workflow_options(), [:execution, :claude, :output_format])
end

@spec execution_mcp_config() :: String.t() | nil
def execution_mcp_config do
  get_in(validated_workflow_options(), [:execution, :claude, :mcp_config])
end

@spec execution_max_budget_usd() :: float() | nil
def execution_max_budget_usd do
  get_in(validated_workflow_options(), [:execution, :claude, :max_budget_usd])
end

@spec execution_effort() :: String.t()
def execution_effort do
  get_in(validated_workflow_options(), [:execution, :claude, :effort])
end

@spec execution_system_prompt() :: String.t() | nil
def execution_system_prompt do
  get_in(validated_workflow_options(), [:execution, :claude, :system_prompt])
end

@spec execution_append_system_prompt() :: String.t() | nil
def execution_append_system_prompt do
  get_in(validated_workflow_options(), [:execution, :claude, :append_system_prompt])
end

# --- Backend-specific ---

@spec execution_flame_pool_config() :: map()
def execution_flame_pool_config do
  get_in(validated_workflow_options(), [:execution, :flame_pool])
end

@spec execution_api_config() :: map()
def execution_api_config do
  get_in(validated_workflow_options(), [:execution, :api])
end

@spec execution_acorn_stack_config() :: map()
def execution_acorn_stack_config do
  get_in(validated_workflow_options(), [:execution, :acorn_stack])
end
```

---

## 7. CLI Command Construction

The `execution:` section is consumed by a new module (replacing AppServer's direct codex invocation) that constructs the `claude` CLI arguments from structured config:

```elixir
defmodule SymphonyElixir.Claude.CommandBuilder do
  @moduledoc """
  Constructs claude CLI arguments from execution config.
  """

  alias SymphonyElixir.Config

  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts \\ []) do
    base_args() ++
      model_args() ++
      output_args() ++
      permission_args() ++
      session_args(opts) ++
      prompt_args() ++
      mcp_args() ++
      budget_args() ++
      effort_args() ++
      tool_args() ++
      settings_args() ++
      [prompt]
  end

  defp base_args, do: ["-p"]

  defp model_args, do: ["--model", Config.execution_model()]

  defp output_args do
    args = ["--output-format", Config.execution_output_format()]

    claude_config = get_in(Config.validated_workflow_options(), [:execution, :claude])

    if claude_config[:include_partial_messages] && Config.execution_output_format() == "stream-json" do
      args ++ ["--include-partial-messages"]
    else
      args
    end
  end

  defp permission_args do
    case Config.execution_permissions_mode() do
      "dangerously-skip" -> ["--dangerously-skip-permissions"]
      "allowlist" -> allowlist_args()
      "default" -> []
    end
  end

  defp allowlist_args do
    allowed = Config.execution_allowed_tools()
    disallowed = Config.execution_disallowed_tools()

    args = []

    args =
      if allowed != [] do
        args ++ ["--allowedTools", Enum.join(allowed, " ")]
      else
        args
      end

    if disallowed != [] do
      args ++ ["--disallowedTools", Enum.join(disallowed, " ")]
    else
      args
    end
  end

  defp session_args(opts) do
    if opts[:resume_session_id] do
      ["--resume", opts[:resume_session_id]]
    else
      session_id = opts[:session_id] || generate_session_id()
      ["--session-id", session_id]
    end
  end

  defp prompt_args do
    cond do
      sp = Config.execution_system_prompt() -> ["--system-prompt", sp]
      asp = Config.execution_append_system_prompt() -> ["--append-system-prompt", asp]
      true -> []
    end
  end

  defp mcp_args do
    case Config.execution_mcp_config() do
      nil -> []
      config -> ["--mcp-config", config]
    end
  end

  defp budget_args do
    case Config.execution_max_budget_usd() do
      nil -> []
      budget -> ["--max-budget-usd", to_string(budget)]
    end
  end

  defp effort_args, do: ["--effort", Config.execution_effort()]

  defp tool_args do
    disallowed = Config.execution_disallowed_tools()

    if disallowed != [] && Config.execution_permissions_mode() != "allowlist" do
      ["--disallowedTools", Enum.join(disallowed, " ")]
    else
      []
    end
  end

  defp settings_args do
    claude_config = get_in(Config.validated_workflow_options(), [:execution, :claude])
    args = []

    args = if claude_config[:settings], do: args ++ ["--settings", claude_config[:settings]], else: args
    args = if claude_config[:setting_sources], do: args ++ ["--setting-sources", claude_config[:setting_sources]], else: args
    args = if claude_config[:agents], do: args ++ ["--agents", claude_config[:agents]], else: args
    args = if claude_config[:agent], do: args ++ ["--agent", claude_config[:agent]], else: args

    if claude_config[:session_persistence] == false do
      args ++ ["--no-session-persistence"]
    else
      args
    end
  end

  defp generate_session_id, do: UUID.uuid4()
end
```

---

## 8. Acorn Stack: Future Readiness Notes

### 8.1 Current Acorn Daemon Status (March 2026)

The Acorn daemon supports exactly three commands:

| Command | Status |
|---|---|
| `{"cmd":"ping"}` | Working |
| `{"cmd":"register","project":"..."}` | Working |
| `{"cmd":"status","project":"..."}` | Working |

All 15 other commands defined in the `AcornAPI` behaviour are **spec-only** -- the socket client sends valid JSON payloads, but the daemon does not process them.

### 8.2 What Needs to Happen Before `acorn-stack` Can Be Enabled

**Tier 1 -- Acorn daemon (upstream)**:
1. Implement container lifecycle: `run_container`, `stop_container`, `remove_container`, `inspect_container`, `list_containers`, `container_stats`
2. Mount daemon socket into containers at `/run/acorn/daemon.sock`
3. Implement stack orchestration: `spawn_stack`, `teardown_stack`, `stack_status`, `stack_service_discovery`, `list_stack_templates`, `list_stacks`
4. Implement scaling: `scale_service`, `list_service_instances`
5. Design and implement streaming exec protocol (websocket or multiplexed ndjson with stdin forwarding)

**Tier 2 -- apple-slicer (integration)**:
6. Expose HTTP/API endpoints for stack management
7. Extend `AcornSocketClient` with streaming exec support
8. Add stack-aware Claude runner

**Tier 3 -- Symphony (consumer)**:
9. Implement `StackOrchestrator` GenServer
10. Replace local `Port.open` sessions with remote stack-based sessions
11. Handle stack failures and re-dispatch

### 8.3 Schema Stability Guarantee

The `execution.acorn_stack:` keys defined in this schema are **forward-compatible placeholders**. When Acorn becomes viable:

- Existing keys (`template`, `image`, `socket`, `project`, `services`) will retain their types and semantics.
- New keys may be added (e.g., `scaling`, `networking`, `volumes`).
- No existing keys will be removed or have their types changed.

The runtime validation rule (`validate_backend_available("acorn-stack")`) will be relaxed once the Acorn daemon implements the required commands.

---

## 9. Relationship to Other Config Sections

The `execution:` section replaces `codex:` but interacts with other sections:

| Section | Interaction with `execution:` |
|---|---|
| `agent.max_concurrent_agents` | Limits how many `execution` sessions run simultaneously. For `flame-pool`, should align with `execution.flame_pool.max`. |
| `agent.max_turns` | **Deprecated in favor of `execution.max_turns`**. If both are set, `execution.max_turns` takes precedence. `agent.max_turns` is retained for backward compatibility. |
| `agent.max_retry_backoff_ms` | Unchanged. Controls orchestrator-level retry backoff, independent of execution backend. |
| `hooks.before_run` | Runs before the execution session starts. Receives the workspace path. |
| `hooks.after_run` | Runs after the execution session ends (success or failure). |
| `workspace.root` | The `execution` session's working directory is always within `workspace.root`. |
| `tracker.*` | Unchanged. The execution backend is agnostic to the issue tracker. |

---

## 10. Summary of Changes

| Item | Before | After |
|---|---|---|
| Section name | `codex:` | `execution:` |
| Agent backend | Hardcoded Codex `app-server` | Configurable: `api`, `flame-pool`, `acorn-stack` |
| Command construction | Raw command string (`codex.command`) | Structured config assembled into CLI args |
| Model selection | Embedded in `codex.command` string | Explicit `execution.model` key |
| Permission model | Codex-specific `approval_policy` + `thread_sandbox` + `turn_sandbox_policy` | `permissions.mode` + `allowed_tools` / `disallowed_tools` mapped to `--dangerously-skip-permissions` or `--allowedTools` |
| Output format | Hardcoded JSON-RPC stream | Configurable `stream-json`, `json`, or `text` |
| MCP integration | `dynamicTools` in JSON-RPC `thread/start` | `--mcp-config` flag pointing to MCP server config |
| System prompt | Not directly configurable | `system_prompt` or `append_system_prompt` |
| Cost control | Not available | `max_budget_usd` |
| Multi-turn strategy | Single Codex process with multiple `turn/start` | Separate `claude -p --resume` invocations per turn |
| FLAME pool support | Not available | Full `flame_pool:` sub-section |
| Acorn stack support | Not available | Placeholder `acorn_stack:` sub-section (not yet viable) |
