# Symphony + Claude Code CLI Invocation Contract

Status: Research document -- Task 1.1
Date: 2026-03-05

---

## 1. Current Codex Invocation Contract

Symphony's Elixir implementation currently uses **Codex app-server** as its agent
backend. The integration lives in three modules:

| Module | File | Role |
|---|---|---|
| `AppServer` | `elixir/lib/symphony_elixir/codex/app_server.ex` | Low-level stdio JSON-RPC 2.0 client for the Codex process |
| `AgentRunner` | `elixir/lib/symphony_elixir/agent_runner.ex` | Multi-turn loop that drives AppServer for a single issue |
| `DynamicTool` | `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` | Client-side tool execution (e.g. `linear_graphql`) |

### 1.1 Process Lifecycle

```
Orchestrator
  |
  +--> AgentRunner.run(issue)
         |
         +--> Workspace.create_for_issue(issue)
         +--> AppServer.start_session(workspace)
         |      |
         |      +--> start_port(workspace)          # bash -lc "codex app-server"
         |      +--> send_initialize(port)           # JSON-RPC "initialize" + "initialized"
         |      +--> start_thread(port, workspace)   # JSON-RPC "thread/start"
         |
         +--> do_run_codex_turns(session, ...)       # multi-turn loop (up to agent.max_turns)
         |      |
         |      +--> AppServer.run_turn(session, prompt, issue)
         |      |      |
         |      |      +--> start_turn(port, ...)    # JSON-RPC "turn/start"
         |      |      +--> await_turn_completion()  # receive loop on port
         |      |
         |      +--> continue_with_issue?()          # check if Linear issue still active
         |      +--> (loop or exit)
         |
         +--> AppServer.stop_session(session)        # Port.close
         +--> Workspace.run_after_run_hook(...)
```

### 1.2 Port Launch

```elixir
# From AppServer.start_port/1
Port.open(
  {:spawn_executable, bash_path},
  [:binary, :exit_status, :stderr_to_stdout,
   args: ["-lc", Config.codex_command()],  # default: "codex app-server"
   cd: workspace,
   line: 1_048_576]
)
```

Key details:
- Launched via Erlang `Port` -- the Codex process is a child of the BEAM VM.
- Communication is **line-delimited JSON-RPC 2.0 over stdin/stdout**.
- The working directory is set to the per-issue workspace.
- `stderr` is merged into `stdout` (`stderr_to_stdout: true`).

### 1.3 JSON-RPC Protocol

**Session setup** (request/response pairs):

| Step | Method | Direction | Key Params |
|------|--------|-----------|------------|
| 1 | `initialize` | client -> server | `capabilities.experimentalApi`, `clientInfo` |
| 2 | `initialized` | client -> server | (notification, no id) |
| 3 | `thread/start` | client -> server | `approvalPolicy`, `sandbox`, `cwd`, `dynamicTools` |
| 4 | `turn/start` | client -> server | `threadId`, `input[{type:"text", text:prompt}]`, `cwd`, `title`, `approvalPolicy`, `sandboxPolicy` |

**Turn streaming** (notifications/requests from server):

| Method | Meaning | AppServer Handling |
|--------|---------|-------------------|
| `turn/completed` | Turn finished successfully | Return `{:ok, :turn_completed}` |
| `turn/failed` | Turn ended with error | Return `{:error, {:turn_failed, params}}` |
| `turn/cancelled` | Turn was cancelled | Return `{:error, {:turn_cancelled, params}}` |
| `item/commandExecution/requestApproval` | Shell command needs approval | Auto-approve or block |
| `item/fileChange/requestApproval` | File write needs approval | Auto-approve or block |
| `item/tool/call` | Dynamic tool invocation | Execute via `DynamicTool` and send result |
| `item/tool/requestUserInput` | Tool needs user input | Auto-answer with canned response |
| `execCommandApproval` | (legacy) Command approval | Auto-approve or block |
| `applyPatchApproval` | (legacy) Patch approval | Auto-approve or block |

### 1.4 Approval Policy and Sandbox Configuration

From `Config`:

