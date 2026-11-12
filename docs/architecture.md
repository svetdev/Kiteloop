# Kiteloop Architecture

How the pieces fit together, and why they fit that way. This is the document to
read before changing something structural — it explains the boundaries that are
load-bearing, not the files that happen to exist today. `Services/` alone holds
more than eighty Swift files; an inventory of them would be wrong within a week,
whereas *why the observation logs stay authoritative* will not be.

Related, and deliberately not repeated here:

- [`how-work-flows.md`](how-work-flows.md) — who decides what gets built, and
  who is allowed to let it into `main`.
- [`control-api.md`](control-api.md) — the endpoint-by-endpoint reference.
- [`worktree-isolation.md`](worktree-isolation.md),
  [`adr/0001-autonomous-run-model.md`](adr/0001-autonomous-run-model.md) — the
  sandbox → PR → human-gate model.
- [`adr/0002-embedded-localhost-control-server.md`](adr/0002-embedded-localhost-control-server.md)
  — why the control API is in-process rather than a separate daemon.

## The shape of the app

Kiteloop is one native macOS process that supervises a fleet of `claude`
subprocesses. It does not implement an agentic loop, and it does not call the
Claude API. Each agent *is* a Claude Code session; Kiteloop supplies the
system prompt, the working directory, the tool scope, the coordination between
agents, and the record of what happened.

```
┌──────────────────────── Kiteloop.app (one process) ───────────────────────┐
│                                                                           │
│  SwiftUI views  ──►  ViewModels  ──►  Orchestrator (@MainActor)            │
│   Views/              ViewModels/      agents · sessions · eventBus ·      │
│                       ChatViewModel    workflowEngine · traceStore         │
│                                              │                            │
│  BacklogAutopilot ──── WorkflowEngine ───────┤                            │
│   (worker/reviewer run loop)                 │                            │
│                                              │                            │
│  KiteloopControlServer (127.0.0.1, off by default)                         │
│                                              │                            │
└──────────────────────────────────────────────┼────────────────────────────┘
                                               │  stdin/stdout: stream-json
                        ┌──────────────────────┼──────────────────────┐
                        ▼                      ▼                      ▼
                  claude (worker)       claude (reviewer)      claude (…)
                   + FIFOs: Kiteloop MCP tool bridge
```

`Orchestrator` (`Services/Orchestrator.swift`) is `@MainActor` and
`@Observable`: views read it directly and there is no HTTP hop inside the app.
The rule that follows from that is the one convention worth restating —
**never block the main actor with synchronous I/O**. Every `git` call, every
build, every file walk in this codebase goes through `Task.detached`. The places
that learned this the hard way say so in their comments: `BacklogAutopilot
.runDiff` drains the pipe before waiting because a `git diff` larger than the
~64 KB pipe buffer otherwise deadlocks, and it took the UI *and* the control API
down with it.

## Agent lifecycle: template → agent → session

Three distinct things, often conflated:

- **Template** (`Models/AgentTemplate.swift`) — a reusable definition: name,
  model, system prompt, tool lists, permission mode. Distributed as an
  **agent package** (`Models/AgentPackage.swift`): a `knowledge/agents/<name>/`
  directory holding `agent.json`, a profile and knowledge files. Bundled
  examples live in `Kiteloop/examples/agents/`.
- **Agent** (`Models/Agent.swift`) — a template instantiated into a project's
  team, with an identity that persists across messages, restarts and runs. The
  roster is `.kiteloop/team.json`; `Agent.state` is one of `idle`, `working`,
  `waitingForHuman`, `crashed`.
- **Session** (`AgentSession`) — one live subprocess. Sessions are cheap and
  disposable; agents are not. Restarting an agent into a different working
  directory is a normal operation, and it is how worktree isolation works.

Kiteloop talks to sessions through the `AgentRuntime` protocol
(`Runtime/AgentRuntime.swift`), never to `claude` directly:

