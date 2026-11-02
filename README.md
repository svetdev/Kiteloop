# Kiteloop

<img src="design/kiteloop-logo.svg" alt="Kiteloop logo" width="120" align="right" />

A native macOS app where you lead a team of AI agents that talk to each other — chat-first, always running.

Kiteloop spawns each agent as a [Claude Code](https://github.com/anthropics/claude-code) subprocess and orchestrates them: agents have their own profiles and knowledge, message each other, and share an event bus. Each one runs under its own permission mode and deny list, and an unattended run is bounded by a worktree, a gate and a person. Think of it as a team workspace where some of your teammates happen to be agents.

It runs the `claude` CLI with the login you already have, so on a Claude subscription your usage stays on the subscription — there is no separate Agent SDK pool or metering (an Anthropic API key, AWS Bedrock, and Ollama work too). The dollar figures inside the app — cost caps, budgets, per-item spend — are token-equivalents reported by the CLI, what Kiteloop paces itself against rather than anything you are charged.

## Features

- **Agent teams** — define agents with a profile, model, and domain knowledge; they persist across messages and sessions
- **A backlog that runs itself — when you say so** — the Planner (the grooming loop that drafts items) keeps the plan real, drafting groomed, gate-checked items toward each project's goal, and the fleet (the scheduler that runs projects unattended) works it: worker → reviewer → your approval gate → a merge that must verify green. Off by default; arming requires a daily budget and per-project consent, and a five-rung trust ladder shows exactly where you stand
- **Operator tools** — grant any agent a scoped token and it can read the same instruments you do, tweak configs and start runs on your ask in chat — everything except approving its own work
- **Permission boundaries** — an agent runs under the permission mode and the deny list it is spawned with, enforced by the CLI itself — Claude Code's auto mode by default, whose classifier decides each tool call; an unattended run always uses auto mode and answers to a worktree, a gate and a person
- **Tool bridge** — agents get Kiteloop-native MCP tools (publish events, message other agents, search the knowledge base) over named pipes
- **Local project memory** — all per-project state lives in a human-readable `.kiteloop/` directory; no cloud sync. The one database is derived: a SQLite metrics index at `~/.kiteloop/metrics.sqlite3`, rebuilt from the JSONL logs whenever it is deleted
- **Backends** — Claude via your Claude account (subscription), an Anthropic API key, or AWS Bedrock (SSO); local models via Ollama; experimental GitHub Copilot bridge. Agents reference model families (`opus`, `sonnet`, `haiku`) — concrete model IDs are resolved per backend at launch

Honest footnote: the success metrics in [docs/success-metrics.md](docs/success-metrics.md) are still marked unmeasured, and the project is maintained by one person.

## Prerequisites

To run the app:

- **macOS 14+**, **Xcode 16+** (Swift 6)
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **Node.js 20+**
- One Claude auth method: a Claude account (run `claude` once and sign in), an Anthropic API key, or AWS Bedrock via SSO — or Ollama for local models only

For the test suite and the repo's hooks, not for running the app:

- **lizard** — `brew install lizard-analyzer` (or `pip install lizard`); not `brew install lizard`, which is a compressor with the same binary name — what the suite's preflight complexity gate measures with (Swift, Python and TypeScript); the preflight runs `gate.py --skip-missing-tools`, so without it the gate is reported as skipped rather than failed
- **SwiftLint** — `brew install swiftlint` — what the CRAP postflight reads function complexity from after a green suite run (CRAP is a complexity-vs-coverage score, `cc² × (1 − coverage)³ + cc`)
- **jq** — `brew install jq` — the tracked `.claude/settings.json` hook uses it

## Download

Signed builds are on the [Releases page](https://github.com/svetdev/Kiteloop/releases). Building from source is below.

## Getting Started

```bash
git clone https://github.com/svetdev/Kiteloop.git
cd Kiteloop/Kiteloop
open Kiteloop.xcodeproj
```

Build and Run (Cmd+R). A setup wizard appears on first launch: it validates your tools (Claude CLI, Node, credentials), lets you pick starter agents, and writes config to `~/.kiteloop/`.

For a first run, pick **Try a Sample Project** from the + menu in the tab bar: it installs a tiny bundled repo with two groomed items and the worker and reviewer already assigned ([Kiteloop/examples/sample-project/README.md](Kiteloop/examples/sample-project/README.md)).

See [Kiteloop/GETTING_STARTED.md](Kiteloop/GETTING_STARTED.md) for a walkthrough.

## How it works

Start with **[docs/how-kiteloop-works.md](docs/how-kiteloop-works.md)** — the
operating model in one read: loops you configure, instruments you read, agents
you talk to; the Planner fills the plan and the fleet works it; one daily
ceiling bounds everything autonomous. The picture version is
[docs/architecture-controls.drawio](docs/architecture-controls.drawio).

Deeper, as needed: [docs/autopilot-runbook.md](docs/autopilot-runbook.md) (how
to operate it, in the app and headless), [docs/control-api.md](docs/control-api.md)
(every endpoint), [docs/how-work-flows.md](docs/how-work-flows.md) (the
execution pipeline), [docs/backlog-format.md](docs/backlog-format.md) (the plan
file itself).

## Defining Agents

Agents are defined as packages — a folder with an `agent.json`, a `profile.md` (system prompt), and optional `knowledge/*.md` files:

```
knowledge/agents/my-agent/
├── agent.json      # handle, version, template (name, model, systemPrompt, …), knowledge
├── profile.md      # who the agent is and how it works
└── knowledge/      # domain docs — the ones agent.json's `knowledge` block names are inlined or linked into the agent's context
```

Two example agents ship in `Kiteloop/examples/agents/`. The format is documented in [knowledge/README.md](knowledge/README.md).

## Repo Structure

Why every file is here: [docs/repo-map.md](docs/repo-map.md). The shape:

```
Kiteloop/
├── Kiteloop/                  # Xcode project (Swift, SwiftUI)
│   ├── Kiteloop/              # App source (Models, Views, ViewModels, Services, Runtime)
│   ├── KiteloopCore/          # Host-less core: a local Swift package, tested under `swift test`; its KiteloopTestSupport target holds the helpers both test targets share
│   ├── KiteloopTests/         # Unit tests (app-hosted; Support/ re-exports KiteloopTestSupport and holds ControlServerHarness)
│   ├── KiteloopUITests/       # UI tests
│   └── examples/              # Bundled example agent packages and the sample project
├── KiteloopMobile/            # iOS companion: drives the Mac's control API from a phone
├── knowledge/                 # Your agent packages (agents/ starts empty)
├── copilot-bridge-extension/  # VS Code extension exposing Copilot over a socket (experimental)
├── scripts/                   # The suite runner, its preflight checks, release tooling and the pairing forwarder
├── quality/                   # cleat, vendored: the quality gates `quality.json` configures (same author, same MIT licence; quality/README.md)
└── docs/                      # Architecture and feature docs
```

The pairing forwarder is described in [docs/autopilot-runbook.md](docs/autopilot-runbook.md#4-the-pairing-forwarder-what-the-qr-sheet-actually-uses); cleat's adoption guide is [quality/README.md](quality/README.md).

## Testing

```bash
cd Kiteloop

# the standing check — compiles the app and the test bundles, runs nothing
xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing

# the host-less core's tests — no test host, safe while the app runs
(cd KiteloopCore && swift test)

# the full suite — quit Kiteloop first; the script refuses if you forget
../scripts/run-unit-suite.sh
```

`build-for-testing` is the check every change is expected to pass: plain `build`
never compiles `KiteloopTests`, and `build-for-testing` launches nothing, so it
is safe while the app is open.

The full `test` run is not. `KiteloopTests` is hosted by `Kiteloop.app`, so
`xcodebuild … test` starts a second Kiteloop as its test host and macOS
terminates the instance you already have running — quit Kiteloop before you run
it. It runs in parallel across host clones and takes about two minutes; the
package's tests need no host at all. [CONTRIBUTING.md](CONTRIBUTING.md#quit-kiteloop-before-running-tests) has the
detail, along with how to run a single class or method.

## License

[MIT](LICENSE)
