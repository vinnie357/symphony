# E2E Setup: Symphony + Apple-Slicer + Acorn

How to run the full agent orchestration stack locally.

## Architecture

```
Linear (issues)
    │
    ▼
Symphony (polls Linear, routes issues to backends)
    │
    ├── claude backend ──► Claude CLI (direct, simplest)
    │
    └── apple-slicer-api backend ──► Apple-Slicer REST API
                                         │
                                         ├── FLAME pool ──► Claude CLI
                                         │
                                         └── Acorn stacks ──► containers
                                               │
                                               └── acorn daemon (Unix socket)
```

## Repos

| Repo | Location | Branch | Purpose |
|------|----------|--------|---------|
| symphony | `~/github/symphony` | `feat/symphony-apple-slicer-integration` | Orchestrator: polls Linear, dispatches to backends |
| apple-slicer | `~/github/apple-slicer` | `main` | FLAME-based execution: manages runs, spawns Claude workers |
| acorn | `~/github/acorn` | `main` (vinnie357 fork) | Container runtime: daemon socket API for container lifecycle |

## Prerequisites

### Tools

```bash
# Elixir/Erlang (symphony + apple-slicer)
cd ~/github/symphony/elixir && mise install
cd ~/github/apple-slicer && mise install

# Rust (acorn)
# cargo via rustup — https://rustup.rs
```

### Environment variables

```bash
# Required
export LINEAR_API_KEY="lin_api_..."       # Linear personal API key
export ANTHROPIC_API_KEY="sk-ant-..."     # Claude CLI authentication

# Only for apple-slicer-api backend
export APPLE_SLICER_URL="http://localhost:4000"
```

### Linear project setup

Symphony polls a specific Linear project. Your `WORKFLOW.md` front matter sets:

```yaml
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"   # your project slug
  active_states: [Todo, In Progress, Merging, Rework]
  terminal_states: [Closed, Cancelled, Canceled, Duplicate, Done]
```

Get your project slug from the Linear project URL.

Optional custom Linear states for full workflow: `Rework`, `Human Review`, `Merging`.
Configure in Linear → Team Settings → Workflow.

## Build & Test (all repos)

```bash
# Acorn
cd ~/github/acorn
cargo build && cargo test
cargo install --path crates/acorn-cli   # install binary

# Apple-slicer
cd ~/github/apple-slicer
mix setup && mix test

# Symphony
cd ~/github/symphony/elixir
mix setup && mix test
```

## Running

### Option A: Claude backend (simplest — 2 processes)

Symphony spawns Claude CLI directly. No apple-slicer or acorn needed.

```bash
# 1. Verify acorn daemon is running (needed for container features)
acorn daemon status

# 2. Start Symphony
cd ~/github/symphony/elixir
LINEAR_API_KEY=lin_api_... mix symphony.tui
```

Update `WORKFLOW.md` front matter:

```yaml
execution:
  backend: claude
  model: sonnet
```

### Option B: Apple-Slicer API backend (full chain — 3 processes)

Symphony submits to apple-slicer, which manages runs and executes via FLAME.

```bash
# Terminal 1 — Acorn daemon (likely already running)
acorn daemon status

# Terminal 2 — Apple-slicer
cd ~/github/apple-slicer
mix phx.server                # http://localhost:4000

# Terminal 3 — Symphony
cd ~/github/symphony/elixir
APPLE_SLICER_URL=http://localhost:4000 mix symphony.tui
```

Update `WORKFLOW.md` front matter:

```yaml
execution:
  backend: apple-slicer-api
  model: sonnet
```

### Option C: Apple-Slicer + Acorn stacks (full chain with containers)

Same as Option B, but apple-slicer spawns agent workers inside acorn-managed containers.

Requires the `flame-runner-claude` container image:

```bash
cd ~/github/apple-slicer
container build -t flame-runner-base -f Containerfile.flame-runner-base .
container build -t flame-runner-claude -f Containerfile.flame-runner-claude .
```

Configure apple-slicer to use `AcornSocketClient` instead of `Mock`:

```elixir
# config/runtime.exs
config :apple_slicer, :acorn_api_adapter, AppleSlicer.Acorn.AcornSocketClient
```

Set the socket path (auto-detected inside acorn containers, manual on host):

```bash
export ACORN_SOCKET="$HOME/.acorn/daemon.sock"
```

## Compose stack (acorn)

An `acorn-compose.yaml` at the repo root defines the full stack:

```bash
# Build apple-slicer image
cd ~/github/apple-slicer
container build -t apple-slicer:latest .

# Start apple-slicer via acorn
cd ~/github/symphony
acorn up apple-slicer

# Run symphony on the host (connects to containerized apple-slicer)
cd ~/github/symphony/elixir
APPLE_SLICER_URL=http://apple-slicer.apple.local mix symphony.tui
```

For FLAME workers in containers, also build the worker images:

```bash
cd ~/github/apple-slicer
container build -t flame-runner-base:latest -f Containerfile.flame-runner-base .
container build -t flame-runner-claude:latest -f Containerfile.flame-runner-claude .

# Start with worker profile
cd ~/github/symphony
acorn up --profile with-worker
```

## Dashboards

| Dashboard | URL / Command | What it shows |
|-----------|---------------|---------------|
| Symphony TUI | `mix symphony.tui` | Terminal: active issues, agent status, backends |
| Symphony Web | `mix symphony.web` | LiveView: http://localhost:4001 |
| Apple-slicer | `mix phx.server` | LiveView: http://localhost:4000 |

## WORKFLOW.md backends

The `execution.backend` field in WORKFLOW.md front matter controls routing:

| Backend | Module | How it works |
|---------|--------|-------------|
| `codex` | `Backends.Codex` | Spawns Codex via JSON-RPC stdio (OpenAI, default upstream) |
| `claude` | `Backends.Claude` | Spawns `claude` CLI subprocess directly |
| `gemini` | `Backends.Gemini` | Spawns `gemini` CLI subprocess |
| `apple-slicer-api` | `Backends.AppleSlicerAPI` | POST/GET to apple-slicer REST API |

Per-issue override: add a label (`claude`, `codex`, `gemini`) to the Linear issue.
The `AgentRouter` checks issue labels before falling back to the configured default.

## Issue lifecycle

```
Todo ──► In Progress ──► agent works issue ──► PR opened
  │                                               │
  │                                               ▼
  │                                         Human Review
  │                                               │
  │                                          (user merges)
  │                                               │
  │                                               ▼
  └──────────────────────────────────────────── Done
```

Symphony polls every `polling.interval_ms` (default 5s). When an issue is in an
`active_state`, it dispatches to the resolved backend. When the issue reaches a
`terminal_state`, the agent stops and the workspace is cleaned up.

## API endpoints (apple-slicer)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/symphony/runs` | Submit issue for execution |
| GET | `/api/symphony/runs` | List runs |
| GET | `/api/symphony/runs/:id` | Run status |
| DELETE | `/api/symphony/runs/:id` | Cancel run |
| POST | `/api/symphony/runs/:id/turns` | Trigger next turn |

## Acorn daemon socket commands

The `AcornSocketClient` sends ndjson over Unix socket at `$ACORN_SOCKET`:

| Command | Purpose |
|---------|---------|
| `run_container` | Spawn a new container |
| `stop_container` | Stop gracefully |
| `remove_container` | Remove stopped container |
| `inspect_container` | Get container metadata |
| `list_containers` | List project containers |
| `exec_container` | Execute command inside container |
| `container_stats` | CPU/memory/PIDs |
| `scale_service` | Adjust replica count |
| `list_service_instances` | List service replicas |
| `spawn_stack` | Create multi-service stack |
| `teardown_stack` | Tear down stack |
| `stack_status` | Stack health |
| `stack_service_discovery` | Resolve service IPs |
| `list_stack_templates` | Available templates |
| `list_stacks` | Active stacks |

## Workspace structure

Symphony creates a workspace per issue under `workspace.root`:

```
~/code/symphony-workspaces/
  └── <issue-id>/
      ├── .git/          # cloned repo
      ├── lib/           # code written by agent
      └── test/          # tests written by agent
```

The `hooks.after_create` script in WORKFLOW.md bootstraps each workspace
(typically `git clone`).

## Troubleshooting

| Problem | Check |
|---------|-------|
| Symphony not picking up issues | `LINEAR_API_KEY` set? Project slug correct? Issue in `Todo` state? |
| Claude CLI fails | `ANTHROPIC_API_KEY` set? `claude --version` works? |
| Apple-slicer connection refused | Server running on :4000? `APPLE_SLICER_URL` set? |
| Acorn socket not found | `acorn daemon status` shows running? `$ACORN_SOCKET` path correct? |
| Container image missing | Build with `container build -t flame-runner-claude ...` |
| Stale FLAME workers | `container list` and remove stopped containers |
| Workspace permission error | Check `workspace.root` exists and is writable |

## Gitleaks

All repos use `.gitleaks.toml` for secret scanning. Run before pushing:

```bash
container run -v $(pwd):/code zricethezav/gitleaks detect --source="/code" -v
```

## Example test task

Use this to verify the full chain works without needing Linear.

### 1. Start services

```bash
# Acorn daemon (likely already running)
acorn daemon status

# Apple-slicer
cd ~/github/apple-slicer && mix phx.server

# (Optional) Symphony — not needed for this test, we use curl directly
```

### 2. Create a run

```bash
curl -s -X POST http://localhost:4000/api/symphony/runs \
  -H "Content-Type: application/json" \
  -d '{
    "issue": {
      "id": "test-count-100",
      "identifier": "TEST-1",
      "title": "Write a function that counts 1 to 100 in Elixir with tests",
      "state": "Todo"
    }
  }'
# Note the run "id" from the response
```

### 3. Create workspace and execute

```bash
# Create workspace
mkdir -p /tmp/symphony-test-count100
cd /tmp/symphony-test-count100 && git init && git commit --allow-empty -m "init"

# Execute via Claude CLI (haiku for speed)
claude --model haiku --dangerously-skip-permissions -p \
  "Create an Elixir module Counter in lib/counter.ex with a function count/0 \
   that returns a list of integers from 1 to 100. Also create test/counter_test.exs \
   with ExUnit tests that verify: count/0 returns a list of 100 elements, the first \
   element is 1, the last element is 100, and all elements are sequential. Write both files now."
```

### 4. Verify

```bash
# Add mix project + test helper
cat > mix.exs << 'MIXEOF'
defmodule Counter.MixProject do
  use Mix.Project
  def project, do: [app: :counter, version: "0.1.0", elixir: "~> 1.19"]
end
MIXEOF
cat > test/test_helper.exs << 'HELPEOF'
ExUnit.start()
HELPEOF

# Run tests
mix test
# Expected: 4 tests, 0 failures
```

### Expected output

```
lib/counter.ex     → Counter.count/0 returns Enum.to_list(1..100)
test/counter_test.exs → 4 tests: length, first, last, sequential
mix test             → 4 tests, 0 failures
```

### 5. Cleanup

```bash
rm -rf /tmp/symphony-test-count100
# Stop apple-slicer (Ctrl-C or kill the process)
```

## Quality gates

```bash
# Symphony
cd ~/github/symphony/elixir && make all

# Apple-slicer
cd ~/github/apple-slicer && mix test && mix credo --strict

# Acorn
cd ~/github/acorn && cargo test && cargo clippy --all-targets
```
