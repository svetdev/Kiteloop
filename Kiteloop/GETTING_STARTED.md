# Kiteloop — Getting Started

A native macOS app where you lead a team of AI agents that know your codebase. Each agent specializes in a domain and has deep knowledge baked in — architecture docs, key patterns, team conventions.

## Prerequisites

| Tool | Install | Why |
|------|---------|-----|
| macOS 14+ | — | The deployment target |
| Xcode 16+ | Mac App Store | Builds the app |
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` | LLM runtime |
| Node.js 20+ | `brew install node` | Required by Claude Code |
| GitHub CLI (optional) | `brew install gh && gh auth login` | Pull-request publishing, cloning an organisation's agent packages |

You also need one way to authenticate to Claude (pick in **Settings → General → Claude Backend**):

| Auth method | Setup |
|-------------|-------|
| Claude account (subscription) | Run `claude` in a terminal once and sign in — the default |
| Anthropic API key | Paste your key in Settings → Claude Backend |
| AWS Bedrock | `brew install awscli`, configure SSO, set region/profile in Settings |

## Install

```bash
git clone https://github.com/svetdev/Kiteloop.git
cd Kiteloop/Kiteloop
open Kiteloop.xcodeproj
```

In Xcode: select **Kiteloop** scheme, target **My Mac**, hit **Cmd+R**.

## First Launch — Setup Wizard

The app opens a setup wizard on first launch — one screen, two panels:

- **Checks** (left) — verifies Claude Code CLI, Node.js and your Claude auth method are working. GitHub CLI sits under an **Optional** header: it is for opening pull requests and cloning an organisation's agent packages, and Kiteloop runs without it
- **Agents** (right) — the available agent packages, listed by name (**Coder** and **Reviewer** are the bundled pair) and selected by default (a worker and a reviewer is what autopilot needs); deselect any

**Done** creates the home workspace at `~/.kiteloop/home/` with the selected agents and opens it; **Skip** creates nothing and the wizard returns on the next launch.

If you use Bedrock and AWS SSO is expired, run `aws sso login --profile <your-profile>` first.

## Try a Sample Project

The fastest first run: pick **Try a Sample Project** from the **+** menu in the tab bar. It copies a tiny bundled repo to `~/.kiteloop/sample-project`, initialises git, assigns Coder and Reviewer as worker and reviewer, and opens it — two groomed items sit `ready` for autopilot. What is in it: [examples/sample-project/README.md](examples/sample-project/README.md).

## Open your own repository

**Open Project…** in the same **+** menu (⌘O) shows a file panel; pick the repository's root folder and it opens as a tab. The start screen offers the same button when nothing is open, and recent projects are listed under the menu. Headless, `POST /v1/projects/open` with the path does the same over the control API ([docs/control-api.md](../docs/control-api.md)).

## Run one item

Open the **Autopilot** view from the sidebar, choose a worker and a reviewer, tick an item in the queue and press **▶ Run**. The worker builds it in its own git worktree, the reviewer checks it against the item's Validation list, and the result parks at your approval gate. Headless: `POST /v1/runs` ([docs/autopilot-runbook.md](../docs/autopilot-runbook.md), section B).

## Stop everything

While a run is up, the Autopilot view's controls pause after the current item (**⏸**) or stop immediately (**⏹**). To stop the whole fleet — every project — open the fleet drawer from the footer and press **Pause fleet**: it holds every queue and refuses new starts until you press **Resume**; headless that is `POST /v1/fleet/quiesce` and `POST /v1/fleet/resume`.

## What to Try

### Talk to an agent
Click any agent in the left sidebar (e.g. **Coder**). Type a question in the chat input at the bottom. The agent uses Claude (via your configured auth method) with full codebase access.

Good starter questions:
- "What's the architecture of this app?"
- "Where is the control API routed?"
- "Find every place the backlog file is parsed"

### Repo Status Badges
Agents that need repos you haven't cloned yet show an orange **!** badge. Right-click the agent → "Resolve Missing Repos…" to clone or link existing local repos.

### Memory
Click **Memory** in the sidebar. The app remembers decisions, preferences, and context across sessions. You can approve or dismiss proposed memories.

### Backlog
Click **Backlog** in the sidebar. The backlog is a plain `BACKLOG.md` in your project root — a shared task list agents can pick work from (the **Autopilot** sidebar view works through it autonomously). If the file doesn't exist, the panel offers to create a starter one.

`## Sections` are epics — *where* the work belongs — and the run order is the **lane**, not the section: every `lane:now` item, across every epic, runs before any `later` one (the default, left off the line), then document order. **Run now** and **Back to later** in an item's menu flip the lane (`POST /v1/backlog/lane` headlessly), and the item never leaves its epic.

