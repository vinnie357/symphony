# Symphony

Elixir fork of openai/symphony (origin: vinnie357/symphony, upstream: openai/symphony).

## Modes

1. **Standalone** — polls Linear for issues, routes by label, calls FLAME/flame_apple_container_backend directly
2. **API mode** — calls apple-slicer REST API to manage Acorn stacks for agent execution
3. **Embedded** — symphony embedded inside apple-slicer for same Acorn workflow

## Dev Setup

```bash
cd elixir && mise install
```

### mise tasks

- `mise run ci` — tests + credo
- `mise run web` — Phoenix web dashboard
- `mise run tui` — terminal status dashboard

## Key Modules

- `SymphonyElixir.Backend` — behaviour for agent execution backends
- `SymphonyElixir.AgentRouter` — label-based routing to backends
- `SymphonyElixir.Config` — NimbleOptions runtime config from WORKFLOW.md
- `SymphonyElixir.Orchestrator` — GenServer poll + dispatch loop
- `SymphonyElixir.Tracker` — behaviour (5 callbacks) for issue tracker adapters
- Backends: `elixir/lib/symphony_elixir/backends/{claude,codex,gemini,apple_slicer_api}.ex`

## Config

Runtime config loaded from `elixir/WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.

## Git

- Single-line commits: `type(scope): description`
- No attribution lines, no Co-Authored-By

## PRs

- No "changes" section (git diff handles that)
- Follow `.github/pull_request_template.md`

## Issue Tracking

Uses beads (`bd`) for issue tracking. Run `bd ready` to find work.