```swift
protocol AgentRuntime: Sendable {
    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession
    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent>
    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent>
    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession)
    func interrupt(session: AgentSession)
    func stop(session: AgentSession)
}
```

`RuntimeRegistry` picks the implementation from `Agent.resolvedRuntimeKind`
(`RuntimeKind`: `.claude`, `.copilot`, `.ollama`). `ClaudeCodeCLIRuntime` is the
one that matters; `CopilotBridgeRuntime` and `OllamaRuntime` exist so the
protocol stays honest, and `RecordingAgentRuntime` / `ReplayAgentRuntime` let a
session be captured and replayed in tests without a model.

`ClaudeCodeCLIRuntime.provision` spawns roughly:

```
claude --print --output-format stream-json --input-format stream-json --verbose \
       --model <resolved> --max-turns <derived> --permission-mode <mode> \
       --permission-prompts host --permission-prompt-tool stdio \
       --allowedTools … [--disallowedTools …] --append-system-prompt <composed> \
       --mcp-config <tool bridge> [--resume <id>]
```

`--max-turns` is derived, not set: an autopilot worker's turn budget is read
off the project's own landed runs (`RunTimeouts`, in `KiteloopCore`), never
below 50 and never above 150, and 50 is what an agent runs on when nothing has
derived a budget for it. The worker's stall deadline and the merge gate's are
derived the same way — the phase's p95 plus half again, the worker's between 15
and 60 minutes with 20 as the fallback, the gate's 30 until five landed runs
have measured it.

Three things about that command are structural:

- **The system prompt is composed, not stored.** `Orchestrator.startAgent` asks
  the `ContextEngine` to build it from the agent's profile, project context and
  knowledge, and passes the result as `--append-system-prompt`. Nothing writes a
  generated `CLAUDE.md` per agent.
- **`ResumeStrategy`** (`.fresh`, `.resume`, `.fork`, `.compact`) is how an agent
  keeps its history across app restarts — the CLI session ids are persisted in
  the project's `config.json`.
- **An attended session asks; an unattended one is refused.** The CLI decides
  every tool call from `--permission-mode` and the agent's `--allowedTools`
  and `--disallowedTools`. Where a terminal would stop and ask its person, an
  attended session — a chat — asks Kiteloop instead (`--permission-prompts
  host --permission-prompt-tool stdio`): a `control_request` on its stdout,
  which `PermissionPrompt` reads, the chat shows as a card (`PermissionCards`)
  and the answer goes back on its stdin. That covers a call waiting on leave
  to run — a subagent's included — the model's own questions and a plan
  offered for approval; the session waits on each without limit, and the same
  channel changes a running session's mode and stops one of its tasks. In
  the three modes that promise to ask — `default`, `acceptEdits`, `plan` — an
  attended session is spawned with none of the agent's built-in tools in
  `--allowedTools` (`PermissionPrompt.asksBeforeListedTools`), only its MCP
  servers' tools and any rule it spells out, so the CLI asks as its mode
  says; in `auto`, `dontAsk` and `bypassPermissions` the whole list stays
  approved. That is fixed at spawn, so a mode change across the two groups
  replaces the process on the same conversation. An
  attended session runs in the agent's configured mode, `auto` unless it
  names another. An unattended one always runs in `auto` with
  `--permission-prompts none`, as described below: nobody is there, so a call
  that would have asked is refused. The subprocess's stderr is read only for
  the CLI's own diagnostics.
- **One MCP bridge over named pipes.** The *tool bridge* is a pair of FIFOs
  carrying Kiteloop's own MCP tools (`message_agent`, `publish_event`,
  `ask_human`, `recall_knowledge`, the `web_*` preview tools below, …). It is
  torn down through one function, `releaseBridge`, so no exit path can leak a
  FIFO.

### Kiteloop-provided tools (MCP)

Most tools on the bridge reach across the app — messaging another agent,
publishing an event, asking a human, searching the knowledge base. One family
reaches into the app's own UI instead: `web_*` lets an agent drive the
**Preview** tab of the inspector drawer — navigate, screenshot, read the
rendered page, and operate its controls by ref. Two things distinguish it from
the rest of the tool bridge:

- **Opt-in per agent, and reachable only by the one currently selected.** An
  agent sees a `web_*` tool only if its `tools` list names it, and even then
  only while it is the agent the human has selected — not a delegated agent,
  not a background autopilot worker or reviewer.
- **Gated by `WebNavigationPolicy`, not the CLI's permission flags.** Navigation is
  a pure decision (`WebNavigationPolicy.decide`,
  `Models/WebNavigationPolicy.swift`) over the pane's mode, the URL and who
  asked — allow, deny, or park for a human to confirm — rather than a risky
  call surfaced through the approval queue above. There is deliberately no
  tool that runs agent-authored JavaScript against the page.

Full reference, including the trust model and the tool table: [`web-preview.md`](web-preview.md).

During an autopilot run the worker and reviewer are marked unattended
(`Orchestrator.setUnattended`), which the spawn reads: they get
`--permission-mode auto`, whatever their own mode, and `--disallowedTools`
carrying only their own denials. Claude Code's auto-mode classifier decides each
tool call; Kiteloop adds no deny list of its own. The one-shot helpers
`HeadlessAgentRunner` spawns run the same way. There is no human to answer a
prompt at 3 a.m., so nothing asks one — what bounds a run beyond the classifier
is the worktree, the gate and a person. The macOS side of running unattended is
[`unattended-permissions.md`](unattended-permissions.md).

## The autopilot run

`Services/BacklogAutopilot.swift` runs a queue of backlog items, one item at a
time per project, each through a worker → reviewer loop. The run loop is
`start()` → `continueFromCurrentIndex()`.

Several rules in this section carry a date. Each is a run that went wrong in
exactly that way, and the dates are kept on purpose: a rule you can trace to
its incident is one you can judge.

### Pickup: refuse early, cheaply

An item is only picked up if it clears three gates, in this order:

1. **Stage** — its status is in `workflow.autopilotPickupStages` (default:
   `ready` only). Drafts are excluded on purpose.
2. **Definition of Ready** — `KiteloopCore/Sources/KiteloopCore/Services/DefinitionOfReady.swift`, the machine
   half of the ODD in `CLAUDE.md`: a groomed detail file with What/How/Validation
   (or the same content inline in the item line), a `verify:` command, and a size
   of M or smaller. The verdict names the unmet `Requirement` — `detail`, `what`,
   `how`, `validation`, `verify`, `size`, `sizeTooLarge` — so a skip says which
   clause to go and fix. The fourth ODD bullet, an explicit out-of-scope list, is
   *not* enforced: an empty one is a legitimate statement and reads identically to
   an unwritten one.