One item, in the plain-markdown format:

```markdown
- [ ] task-1 | Add login screen | verify: npm test | lane:now
```

Items are `id | title` with optional ` | verify:`, ` | size:`, ` | lane:now` and status fields; checked items are done. A `verify:` runs from the project root, and a shell pipe inside it is written without spaces (`a --json|jq .`) because the fields are split on `" | "`. Edits made in the panel write back to the file, and external edits reload live. **Groom** on an item's page drafts its detail file (What / How / Validation, Out of Scope, a `verify:` and a size). The full format — frontmatter, detail files, every token — is [docs/backlog-format.md](../docs/backlog-format.md).

#### Stage flow

Items move through stages, tracked as a token on the item line (`- [ ] task-1 | Title | ready`):

```
Draft → Ready → Active → In Review → Awaiting Approval → Done
 you     you    agent      agent          agent           YOU
```

- **Draft** — new items land here; not groomed, so agents won't pick them up
- **Ready** — groomed and runnable; autopilot pulls from this stage
- **Active / In Review** — the worker agent codes, then the reviewer agent runs QA against the Validation criteria
- **Awaiting Approval** — the reviewer passed, and the item **stops here**. An agent passing its own review is not the work being accepted, so it waits for you with **Approve** / **Reject** buttons in the panel (Reject sends it back to Ready and writes your feedback into the detail file's Notes, which the next worker run reads)
- **Done** — a person's approval at the gate, or the `land` rung approving a review-passed run

How far a project goes on its own is the **Autonomy** dial on its Autopilot settings — `off` / `propose` / `land`, also `PUT /v1/autopilot`. `off` never picks the project up unattended; `propose` starts runs unattended and parks every review-passed run at your approval gate; `land` approves a review-passed run without asking and merges it — still only after a clean merge and a green `verify:` of the merged tree. Migrating from the older switches: see the autonomy dial section of [docs/control-api.md](../docs/control-api.md).

Tune the flow per project in **Project Settings → Backlog Flow**: toggle the Draft, Review, and approval stages, and choose which stages autopilot may pick up. Turning off "Require human approval" lets a passing agent review send items straight to Done — convenient solo, but the agent then grades its own work.

## Configuration

Per-project config lives at `.kiteloop/config.json` in the project root; for the home project — the default project managers open in, `~/.kiteloop/home/` — that is `~/.kiteloop/home/.kiteloop/config.json`:

```json
{
  "permissionMode": "acceptEdits",
  "deniedTools": [],
  "goal": "What this project is for, read by the Planner"
}
```

Backend/auth settings live in `~/.kiteloop/global-config.json` (managed from Settings → Claude Backend):

```json
{
  "claudeAuth": "bedrock",
  "bedrock": {
    "region": "us-east-1",
    "profile": "default",
    "modelMappings": {
      "opus": "<inference-profile-id>",
      "sonnet": "<inference-profile-id>"
    }
  }
}
```

`claudeAuth` is one of `subscription`, `apiKey`, `bedrock`. Agents store model *family aliases* (`opus`, `sonnet`, `haiku`); on Bedrock these map to inference-profile IDs via `bedrock.modelMappings` (edit to pin versions or use another region's profiles), while the API and subscription methods pass the alias to the CLI, which tracks the latest release.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Claude not found" | Run `npm install -g @anthropic-ai/claude-code` and restart |
| Agents stuck on "Starting..." | Check `aws sts get-caller-identity` — SSO may be expired |
| No agents load | Delete `~/.kiteloop` and relaunch to redo setup wizard |
| Repos show as missing | Click the orange badge or right-click → "Resolve Missing Repos" |

## Next

- [docs/how-kiteloop-works.md](../docs/how-kiteloop-works.md) — the operating model in one read: loops, instruments, agents; the Planner and the fleet
- [docs/autopilot-runbook.md](../docs/autopilot-runbook.md) — operating autopilot in the app and headless, gates, recovery
- [docs/autonomy.md](../docs/autonomy.md) — what stops a bad run reaching `main`, and what stops a run reporting success it did not earn
- [docs/backlog-format.md](../docs/backlog-format.md) — the `BACKLOG.md` contract as the parser implements it