```elixir
# Default approval policy -- rejects interactive prompts
@default_codex_approval_policy %{
  "reject" => %{
    "sandbox_approval" => true,
    "rules" => true,
    "mcp_elicitations" => true
  }
}

# Default thread sandbox
@default_codex_thread_sandbox "workspace-write"

# Default turn sandbox policy (constructed per workspace)
%{
  "type" => "workspaceWrite",
  "writableRoots" => [workspace_path],
  "readOnlyAccess" => %{"type" => "fullAccess"},
  "networkAccess" => false,
  "excludeTmpdirEnvVar" => false,
  "excludeSlashTmp" => false
}
```

When `auto_approve_requests` is `true` (approval_policy == `"never"`), all
command execution and file change approvals are automatically accepted with
`"acceptForSession"` or `"approved_for_session"`.

### 1.5 Dynamic Tools

The `DynamicTool` module registers client-side tools that Codex can invoke.
Currently there is one:

- **`linear_graphql`** -- Executes a raw GraphQL query/mutation against the
  Linear API using Symphony's configured auth token. The tool spec is sent
  in the `thread/start` message under `dynamicTools`.

### 1.6 Multi-Turn Loop

`AgentRunner.do_run_codex_turns/8` implements the outer multi-turn loop:

1. A single Codex app-server session is started (one OS process, one thread).
2. Each "turn" sends a new `turn/start` with a prompt.
3. After a turn completes, the runner checks whether the Linear issue is
   still in an active state (`Config.linear_active_states()`).
4. If active and `turn_number < max_turns`, it sends another turn with a
   continuation prompt (no re-stating of original instructions).
5. The default `max_turns` is **20** (configurable via `agent.max_turns`).
6. The turn timeout is **3,600,000 ms** (1 hour) by default.

### 1.7 Configuration Surface (WORKFLOW.md)

The `codex` section in `WORKFLOW.md` exposes:

| Key | Default | Purpose |
|-----|---------|---------|
| `command` | `"codex app-server"` | Shell command to launch the agent backend |
| `turn_timeout_ms` | `3,600,000` | Max time to wait for a single turn to complete |
| `read_timeout_ms` | `5,000` | Timeout for individual JSON-RPC responses |
| `stall_timeout_ms` | `300,000` | (Used by orchestrator for stall detection) |
| `approval_policy` | `{reject map}` | Codex approval policy (string or map) |
| `thread_sandbox` | `"workspace-write"` | Thread-level sandbox type |
| `turn_sandbox_policy` | `{workspaceWrite map}` | Turn-level sandbox policy |

---

## 2. Claude Code CLI Flags and Modes

Based on `claude --help` (version 2.1.63):

### 2.1 Core Invocation Modes

| Mode | Flags | Description |
|------|-------|-------------|
| **Interactive** | (default, no flags) | Opens a REPL session with user interaction |
| **Print (single-shot)** | `-p` / `--print` | Runs prompt, prints response, exits. Skips workspace trust dialog. |
| **Streaming JSON** | `--print --output-format stream-json` | Like print mode but emits structured JSON events in real-time |
| **Session resume** | `--continue` / `--resume <session-id>` | Continues an existing conversation |

### 2.2 Key Flags for Non-Interactive/Orchestrated Use

