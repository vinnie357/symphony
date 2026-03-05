# Acorn Stack Evaluation for Symphony Option C

Task 1.5: Evaluate whether Symphony can use apple-slicer's Acorn stack deployment
model instead of (or alongside) direct FLAME pool calls.

## 1. AcornAPI Operations: Implemented vs Spec-Only

The `AcornAPI` behaviour (`acorn_api.ex`) defines the full contract. The
`AcornSocketClient` (`acorn_socket_client.ex`) implements every callback by
sending ndjson commands over a Unix domain socket. However, the **Acorn daemon
itself does not yet support most of these commands** -- the module's own
`@moduledoc` states:

> "This module is a specification -- it documents what we WANT Acorn to expose."

| Operation | Callback | Socket Client | Daemon Support | Notes |
|---|---|---|---|---|
| `run_container/2` | Defined | Sends `run_container` cmd | **Unknown/gap** | Acorn daemon has no documented `run_container` command |
| `stop_container/3` | Defined | Sends `stop_container` cmd | **Unknown/gap** | Same -- spec only |
| `remove_container/2` | Defined | Sends `remove_container` cmd | **Unknown/gap** | Same |
| `inspect_container/2` | Defined | Sends `inspect_container` cmd | **Unknown/gap** | Same |
| `list_containers/1` | Defined | Sends `list_containers` cmd | **Unknown/gap** | Same |
| `exec_container/3` | Defined | Sends `exec_container` cmd | **Unknown/gap** | 30s recv_timeout; request/response only |
| `container_stats/2` | Defined | Sends `container_stats` cmd | **Unknown/gap** | Same |
| `scale_service/3` | Defined | Sends `scale_service` cmd | **Not implemented** | Explicitly called out as Gap 3 |
| `list_service_instances/2` | Defined | Sends `list_service_instances` cmd | **Not implemented** | Depends on scaling support |
| `spawn_stack/2` | Defined | Sends `spawn_stack` cmd | **Not implemented** | Gap 4: stack-level orchestration |
| `teardown_stack/2` | Defined | Sends `teardown_stack` cmd | **Not implemented** | Gap 4 |
| `stack_status/1` | Defined | Sends `stack_status` cmd | **Not implemented** | Gap 4 |
| `stack_service_discovery/1` | Defined | Sends `stack_service_discovery` cmd | **Not implemented** | Gap 4 |
| `list_stack_templates/0` | Defined | Sends `list_stack_templates` cmd | **Not implemented** | Gap 4 |
| `list_stacks/1` | Defined | Sends `list_stacks` cmd | **Not implemented** | Gap 4 |
| `expose_service/4` | Defined | Sends `expose_service` cmd | **Unknown/gap** | Cloudflare tunnel integration |
| `unexpose_service/3` | Defined | Sends `unexpose_service` cmd | **Unknown/gap** | Same |
| `list_tunnels/1` | Defined | Sends `list_tunnels` cmd | **Unknown/gap** | Same |
| `list_dns_domains/0` | Defined | **Local impl** (env var) | N/A | Reads `FLAME_DNS_DOMAIN` or defaults to `apple.local`; no daemon call |

**Known working daemon commands** (documented in the `@moduledoc`):

- `{"cmd":"ping"}` -- health check
- `{"cmd":"register","project":"..."}` -- project registration
- `{"cmd":"status","project":"..."}` -- project status

Everything else is aspirational. The socket client code is structurally
complete (it builds the right JSON payloads and handles responses), but the
daemon on the other end does not process these commands yet.

### API Contract Summary

- **Protocol**: ndjson over Unix domain socket at `/run/acorn/daemon.sock`
  (configurable via `ACORN_SOCKET` env var)
- **Request format**: `{"cmd":"<command>", ...fields...}\n`
- **Response format**: `{"ok":true|false, ...fields...}\n` or
  `{"status":"ok|error", ...fields...}\n`
- **Timeouts**: 5s connect, 30s recv
- **Adapter pattern**: `AcornAPI.adapter()` returns the configured module
  (Mock in tests, AcornSocketClient in production)

