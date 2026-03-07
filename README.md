# Symphony

Fork of [openai/symphony](https://github.com/openai/symphony) with multi-backend agent support.

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## What this fork adds

Upstream Symphony supports Codex as its sole agent backend. This fork extends the orchestrator with a pluggable backend system (`SymphonyElixir.Backend` behaviour) and ships four backends:

| Backend | Module | Description |
|---------|--------|-------------|
| **Claude** | `Backends.Claude` | Anthropic Claude via FLAME pools |
| **Codex** | `Backends.Codex` | OpenAI Codex app-server (upstream default) |
| **Gemini** | `Backends.Gemini` | Google Gemini |
| **AppleSlicerAPI** | `Backends.AppleSlicerAPI` | REST API to apple-slicer for Acorn-managed execution |

The `SymphonyElixir.AgentRouter` routes issues to backends based on Linear labels, so different issue types can use different agents in the same project.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Quick start

Check out [elixir/README.md](elixir/README.md) for environment setup and run instructions.

### Configuring backends

Backend routing is configured in `WORKFLOW.md` front matter. See [elixir/WORKFLOW.md](elixir/WORKFLOW.md) for the full configuration reference. The `SymphonyElixir.AgentRouter` selects a backend per issue based on label matching rules defined in the workflow config.

## Upstream

This fork tracks [openai/symphony](https://github.com/openai/symphony) as `upstream`. Upstream changes are periodically rebased into this fork.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