3. **Grounding** — `KiteloopCore/Sources/KiteloopCore/Services/GroundingCheck.swift` asks whether the item is
   *true* about the repo, not merely shaped right: every backticked path and
   symbol it cites has to exist. An item that cites something imaginary sends the
   worker hunting for it.

   A citation is resolved against the **corpus it belongs to**, not the repo
   alone: a `Corpus` for the repo, one for the optional shared vault of backlogs
   the item's backlog and detail files may live in (see
   [backlog-format.md](backlog-format.md#where-the-file-lives)), and one per
   sibling project that vault's registry (`Logs/registry.yaml`) lists — the
   last in scope only for an item that *names* that project. A dotted token is
   judged by its root, so `BacklogAutopilot.start` is a checkable claim about this
   code and `window.name` is not; an undotted name that isn't here is an invention
   when it is lower-camel (`checkCostCaps`) and a platform's type when it is
   capitalised (`DOMString`). Each refusal names the rule that made the token
   checkable as well as the token, so a false positive is a one-line read.

   The item's **`verify:` command** is read the same way, one step further than
   its executable: the paths it hands that executable are resolved from the
   directory it will run in — the project root, unless a `cd` in the command
   moved it. Twelve items on 2026-08-10 ran `xcodebuild -project
   Kiteloop.xcodeproj` from the root, where the project is at
   `Kiteloop/Kiteloop.xcodeproj`, and nothing said so until the merge gate, in
   front of a person. Only that one shape of miss refuses — the same relative
   path sitting under a directory the command never entered, which is a missing
   `cd` and names its own fix. A path the repo doesn't hold at all is left alone,
   since static text can't tell a file the command writes from one the run is
   about to create; whether a command can *pass* is not decidable from its text
   and is not attempted. A `cd` through a substitution stops the walk rather than
   guessing where it landed — with one exception, because that rule used to turn
   the check off for the very spelling `CLAUDE.md` recommends: `cd "$(git
   rev-parse --show-toplevel)/Kiteloop"` names the repo root, whose value is
   known from the text without running anything, so the walk restarts there and
   the rest of the command is judged. Every other `$(…)`, every backtick, `~` and
   absolute path still stops it.

All three refuse *before* spending a run. The alternative is an hour of worker
and reviewer discovering the item had nothing to build against, then blocking on
its own vagueness — which is what used to happen. Refusals are recorded in the
`GroomingLedger` so they outlive the in-memory log.

### Isolation

`WorktreeSession.begin` (`Services/WorktreeSession.swift`) creates
`.kiteloop/worktrees/<item-id>` on branch `kiteloop/<item-id>` and **restarts the
worker and reviewer into it** — a session's working directory is fixed at spawn,
so a fresh session is how an agent ends up editing the worktree. It returns nil
for a live-tree run (isolation off, no project root, not a git repository, or a
setup that failed and rolled itself back), so `session?.` reads exactly as "if we
isolated".

One detail that costs real money when it is missing: a worktree's `xcodebuild`
would otherwise derive its own `~/Library/Developer/Xcode/DerivedData` tree from
the worktree path, and register a second `.app` under the same bundle id — 113
dead build trees, and `open -a Kiteloop` resolving to a two-day-old binary out of
a long-merged worktree. `KiteloopCore/Sources/KiteloopCore/Services/WorktreeBuildOutput.swift` rewrites every
`xcodebuild` in the item's verify commands to build into
`<worktree>/.kiteloop/DerivedData`, which is inside an already-gitignored
directory so the build cannot dirty the worktree's `git status`. The worker is
told about the path in its prompt.

### Worker and reviewer

`buildWorkflowGraph` produces a four-node `WorkflowGraph` — `worker` →
`reviewer`, then `reviewer` → `done` (its JSON verdict says `passed: true`),
`reviewer` → `worker` (`passed: false`, feeding the failure back as
`previousFeedback`), or `reviewer` → `blocked` as the fallback edge. Retries are
bounded by the graph's `maxIterations`. `Orchestrator.startWorkflow` runs it, and
the execution id it returns is the run's identity everywhere else — including the
`runId` the control API hands back.

### How a run ends

`ItemResult.Outcome` has exactly four cases, and each one means something
different to the worktree. `WorktreeSession.teardownAction(for:)` is the single
pure function that maps between them:

| Outcome | Item status | Worktree teardown | What survives |
|---|---|---|---|
| `.done` | `done` | `.commit` | branch, if there was anything to commit |
| `.awaitingApproval` | `awaiting-approval` | `.commit` | branch, if there was anything to commit |
| `.blocked(reason)` | `blocked` (or back to `ready`) | `.keepForInspection` | branch **and** the worktree directory |
| `.cancelled` | back to `ready` | `.commit` | branch, if there was anything to commit — a cancel is not a verdict on the work |

Reading that table:

- **Passing review is not acceptance.** `accept()` parks the item at
  `awaiting-approval` for a human unless the project has configured
  `stageAfterAgentReview` to `done`. At the autonomy dial's `land` rung
  (`BacklogAutopilot.Autonomy`: `off` / `propose` / `land`) a review-passed run
  is approved without asking and a merge is then attempted — gated on a clean
  merge *and* a green `verify:` of the merged tree, never on the reviewer's
  opinion; `propose` parks it at the gate for a person. A failed merge leaves
  the item parked.
- **A run cut short can still be salvaged.** If the workflow failed or timed out
  (cost cap, stall, retry ceiling), `salvageVerifyPasses` re-runs the item's own
  `verify:` against the run's tree. Green means it clears the same objective bar
  acceptance uses, so the work is accepted rather than thrown away.
- **A blocked run commits and keeps its worktree.** This is the counter-intuitive
  one, and it is deliberate: a blocked run's output used to sit uncommitted in a
  directory nobody was told about, and the next attempt's `begin` force-removed
  it. On 2026-08-08 one item was run three times while a finished implementation
  of it sat in exactly that state. Committing costs a ref and turns the work into
  a diff a reader can find. `reportWorkLeftBehind` then names it — file count,
  branch, worktree path — in the run log and the item's notes, and the next
  attempt says so before starting over.
- **Cancelled commits too.** A cancel is not a verdict on the work — a driver's
  own timeout, a stop, an app quitting with the run up all end here — so the
  branch is committed and kept like a passing run's; only an empty branch is
  dropped. Discarding used to take uncommitted work with it.

### Did the run produce anything?

A run can walk the whole workflow, reach `done`, and have produced nothing at all
— the worker's session dies and the graph still steps to its accepting node. At
the gate that asks a human to approve a change that does not exist; approving it
stamps the item `done`.

`Services/RunWorkEvidence.swift` is the single git-based answer to that question.
It asks git, not cost: cost read $0 on nine of thirty-one runs on 2026-08-08 for
reasons that had nothing to do with the agents, so cost cannot carry this. Two
entry points, because the two endings leave different evidence:

- `inspect` — for a run that reached the gate: does the branch resolve, does it
  carry commits `HEAD` cannot already reach, and do those commits change files?
  Verdicts: `.produced`, `.noBranch`, `.noCommits`, `.emptyDiff`, `.unknown`.
- `inspectBlocked` — for a blocked run, whose worktree was kept and which commits
  nothing by design. `noCommits` is the *normal* state there, so reading it as
  emptiness would turn every review rejection into a dead-session diagnosis.
  What separates the two is the worktree: rejected work is still sitting in it.
  Either signal alone is enough to say the run produced something; it takes both
  reading empty to call it `.noChanges`.

`.unknown` is deliberately distinct from the empty verdicts — only those three
are *evidence*, and evidence is what turning a run back requires. An empty verdict
returns the item to `ready` (nothing was attempted, so this is not a verdict on
the work) and records the signal as the reason. Three such items in a row trips a
circuit breaker: restarting the agents did not fix it, so the run pauses and says
so rather than chewing through the backlog. `CoordinatorBlockedTriage` asks the
same module about an already-blocked item, so the two cannot disagree about
whether a run produced anything.

One more gate runs on work that stands: `verifyCoverageGap` asks whether the
item's `verify:` actually exercises what the diff changed, using the project's
optional `kiteloop-verify.json` at its root (`KiteloopCore/Sources/KiteloopCore/Services/VerifyCoverage.swift`). A gap
blocks rather than warns — the work is committed and the branch kept, so nothing
is lost while someone widens the item's `verify:`.

### The judge is advisory

`Services/RunQualityJudge.swift` scores a finished run against the reviewer
rubric as an independent one-shot LLM call — not the reviewer agent, to avoid
self-preference bias. It is **a signal, never a gate**: the score feeds the
metrics and the badge in the run list, and never changes item state. Its
`Judgement` is `.scored` or `.unavailable(reason)`, and the reasons matter:
`disabled` and `cancelled` mean nobody asked, while `noReply`, `unparseable`,
`incomplete` and `notConfigured` mean the judge was asked and failed. Collapsing
those into "no score" once made a healthy night read as a quality collapse.

## Observation flow

Everything the app measures follows one path, and the direction is never
reversed:

```
turn finishes
   │
   ├─ ChatViewModel.recordTurnSpan
   │     stamps: executionID + role (worker/reviewer), the four token counters,
   │     the model, the CLI's reported cost, and a cost derived from the
   │     counters at the rate card in force
   ▼
<project>/.kiteloop/traces/<yyyy-MM-dd>.jsonl        ← turn spans (TraceStore)
<project>/.kiteloop/transcripts/<exec>/<role>.jsonl  ← what was said (RunTranscriptStore)
~/.kiteloop/task-metrics.jsonl                       ← one line per finished run
~/.kiteloop/task-approvals.jsonl                     ← approve / reopen events
   │
   │  incremental ingest, by byte offset
   ▼
~/.kiteloop/metrics.sqlite3
   (MetricIndex: runs · turns · approvals · transcripts · sources)
   │
   ▼
GET /v1/metrics  ·  GET /v1/metrics?aggregate=size|epic|outcome|project|day|model|role|total
Autopilot panel (RunEconomics)  ·  cost caps and forecasts (SizeCalibration)
MetricIndex.noWorkRuns / .runsWithoutAgentOutput / .transcriptRecords
```

**The JSONL logs are the source of truth. The SQLite index is derived and
disposable.** This is the boundary most likely to be violated by someone later,
so `Services/MetricIndex.swift` states the deal and enforces it:

- Nothing is written to the database that did not first land in a log. There is
  no path by which a measurement reaches the index and not the file, because a
  write that must reach two stores to be durable has two ways to be lost.
- A schema change is a `DROP` and a replay, never a migration. `schemaVersion` is
  stamped in the file and a mismatch rebuilds. There is no migration path and
  there is not meant to be one.
- Deleting `metrics.sqlite3` loses nothing. `rebuild()` reconstructs it from the
  logs alone; `replay()` re-ingests from byte zero *without* dropping rows, which
  is the idempotency guarantee — every row is an `INSERT … ON CONFLICT(id) DO
  UPDATE`, keyed on the record's own id, so the same line seen twice rewrites its
  row instead of adding one.
- A source file that *shrank* below what was already indexed was truncated,
  rotated or hand-edited; that is the one case incremental catch-up cannot repair,
  and it triggers a full rebuild.
- Neither refresh nor rebuild holds the history in memory: `JSONLTail` reads
  through a 64 KB window and stops at the last complete line, so a read that
  races an append resumes at the partial line rather than dropping it.

The index exists because reading the logs used to mean loading the whole file
into an array — which is why `GET /v1/metrics` was capped at 200 records and why
answering "what did last night cost per merged item" meant pulling JSON over HTTP
and aggregating it in a script. Aggregates are computed by SQLite now, over the
whole history; `MetricGrouping` is a closed enum precisely because its value is
interpolated into the `GROUP BY`, so the enum *is* the whitelist.

### Transcripts are projected under the same deal

What an agent *said* during a run is indexed from the same JSONL that holds it,
for the same reason the numbers are: on 2026-08-09, "show me every no-work run
this week with its closing message" took hours of reading session files by hand
and five of the diagnoses that came out of it were wrong. It is now one query —
`MetricIndex.noWorkRuns`, which joins each run that left nothing behind to the
last words its worker finished on, and `runsWithoutAgentOutput`, which finds the
ending that has no words to quote because the session died before it said any.

What goes in a row is what is cheap to store and discriminating to filter on: the
record's kind, the execution, the role, the sender, the timestamps, and the *text*
of `text` and `error` records. **Thinking, tool inputs and tool outputs stay in the
log.** They are roughly three quarters of transcript bytes by measurement (see
`RunTranscriptStore`) and nothing filters on them; each row records its line's byte
offset, so reading a payload the index left behind means opening the one line it
came from.

Two consequences worth knowing before querying it:

- **A pruned transcript leaves no rows.** Retention deletes the records after
  seven days, and a deleted file is exactly the shrank-below-what-was-indexed case
  that triggers a rebuild — which reads only what is still on disk. Nothing
  resurrects a pruned record, and no tombstone is indexed either, so ask
  `runsWithoutAgentOutput` over a window inside the retention period: outside it,
  "aged out" and "never written" look identical from the index, and
  `RunTranscriptStore.status` is what tells them apart.
- **Indexing is off the run's path.** A run appends to a file and is done. The
  index catches up when something asks it a question, on its own actor, and a run
  never waits on it.

Three conventions run through all of this and are worth internalising before
adding a field:

- **Nil means "not recorded"; zero means "measured as zero".** `TokenUsage?`,
  `RunTokenUsage`'s optional fields, `TaskMetricRecord.changedFileCount`,
  `SQLiteValue.null` — all of them exist to keep those two facts apart. A record
  reporting 0 tokens claims the run consumed nothing, which is a different
  statement from the app never having seen a counter. `RunEconomics` excludes
  unattributed ($0) runs from every figure rather than averaging them in as free,
  and `SizeCalibration` drops runs that produced nothing rather than training its
  bands on a broken pipeline.
- **Cost is derived, and both figures are kept.** `Models/ModelPricing.swift`
  holds a rate card versioned by effective date (`ModelPriceTable.current`).
  A turn is priced at the card in force *when it ran*, so re-pricing history is a
  deliberate act rather than a silent drift, and the `priceVersion` is recorded so
  it can be re-priced at all. The derived cost sits beside the CLI's reported one
  rather than replacing it: when the two disagree, the disagreement is the
  finding. Models with no per-token dollar rate here — Ollama, the Copilot bridge
  — get no derived cost, because inventing one would be worse.
- **A run's outcome is a snapshot; the item's status is the fact.** `outcome` is
  stamped when a run ends and never revisited, so a run that finished
  `awaiting-approval` wears it after its work is approved and merged. Anything
  asking "did this spend buy something" asks the backlog instead —
  `BacklogFile.statusByItemID`, joined in `RunEconomics` — and asks it fresh each
  time the figure is drawn. Computing it from the frozen outcome had the Autopilot
  panel reporting 34% of a day's spend as waste when about 1% was real, because
  every delivered item whose run ended at the approval gate stayed in the
  numerator for good.

## The control API

`Services/Control/` is a loopback HTTP server that lets a script or another
Claude Code session drive the app: open a project, configure autopilot, run a
backlog item, watch it, approve it. It is **off by default** (Settings → General
→ Local Control API, persisted as `controlServerEnabled` / `controlServerPort` in
`~/.kiteloop/global-config.json`).

- **Loopback is forced in the transport, not by convention.** `HTTPServer` sets
  `requiredLocalEndpoint` to `127.0.0.1`, so the API cannot be exposed off-device
  by misconfiguration.
- **One bearer token**, at `~/.kiteloop/control-token` (mode 0600, created on
  first use, rotatable from Settings — the new value replaces the running
  server's in memory, so no restart is involved), compared as an exact full
  string. `GET /health` is the only
  unauthenticated route; an unmatched path 401s rather than 404ing, so an
  anonymous caller cannot map out which routes exist.
- **`ControlRouter.table` is the single place an endpoint is declared.** Matching
  is a pure function of method and path, testable without binding a port or
  opening a project. `ControlRoute` carries the auth policy. The OpenAPI 3.1
  document at `GET /v1/openapi.json` is *generated* by walking
  `ControlRouter.endpoints` (`ControlAPISpec`), so paths, methods and auth
  requirements cannot drift from the router — they *are* the router. Request and
  response schemas are the one hand-maintained part, and `detail(for:)` is
  exhaustive over `ControlRoute`, so a new endpoint fails to compile until it is
  described.
- **The server reaches app state through `ControlSessionRegistry`**, keyed by
  canonical project path, rather than into SwiftUI view state. `MainWindow`
  registers a project's session and autopilot when it opens and drops it on close.

Adding an endpoint means touching the router table, the dispatch arm and handler
in `KiteloopControlServer`, `ControlRouterTests`, a server test, and
[`control-api.md`](control-api.md) — the checklist is in `CLAUDE.md`.

Two limits that shape how a driver has to be written: `runId` **is** the workflow
execution id, and run records are in-memory, so an app restart turns a known
`runId` into a 404. And a project must already be open in the app before its
items can be run.

## What lives where, and why

### `Kiteloop/KiteloopCore/`: the host-less core

`Kiteloop/KiteloopCore/` is a local Swift package the app target depends on
(`SWIFT_PACKAGE_NAME = kiteloopcore` in
`Kiteloop.xcodeproj/project.pbxproj`); its types carry `package` access rather
than the app's `internal`. Its test target needs no test host, so it runs
under a plain `swift test` process — `scripts/run-core-tests.sh` — instead of
inside `Kiteloop.app` the way `Kiteloop/KiteloopTests/` does. That is the whole
reason the package's tests, and only the package's tests, are safe to run
while Kiteloop is up, and the one `verify:` an autopilot item can rely on to
run real tests without killing the app it is running in.

A file moves into the package once every type it references is already
there — not before, since a reference still pointing at the app would need
`Kiteloop.app` to resolve. `quality/bin/check-layering.py` judges all three
roots: `layering.roots` in `quality.json` carries `Kiteloop/Kiteloop`,
`Kiteloop/KiteloopCore/Sources/KiteloopCore`, and `KiteloopMobile/Sources`,
each with its own exempt list, so a reference cannot leave the layering
ratchet behind just by moving files from one tree to another.

| Location | Holds | Nature |
|---|---|---|
| `<project>/BACKLOG.md`, `backlog/<id>.md` | items and their groomed detail | intent — Markdown, hand-editable |
| `<project>/.kiteloop/` | team, per-project config, events, traces, worktrees | project state, human-readable |
| `~/.kiteloop/` | global config, control token, metric logs, the SQLite index, autopilot history | app state, per-machine |
| `~/.kiteloop/home/` | the default project for managers | a project like any other |

The backlog is looked up in one order: a `BACKLOG.md` in the project root wins,
because it is self-contained, travels with the repo and needs no configuration.
Failing that, an optional shared vault of backlogs (Settings → General;
[backlog-format.md](backlog-format.md#where-the-file-lives)) is searched for
`Projects/<name>/Backlog.md` matching the repo. Detail files live in a
`backlog/` directory beside whichever file was found.

External edits are picked up while the app runs.
`KiteloopCore/Sources/KiteloopCore/Services/BacklogFileWatcher.swift` uses
**two** dispatch sources for one file, because one is not enough: the
file source (`O_EVTONLY`) sees in-place writes, but a write-to-temp-and-rename —
what most editors do, and what every `write(…, atomically: true)` does — unlinks
the inode the descriptor names, and the descriptor goes deaf. A directory source
survives that; directory events are then filtered on the backlog file's own
identity (inode, size, mtime) so sibling churn does not wake the app.

### Why intent stays in Markdown while observations went to a database

They are asked different questions, so they get different stores.

Intent is small, edited by hand, reviewed in a diff, and travels with the repo.
It has to be readable and writable by a person and by an agent with nothing but
`Read` and `Edit` — a database would put a tool between the human and their own
backlog, and there is no query worth that. The whole point of `.kiteloop/` being
plain files is that when an agent does something wrong you can open what it read.

Observations are append-only, large, and asked aggregate questions — per size,
per day, per role, over months. That is what the index is for, and it is exactly
why the index is *derived*: the property that makes JSONL good for the intent
side (a human can read and repair it) is the same property that makes it a bad
place to answer a `GROUP BY`, and the resolution is to keep the log authoritative
and let the database be rebuildable rather than to promote the database.

The test for whether a future change respects this: **can you delete
`~/.kiteloop/metrics.sqlite3` and lose nothing?** Today, yes. If that ever stops
being true, the boundary has been crossed.