| Flag | Description | Notes |
|------|-------------|-------|
| `-p` / `--print` | Single-shot mode, prints and exits | **Required** for non-interactive use |
| `--model <model>` | Model selection | Accepts aliases (`sonnet`, `opus`) or full names (`claude-sonnet-4-6`) |
| `--output-format <fmt>` | Output structure | `text` (default), `json` (single result), `stream-json` (realtime events) |
| `--dangerously-skip-permissions` | Bypass all permission checks | For sandboxed/trusted environments only |
| `--allow-dangerously-skip-permissions` | Enable permission bypass as an option | Does not auto-skip, just enables the capability |
| `--permission-mode <mode>` | Permission mode | `acceptEdits`, `bypassPermissions`, `default`, `dontAsk`, `plan` |
| `--system-prompt <prompt>` | Override system prompt | Full replacement |
| `--append-system-prompt <prompt>` | Append to default system prompt | Additive |
| `--max-budget-usd <amount>` | Spending cap per invocation | Only with `--print` |
| `--allowedTools <tools>` | Restrict available tools | e.g. `"Bash(git:*) Edit Read"` |
| `--disallowedTools <tools>` | Block specific tools | e.g. `"Bash(git:*)"` |
| `--tools <tools>` | Specify exact built-in tool set | `""` disables all, `"default"` for all, or list specific names |
| `--mcp-config <configs>` | Load MCP server configurations | JSON file paths or inline JSON strings |
| `--strict-mcp-config` | Only use MCP servers from `--mcp-config` | Ignores other MCP configurations |
| `--add-dir <dirs>` | Allow tool access to additional directories | Extends workspace scope |
| `--input-format <fmt>` | Input format | `text` (default) or `stream-json` for realtime streaming input |
| `--include-partial-messages` | Include partial chunks | Only with `--print` and `stream-json` output |
| `--json-schema <schema>` | Structured output validation | JSON Schema for output |
| `--effort <level>` | Reasoning effort | `low`, `medium`, `high` |
| `--fallback-model <model>` | Automatic model fallback on overload | Only with `--print` |
| `--no-session-persistence` | Disable session saving to disk | Only with `--print` |
| `--settings <file-or-json>` | Load additional settings | Path to JSON file or inline JSON |
| `--setting-sources <sources>` | Control setting sources | Comma-separated: `user`, `project`, `local` |
| `--disable-slash-commands` | Disable all skills | |
| `--agents <json>` | Define custom agents | JSON object with agent definitions |
| `--agent <agent>` | Select agent for session | Overrides `agent` setting |

### 2.3 Session Continuation

| Flag | Behavior |
|------|----------|
| `-c` / `--continue` | Resume the most recent conversation in the current directory |
| `-r` / `--resume <session-id>` | Resume a specific session by ID |
| `--session-id <uuid>` | Use a specific session ID (must be valid UUID) |
| `--fork-session` | When resuming, create a new session ID instead of reusing the original |

### 2.4 Output Formats (with `--print`)

**`--output-format text`** (default): Plain text response on stdout.

**`--output-format json`**: Single JSON object on completion:
```json
{
  "type": "result",
  "subtype": "success",
  "cost_usd": 0.003,
  "duration_ms": 1234,
  "duration_api_ms": 1100,
  "is_error": false,
  "num_turns": 1,
  "result": "The response text here",
  "session_id": "uuid-here",
  "total_cost_usd": 0.003
}
```

**`--output-format stream-json`**: Newline-delimited JSON events:
```json
{"type": "system", "subtype": "init", "session_id": "..."}
{"type": "assistant", "subtype": "text", "text": "partial text..."}
{"type": "assistant", "subtype": "tool_use", "tool": "Bash", ...}
{"type": "result", "subtype": "success", "result": "...", "cost_usd": ...}
```

---

## 3. Apple-Slicer's Existing Claude CLI Integration

The `AppleSlicer.Claude` module (`apple-slicer/lib/apple_slicer/claude.ex`)
demonstrates a simpler, single-shot invocation pattern:

### 3.1 Invocation

```elixir
# From AppleSlicer.Claude.run_claude_cli/3
System.cmd(
  "sh",
  ["-c", "cat #{tmp_file} | claude -p --model #{model}"],
  stderr_to_stdout: true,
  env: merged_env
)
```

Key characteristics:
- Uses `--print` mode exclusively (single-shot, no session management).
- Pipes prompt from a temp file via stdin to avoid shell escaping issues.
- Uses `--model` flag (default: `"haiku"`).
- Unsets nested-session env vars (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) to prevent Claude Code from
  detecting it is running inside another Claude Code session.
- Result is plain text (`--output-format` not specified, defaults to `text`).
- Dispatches work to remote FLAME workers for horizontal scaling.

### 3.2 Limitations for Symphony Use

- No multi-turn: each invocation is completely independent.
- No tool restrictions: does not use `--allowedTools` or `--dangerously-skip-permissions`.
- No structured output: parses raw text, losing cost/token metadata.
- No session continuation: no `--resume` or `--continue`.
- No sandbox/approval policy: relies on default Claude Code behavior.

---

## 4. Feature Mapping: Codex AppServer to Claude Code CLI

### 4.1 Direct Equivalents