## 2. Stack Lifecycle Analysis

### StackTemplate Schema

Defined in `lib/apple_slicer/stacks/stack_template.ex`:

```elixir
schema "stack_templates" do
  field :name, :string                       # unique per workspace
  field :description, :string
  field :services, :map, default: %{}        # compose-style service definitions
  field :is_default, :boolean, default: false
  belongs_to :workspace, Workspace
  has_many :stack_instances, StackInstance
end
```

The `services` field holds a map of service definitions (worker, postgres, etc.)
passed directly to `spawn_stack` as `compose_config`.

### StackInstance Schema

Defined in `lib/apple_slicer/stacks/stack_instance.ex`:

```elixir
schema "stack_instances" do
  field :name, :string           # generated: "stack-<template_name>-<random_hex>"
  field :status, :string         # pending | deploying | running | degraded | stopped | error
  field :deployed_config, :map   # snapshot of template.services at deploy time
  field :service_ips, :map       # discovered IPs: %{"worker" => "192.168.64.10", ...}
  field :deployed_at, :utc_datetime
  field :torn_down_at, :utc_datetime
  belongs_to :workspace, Workspace
  belongs_to :stack_template, StackTemplate
end
```

Notable: `SliceExecution` (the FLAME task record schema) has a
`belongs_to :stack_instance` -- so the data model already links task executions
to the stack they ran on.

### deploy_template/2 Flow

```
deploy_template(template, workspace)
  1. Generate project name: "stack-<name>-<8_hex_chars>"
  2. adapter.spawn_stack(project_name, compose_config: template.services)
  3. adapter.stack_service_discovery(project_name) -> get service IPs
  4. Create StackInstance record with status "running" and discovered IPs
  -- on error: create StackInstance with status "error"
```

### teardown_instance/1 Flow

```
teardown_instance(instance)
  1. adapter.teardown_stack(instance.name, [])
  2. Update instance: status -> "stopped", torn_down_at -> now
```

### Additional Runtime Operations

- `refresh_instance_status/1` -- polls `stack_status` + `stack_service_discovery`
  and updates the StackInstance record
- `expose_instance_service/4` and `unexpose_instance_service/3` -- Cloudflare
  tunnel management per service
- `list_instance_tunnels/1` -- enumerate active tunnels

### AcornCliAdapter: The FLAME Bridge

`AcornCliAdapter` implements the `FLAME.AppleContainers.CLI` behaviour,
translating FLAME backend calls into Acorn API calls. Key design:

- `run_container/1` detects `--compose-config` arg and routes to `run_stack/3`
  instead of a single container spawn.
- `run_stack/3` calls `spawn_stack` then `stack_service_discovery`, constructs a
  `DATABASE_URL` from discovered postgres IP, and returns a combined result.
- `teardown_stack/2` wraps `teardown_stack` in the CLI result format.
- Image operations (`build_image`, `list_images`) are explicitly no-ops -- images
  are managed on the host.

## 3. Socket Client: exec_container and Long-Running Sessions

### Current exec_container Implementation

```elixir
def exec_container(project, name, command) do
  send_command(%{
    "cmd" => "exec_container",
    "project" => project,
    "name" => name,
    "command" => command
  })
end
```

The socket client uses `packet: :line` mode with a 30-second `@recv_timeout`.
This is a **synchronous request/response** pattern -- it sends a command, waits
for one line of JSON back, and returns.

### Can exec_container Run Long-Running Claude Sessions?

**No, not in its current form.** Several problems:

1. **30-second timeout**: Claude Code sessions (Codex) run for minutes to hours.
   The `@recv_timeout` of 30,000ms would kill the connection.

2. **Single-line response**: The protocol expects one JSON line back. A Claude
   session produces a continuous stream of JSON-RPC messages over stdio. The
   exec model would need to become a streaming/multiplexed connection.

