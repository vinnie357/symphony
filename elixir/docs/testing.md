# Testing Guide

This guide covers the test suite architecture, how to run tests, and what is covered.

## Running Tests

```bash
mise run ci          # Full gate: format check, lint, coverage, dialyzer
mix test             # Tests only
mix test --only integration  # Integration tests only
```

## Test Architecture

### Tracker.Memory Adapter

`SymphonyElixir.Tracker.Memory` is an in-memory tracker adapter for tests. It stores
issues in application env (`:memory_tracker_issues`) and notifies a recipient process
(`:memory_tracker_recipient`) on state changes. Use it by setting `tracker.kind: memory`
in a test workflow file.

### MockBackend Pattern

For unit tests that need to control backend behavior, define a local `MockBackend`
module implementing the `SymphonyElixir.Backend` behaviour (`start_session/3`,
`run_turn/3`, `stop_session/1`). Use `Process.put/get` to wire up a test recipient
for assertions.

### MockCmd Pattern

For integration tests that exercise real GenServer processes but need to stub shell
commands, inject a `MockCmd` module via application env:

```elixir
Application.put_env(:symphony_elixir, :cmd_runner, MockCmd)
```

The Claude and Gemini backends read `:cmd_runner` at runtime, so tests can intercept
`System.cmd` calls without replacing the backend module itself.

### TestSupport Macro

`use SymphonyElixir.TestSupport` sets up ExUnit with `async: false`, configures a
temporary workflow file, and imports common aliases. All test modules should use it.

## Issue Lifecycle Flow

The orchestrator processes issues through these stages:

1. **Poll** — `Tracker.fetch_candidate_issues/0` returns issues in active states (e.g. Todo).
2. **Dispatch** — Orchestrator claims the issue, `AgentRouter` resolves a backend from
   issue labels, and `AgentRunner.run/3` executes via `Task.Supervisor`.
3. **Turn execution** — Backend calls `start_session/3` then `run_turn/3` in a loop.
4. **Completion** — Task exits normally; orchestrator marks it completed and schedules
   retry/reconciliation.
5. **Reconcile** — On next poll, terminal-state issues (Done, Cancelled) are cleaned up
   and removed from the running map.

### Boundary gaps

`Tracker.update_issue_state/2` and `Tracker.create_comment/2` are defined as callbacks
on the Tracker behaviour and implemented by the Memory adapter, but they are not yet
called by the orchestrator or agent runner in production code. The unit tests verify
these boundaries work in isolation; wiring them into the orchestrator is tracked
separately.

## Test Fixtures

- `test/fixtures/WORKFLOW.integration.md` — Pre-configured workflow for integration
  tests. Uses `tracker.kind: memory`, `execution.backend: claude`, conservative limits
  (`max_concurrent_agents: 2`, `max_turns: 3`), and a Liquid prompt template.

## Test File Overview

| File | Scope | Tests |
|------|-------|-------|
| `orchestrator_lifecycle_test.exs` | Unit: Tracker + Backend boundaries | 10 |
| `workflow_integration_config_test.exs` | Config: WORKFLOW fixture validation | 11 |
| `dashboard_verification_test.exs` | Web + TUI dashboard rendering | 13 |
| `orchestrator_integration_test.exs` | Integration: full issue lifecycle | 7 |
| `backends_test.exs` | Unit: individual backend modules | varies |
| `extensions_test.exs` | LiveView: dashboard extensions | varies |