| Codex Feature | Codex Mechanism | Claude Code CLI Equivalent |
|---|---|---|
| Launch agent process | `Port.open` + `codex app-server` | `Port.open` + `claude -p ...` (or `System.cmd`) |
| Set working directory | Port `cd:` option | Port `cd:` option (same) |
| Provide prompt | `turn/start` JSON-RPC `input` | CLI argument, stdin pipe, or `--input-format stream-json` |
| Model selection | Codex internal config | `--model <model>` |
| Structured output | JSON-RPC events on stdout | `--output-format stream-json` (line-delimited JSON) |
| Auto-approve commands | `approvalPolicy: "never"` + client-side approval handler | `--dangerously-skip-permissions` or `--permission-mode bypassPermissions` |
| Sandbox to workspace | `sandboxPolicy.writableRoots` | `--add-dir` for additional dirs (workspace is implicit from `cd`) |
| Custom system prompt | Not directly (Codex has its own) | `--system-prompt` or `--append-system-prompt` |
| Tool restrictions | Not directly in current code | `--allowedTools` / `--disallowedTools` / `--tools` |
| MCP servers | Codex internal | `--mcp-config <file>` / `--strict-mcp-config` |
| Cost control | Not present | `--max-budget-usd <amount>` |
| Session persistence | Codex thread/session model | `--session-id`, `--resume`, `--continue` |
| Spending visibility | JSON-RPC `usage` fields | `stream-json` result events include `cost_usd` |

### 4.2 Features Requiring Adaptation

| Symphony Need | Codex Approach | Claude Code Adaptation Required |
|---|---|---|
| **Multi-turn within one process** | Single app-server process, multiple `turn/start` calls on same thread | Option A: Use `--resume <session-id>` across separate CLI invocations. Option B: Use `--input-format stream-json` for a long-lived streaming session. |
| **Dynamic tools (e.g. `linear_graphql`)** | `dynamicTools` in `thread/start` + `item/tool/call` callback | Register as an MCP server via `--mcp-config`. Symphony would run a local MCP server that exposes `linear_graphql`. |
| **Approval handling** | Client-side JSON-RPC approval response loop | Use `--dangerously-skip-permissions` to bypass entirely, or `--permission-mode dontAsk` / `bypassPermissions`. |
| **Turn-level sandbox policy** | `sandboxPolicy` in `turn/start` (writableRoots, networkAccess, etc.) | No direct equivalent. Claude Code's sandbox model differs. Use OS-level sandboxing (e.g., Docker, firejail) or rely on `--allowedTools` to restrict capabilities. |
| **Stall detection** | `codex_stall_timeout_ms` in orchestrator | Implement in Symphony by monitoring `stream-json` event timestamps or using `timeout` on the Port. |
| **Thread identity** | `thread/start` returns a `thread_id` | `--session-id <uuid>` provides explicit session identity. Result JSON includes `session_id`. |

---

## 5. Recommended Invocation Pattern for Symphony

### 5.1 Primary Approach: `--print` with `--output-format stream-json` and `--resume`

The recommended pattern launches Claude Code CLI per-turn using `--print` mode
with `stream-json` output, and uses `--resume` for multi-turn continuation.

```
# Turn 1 (initial)
claude -p \
  --model opus \
  --output-format stream-json \
  --include-partial-messages \
  --dangerously-skip-permissions \
  --append-system-prompt "<symphony context>" \
  --mcp-config symphony-mcp.json \
  --allowedTools "Bash Edit Read Write Glob Grep WebFetch mcp__symphony__linear_graphql" \
  --max-budget-usd 5.00 \
  --session-id "<deterministic-uuid>" \
  "<prompt text>"

# Turn 2+ (continuation, if issue still active)
claude -p \
  --model opus \
  --output-format stream-json \
  --include-partial-messages \
  --dangerously-skip-permissions \
  --resume <session-id-from-turn-1> \
  --max-budget-usd 5.00 \
  "<continuation prompt>"
```

### 5.2 Port-Based Invocation (Elixir Side)