3. **No stdin forwarding**: `exec_container` sends a command and waits for
   output. Codex's `AppServer` needs bidirectional stdio communication
   (it sends JSON-RPC requests to the codex process and receives streaming
   responses). The current exec protocol has no mechanism for this.

4. **No PTY/interactive support**: The daemon socket protocol is batch-oriented.
   There is no session multiplexing, no PTY allocation, no streaming.

### What exec_container CAN Do

- Run short commands: `["bin/app", "eval", "MyApp.some_function()"]`
- Health checks inside containers
- One-shot diagnostic commands
- Trigger a process that runs independently (fire-and-forget)

## 4. Acorn-Related Schemas, Migrations, and Config

### Database Migration

`priv/repo/migrations/20260301000001_create_stacks.exs`:
- `stack_templates` table with workspace foreign key and unique name index
- `stack_instances` table with workspace + template foreign keys, status index
- `slice_executions` has `stack_instance_id` foreign key (linking tasks to stacks)

### Configuration

From `config/runtime.exs`:
```elixir
if System.get_env("ACORN_SOCKET") do
  config :apple_slicer, :acorn_api_adapter, AcornSocketClient
  config :flame_apple_container_backend, :cli_adapter, AcornCliAdapter
end

if acorn_project = System.get_env("ACORN_PROJECT") do
  config :apple_slicer, :acorn_project, acorn_project
end
```

The Acorn integration is entirely opt-in via environment variables. Without
`ACORN_SOCKET`, the system falls back to Mock in tests and direct FLAME
container spawning in production.

### Availability Check

`AppleSlicer.Acorn.Availability` provides runtime checks:
- `available?/0` -- returns boolean
- `status/0` -- returns `{:ok, :connected}` or `{:unavailable, reason}`
- Results cached for 10 seconds via `persistent_term`
- Used by LiveViews to conditionally show stack management UI

## 5. Evaluation for Symphony's Needs

### Can Symphony Define a Stack Template in WORKFLOW.md?

**Partially.** Symphony's `WORKFLOW.md` already defines workspace hooks
(`after_create`, `before_remove`) and agent configuration. A stack template
could be embedded as additional YAML frontmatter:

```yaml
stack:
  template: "symphony-worker"
  services:
    worker:
      image: "symphony-codex:latest"
      env:
        CLAUDE_API_KEY: "${CLAUDE_API_KEY}"
    # optional companion services
```

apple-slicer's `Stacks.create_template/1` accepts exactly this structure in the
`services` field. The integration path would be:

1. Symphony parses `WORKFLOW.md` frontmatter and extracts `stack` config
2. Symphony calls apple-slicer's `Stacks.create_template/1` (or an API endpoint)
3. Symphony calls `Stacks.deploy_template/2` for each concurrent agent

**Gap**: There is no HTTP/API surface on apple-slicer for stack management.
Symphony would need either:
- Direct Elixir function calls (if running in the same BEAM node)
- A new REST/GraphQL API layer in apple-slicer
- Symphony managing Acorn daemon communication directly

### What Acorn Daemon Gaps Need Filling?

| Gap | Description | Severity for Symphony |
|---|---|---|
| **Container-to-host API** (Gap 1) | Daemon socket not mounted into containers; no `run_container` command | **Critical** -- without this, containers cannot spawn other containers |
| **Socket mounting** | Daemon socket at `/run/acorn/daemon.sock` is host-only | **Critical** -- prerequisite for all container management from within containers |
| **Scaling support** (Gap 3) | `scale_service` not implemented; Acorn creates exactly 1 container per service | **High** -- Symphony needs 10+ concurrent agents |
| **Stack orchestration** (Gap 4) | `spawn_stack`, `teardown_stack`, `stack_status`, `stack_service_discovery` not implemented | **High** -- the entire stack lifecycle depends on these |
| **Streaming exec** | `exec_container` is request/response with 30s timeout | **Critical for Option C** -- Claude Code sessions need bidirectional streaming |
| **Service discovery** | `stack_service_discovery` returns static IPs only after implementation | **Medium** -- needed for inter-service communication |

