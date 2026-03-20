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
    git clone --depth 1 https://github.com/vinnie357/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
execution:
  backend: flame-pool
  model: claude-sonnet-4-20250514
  max_turns: 20
  timeout_ms: 3600000
claude:
  command: claude
  output_format: stream-json
  permission_mode: dangerously-skip
  allowed_tools: []
  disallowed_tools: []
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Issue context:

- Title: {{ issue.title }}
- State: {{ issue.state }}
- Priority: {{ issue.priority }}
{% if issue.description %}

Description:

{{ issue.description }}
{% else %}
No description provided — investigate the title and any linked context.
{% endif %}

{% if issue.labels.size > 0 %}
Labels: {{ issue.labels | join: ", " }}
{% endif %}

{% if issue.branch_name %}
Branch: {{ issue.branch_name }}
{% endif %}

{% if issue.url %}
Linear URL: {{ issue.url }}
{% endif %}

Instructions:

1. Read the issue carefully and understand the full scope of work.
2. Explore the codebase to understand existing patterns and architecture.
3. Implement the changes following existing code conventions.
4. Run tests to verify your changes work (`mix test` for Elixir code).
5. If you need to create or modify files, do so directly.
6. When complete, ensure all tests pass and the code compiles cleanly.
7. Do not push or create PRs — the orchestrator handles that.