```elixir
# Conceptual -- replaces AppServer.start_port/1
defp launch_claude_turn(workspace, prompt, opts) do
  args = build_claude_args(prompt, opts)

  port = Port.open(
    {:spawn_executable, System.find_executable("claude")},
    [:binary, :exit_status, :stderr_to_stdout,
     args: args,
     cd: workspace,
     line: 1_048_576]
  )

  # Read stream-json lines from port
  # Each line is a JSON object with type/subtype
  # Final line has type: "result"
  {:ok, port}
end

defp build_claude_args(prompt, opts) do
  base = [
    "-p",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--model", opts[:model] || "opus",
    "--dangerously-skip-permissions"
  ]

  session_args = if opts[:resume_session_id] do
    ["--resume", opts[:resume_session_id]]
  else
    ["--session-id", opts[:session_id] || UUID.uuid4()]
  end

  prompt_args = [prompt]

  optional =
    []
    |> maybe_add("--append-system-prompt", opts[:system_prompt])
    |> maybe_add("--mcp-config", opts[:mcp_config_path])
    |> maybe_add("--max-budget-usd", opts[:max_budget_usd])
    |> maybe_add("--allowedTools", opts[:allowed_tools])

  base ++ session_args ++ optional ++ prompt_args
end

defp build_claude_env do
  [
    {"CLAUDECODE", nil},
    {"CLAUDE_CODE_ENTRYPOINT", nil},
    {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", nil}
  ]
end
```

### 5.3 Stream-JSON Event Processing

Replace the Codex JSON-RPC receive loop with a `stream-json` line parser:

| Codex Event | stream-json Equivalent | Action |
|---|---|---|
| `turn/completed` | `{"type": "result", "subtype": "success"}` | Extract `result`, `cost_usd`, `session_id` |
| `turn/failed` | `{"type": "result", "subtype": "error_*"}` | Extract error details |
| `item/tool/call` | (not applicable -- tools run inside Claude Code) | N/A unless using MCP |
| Approval requests | (not applicable -- skipped by `--dangerously-skip-permissions`) | N/A |
| Streaming text | `{"type": "assistant", "subtype": "text"}` | Forward to observability/dashboard |
| Tool use events | `{"type": "assistant", "subtype": "tool_use"}` | Log for observability |

### 5.4 Dynamic Tools via MCP

Instead of the `dynamicTools` parameter in `thread/start`, expose Symphony's
tools as an MCP server:

```json
{
  "mcpServers": {
    "symphony": {
      "command": "path/to/symphony-mcp-server",
      "args": ["--linear-token-env", "LINEAR_API_KEY"],
      "env": {}
    }
  }
}
```

The MCP server would expose:
- `linear_graphql` -- same interface as `DynamicTool`, but accessible via MCP protocol.
- Future tools (e.g. `linear_update_issue`, `symphony_report_status`) can be added.

### 5.5 Multi-Turn Strategy

Two viable approaches:

**Option A: Separate CLI invocations with `--resume`** (recommended)

- Each turn is a separate `claude -p --resume <session-id>` invocation.
- Session state is managed by Claude Code internally.
- Symphony's `AgentRunner` continues to own the outer loop.
- The `session_id` from turn 1's result JSON feeds into turn 2's `--resume` flag.
- Pro: Clean process lifecycle per turn, simple error recovery.
- Con: Process startup overhead per turn; relies on session persistence.

**Option B: Long-lived streaming session with `--input-format stream-json`**

- A single Claude CLI process stays alive.
- Symphony sends new prompts via stdin as stream-json input events.
- Pro: No process restart overhead, maintains full context.
- Con: More complex lifecycle management; harder to recover from crashes.

### 5.6 Environment Variable Hygiene

Following apple-slicer's pattern, always unset nested-session variables:

```elixir
base_env = %{
  "CLAUDECODE" => nil,
  "CLAUDE_CODE_ENTRYPOINT" => nil,
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" => nil
}
```

---

## 6. Gaps and Open Questions

### 6.1 Sandbox Policy Parity

**Gap**: Codex supports fine-grained `sandboxPolicy` with `writableRoots`,
`readOnlyAccess`, and `networkAccess` controls sent per-turn. Claude Code CLI
does not expose equivalent per-invocation sandbox configuration.