### Can exec_container Run Claude Code Sessions Inside a Stack Container?

**No.** This is the fundamental blocker for "Option C: run Claude Code inside
existing stack containers via exec." The reasons are detailed in Section 3
above. To make this work would require:

1. A new streaming exec protocol (websocket or multiplexed ndjson)
2. Stdin/stdout forwarding with session multiplexing
3. Configurable/infinite timeouts per exec session
4. PTY support for interactive terminal programs

This is effectively building a container exec subsystem comparable to
`docker exec -it` or `kubectl exec`, which is a substantial engineering effort.

### Are Stacks Better Than Direct FLAME Pool Calls?

**It depends on the workload pattern.** Analysis:

| Dimension | FLAME Pools (Current) | Acorn Stacks (Option C) |
|---|---|---|
| **Startup latency** | Fast -- FLAME spawns a container and runs a closure | Slow -- must spawn stack, wait for services, discover IPs |
| **Companion services** | Not supported -- each FLAME call is isolated | Built-in -- postgres, redis, etc. start alongside worker |
| **Session duration** | Short -- designed for request/response closures (120s default) | Long -- stack stays up until explicitly torn down |
| **Isolation** | Per-call -- each FLAME.call gets a fresh context | Per-stack -- shared state within a stack instance |
| **Concurrency model** | Pool with min/max/idle settings; auto-scaling | Manual: one stack = one worker (no replica support yet) |
| **Complexity** | Low -- `FLAME.call(Pool, fn -> ... end)` | High -- template management, lifecycle, service discovery |
| **Failure handling** | FLAME retries/replaces containers automatically | Manual -- must monitor `stack_status` and handle errors |

**For Symphony's specific use case** (running Codex agent sessions on Linear
tickets):

- Symphony runs Codex via `AppServer.start_session/1` which spawns a local
  `bash -lc codex ...` process and communicates over stdio JSON-RPC.
- Each agent run needs: (1) a workspace directory, (2) a codex process,
  (3) environment variables (API keys, config).
- Agent runs are long-lived (minutes to hours per ticket, with multiple turns).
- Symphony needs up to 10 concurrent agents (`max_concurrent_agents: 10`).

FLAME pools are designed for short, stateless function calls -- not for
long-running interactive sessions. But Symphony does not actually use FLAME
for its agent runs; it runs Codex directly on the local machine via
`Port.open/2`.

Stacks would be useful if Symphony wanted to:
- Run each agent in an isolated container (security/resource isolation)
- Provide per-agent companion services (dedicated databases, caches)
- Deploy agent workers on remote machines

But the exec_container gap makes this impractical today.

## 6. Recommendation: Stacks vs FLAME Pools

### Short-Term (Current State): Neither

Symphony's current architecture does not use FLAME or stacks. It runs Codex
processes locally via Erlang ports. This works and should not be changed until
there is a concrete need for containerized isolation.

### Medium-Term: FLAME Pools for Compute Offloading

If Symphony needs to offload work to remote containers (e.g., running more
agents than one machine can handle), FLAME pools are the simpler path:

- Well-tested in apple-slicer for Claude CLI calls
- No daemon gaps to fill
- `FLAME.call/3` handles container lifecycle automatically
- But: not suitable for long-running Codex sessions without significant
  FLAME backend modifications (idle timeout, session affinity)

### Long-Term: Stacks for Full Isolation

If Symphony needs full per-agent isolation with companion services, stacks
are architecturally correct but require substantial Acorn daemon work first.

### Verdict

**Do not adopt stacks for Symphony at this time.** The Acorn daemon gaps are
too large. Every stack-related command (`spawn_stack`, `teardown_stack`,
`stack_status`, `stack_service_discovery`, `scale_service`) is unimplemented
in the daemon. The exec_container protocol cannot support long-running
interactive sessions.

## 7. Required Work to Make Option C Viable

If Option C (stack-based deployment) were pursued, the following work would be
needed, roughly ordered by dependency:

### Tier 1: Acorn Daemon (Upstream)

1. **Implement container lifecycle commands** in the Acorn daemon:
   `run_container`, `stop_container`, `remove_container`, `inspect_container`,
   `list_containers`, `container_stats` (Gap 1)

2. **Mount daemon socket into containers** at `/run/acorn/daemon.sock` so
   containers can communicate with the host daemon (Gap 1 prerequisite)

3. **Implement stack orchestration** commands: `spawn_stack`,
   `teardown_stack`, `stack_status`, `stack_service_discovery`,
   `list_stack_templates`, `list_stacks` (Gap 4)

4. **Implement scaling support**: `scale_service`,
   `list_service_instances` (Gap 3)

5. **Design and implement streaming exec protocol** for long-running
   interactive sessions -- websocket upgrade or multiplexed ndjson with
   stdin forwarding and configurable timeouts

### Tier 2: apple-slicer (Integration)

6. **Expose HTTP/API endpoints** for stack management so Symphony can call
   apple-slicer remotely (currently all functions are internal Elixir calls)

7. **Extend AcornSocketClient** with streaming exec support (new
   `exec_container_stream/4` that returns a bidirectional stream)

8. **Add stack-aware Codex runner** that can start a Codex AppServer session
   inside a running stack container via the streaming exec protocol

### Tier 3: Symphony (Consumer)

9. **Add WORKFLOW.md stack configuration** parsing to extract template
   definitions from the workflow frontmatter

10. **Implement StackOrchestrator** GenServer that manages stack lifecycle
    alongside the existing polling orchestrator

11. **Replace local Port.open Codex sessions** with remote stack-based
    sessions (exec into container, start codex, forward JSON-RPC)

12. **Handle stack failures** -- monitoring, restart, and re-dispatch of
    failed agent runs to new stack instances

### Estimated Effort

- Tier 1 (Acorn daemon): **Large** -- requires changes to the Acorn runtime,
  which is an Apple-maintained project. The streaming exec protocol alone is
  a significant feature.
- Tier 2 (apple-slicer): **Medium** -- 2-3 weeks of focused work given the
  existing adapter pattern and schema infrastructure.
- Tier 3 (Symphony): **Medium** -- 1-2 weeks given the clean orchestrator
  architecture.

**Total: The daemon work is the bottleneck.** Without upstream Acorn changes,
Tiers 2 and 3 cannot proceed beyond mock/test implementations.

## Appendix: Key Files Referenced

| File | Location |
|---|---|
| AcornAPI behaviour | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/acorn/acorn_api.ex` |
| AcornSocketClient | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/acorn/acorn_socket_client.ex` |
| AcornCliAdapter | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/acorn/acorn_cli_adapter.ex` |
| Mock adapter | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/acorn/mock.ex` |
| Availability checker | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/acorn/availability.ex` |
| Stacks context | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/stacks.ex` |
| StackTemplate schema | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/stacks/stack_template.ex` |
| StackInstance schema | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/stacks/stack_instance.ex` |
| SliceExecution schema | `/Users/vinnie/github/apple-slicer/lib/apple_slicer/slices/slice_execution.ex` |
| Stacks migration | `/Users/vinnie/github/apple-slicer/priv/repo/migrations/20260301000001_create_stacks.exs` |
| Runtime config | `/Users/vinnie/github/apple-slicer/config/runtime.exs` |
| Symphony Orchestrator | `/Users/vinnie/github/symphony/elixir/lib/symphony_elixir/orchestrator.ex` |
| Symphony AgentRunner | `/Users/vinnie/github/symphony/elixir/lib/symphony_elixir/agent_runner.ex` |
| Symphony AppServer | `/Users/vinnie/github/symphony/elixir/lib/symphony_elixir/codex/app_server.ex` |
| Symphony Workspace | `/Users/vinnie/github/symphony/elixir/lib/symphony_elixir/workspace.ex` |
| Symphony WORKFLOW.md | `/Users/vinnie/github/symphony/elixir/WORKFLOW.md` |
