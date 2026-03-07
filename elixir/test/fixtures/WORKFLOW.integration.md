---
tracker:
  kind: memory
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 1000
workspace:
  root: /tmp/symphony-integration-workspaces
agent:
  max_concurrent_agents: 2
  max_turns: 3
  max_retry_backoff_ms: 5000
execution:
  backend: claude
  model: claude-sonnet-4-20250514
  max_turns: 3
  timeout_ms: 300000
claude:
  command: claude
  output_format: stream-json
  permission_mode: plan
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
hooks:
  timeout_ms: 30000
observability:
  dashboard_enabled: false
  refresh_ms: 5000
  render_interval_ms: 100
---

You are working on a test issue `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }}.
- Resume from the current workspace state.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an integration test session.
2. Work only in the provided workspace.
3. Report completed actions when done.