**Mitigation options**:
- Use `--allowedTools` / `--disallowedTools` to restrict tool access (coarser).
- Use `--permission-mode bypassPermissions` paired with OS-level containment
  (Docker, `firejail`, macOS sandbox-exec).
- Accept reduced sandbox granularity if running in a trusted environment.

### 6.2 Dynamic Tool Protocol

**Gap**: Codex has a built-in `item/tool/call` callback mechanism for
client-side tools. Claude Code CLI does not support client-side tool callbacks
in `--print` mode.

**Mitigation**: Implement dynamic tools as an MCP server that Claude Code
connects to via `--mcp-config`. This requires:
- Building an MCP server process (could be part of Symphony or a separate binary).
- Passing the MCP config file path to each Claude CLI invocation.
- Managing the MCP server lifecycle alongside Symphony.

### 6.3 Session Continuation Reliability

**Open question**: How reliable is `--resume <session-id>` across separate
CLI process invocations? Specifically:
- Is the session state persisted to disk between invocations?
- What is the session storage format and location?
- Are there size limits or TTLs on persisted sessions?
- Does `--no-session-persistence` conflict with `--resume`?

### 6.4 Cost and Token Accounting

**Improvement over Codex**: Claude Code CLI provides `cost_usd` in result
events, which Codex does not directly. However:
- Is `cost_usd` accurate for all model types?
- Does `--max-budget-usd` account for tool-use token costs?
- How does the budget interact with `--resume` (is it per-invocation or
  per-session)?

### 6.5 Error Classification

**Gap**: Codex provides typed error events (`turn/failed`, `turn/cancelled`).
Claude Code CLI's `stream-json` result events need investigation:
- What `subtype` values exist for errors?
- How are rate limits, context window exhaustion, and network errors reported?
- Is there a distinction between retriable and terminal errors?

### 6.6 Approval Policy Granularity

**Open question**: `--dangerously-skip-permissions` is all-or-nothing. For
production use, Symphony may want:
- Auto-approve file edits within the workspace but block network access.
- Allow specific shell commands but block others.
- `--permission-mode` options (`acceptEdits`, `dontAsk`, `plan`) may provide
  some middle ground, but their exact behavior needs testing.
- `--allowedTools` with glob patterns (e.g. `Bash(git:*)`) provides
  command-level control but is not approval-based.

### 6.7 Streaming Input for Long-Lived Sessions

**Open question**: The `--input-format stream-json` mode could enable a
long-lived Claude Code process that receives multiple prompts. Questions:
- What is the input event schema for `stream-json` input?
- Can it simulate multi-turn conversations within a single process?
- How does it interact with `--output-format stream-json`?
- Is the `--replay-user-messages` flag relevant for acknowledgment?

### 6.8 Agent and Plugin System

**Opportunity**: Claude Code's `--agents` and `--agent` flags could replace
Symphony's prompt template system:
- Define a Symphony agent with a built-in prompt and tool configuration.
- Use `--agent symphony-worker` instead of `--append-system-prompt`.
- The `--plugin-dir` flag could load project-specific plugins.

### 6.9 Configuration Injection

**Current state**: Symphony reads all configuration from `WORKFLOW.md` and
passes it programmatically to Codex. With Claude Code CLI:
- `--settings <file-or-json>` can inject settings.
- `--setting-sources` can control which setting files are loaded.
- `.claude/settings.json` in the workspace could be pre-populated by the
  `after_create` hook.
- Need to determine which settings override which (user vs project vs CLI flags).

### 6.10 `codex.command` Migration Path

The current `codex.command` config key (default `"codex app-server"`) would
need to change. Two options:

**Option 1 -- Raw command (user specifies flags):**
```yaml
codex:
  command: >
    claude -p
    --output-format stream-json
    --dangerously-skip-permissions
    --model opus
    --mcp-config .claude/symphony-mcp.json
```

**Option 2 -- Structured config (Symphony constructs the command):**
```yaml
agent_backend:
  type: claude-code
  model: opus
  permission_mode: bypass
  mcp_config: .claude/symphony-mcp.json
  max_budget_usd: 5.00
  allowed_tools: "Bash Edit Read Write Glob Grep"
```

Option 2 is preferred for maintainability and validation.
