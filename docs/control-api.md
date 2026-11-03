# Control API

Reference for Kiteloop's **local control API** — a loopback HTTP server that lets an
external tool (a Claude Code session, a shell script, a long-run harness such as
`scripts/kiteloop-verify.py`) open a
project, wire up autopilot, start a backlog item, monitor it, and approve the
result without touching the UI. (Diátaxis: this is *reference*. For the operational
walkthrough see [`autopilot-runbook.md`](autopilot-runbook.md); for the execution
model see [ADR-0001](adr/0001-autonomous-run-model.md); for *why* the control
surface is an embedded loopback HTTP server see
[ADR-0002](adr/0002-embedded-localhost-control-server.md).)

Implementation: `Kiteloop/Services/Control/` —
`KiteloopControlServer.swift` (handlers), `ControlRouter.swift` (the routing
table), `HTTPServer.swift` (transport), `ControlSessionRegistry.swift`
(open-project directory), `ControlAPISpec.swift` (the OpenAPI document served at
[`GET /v1/openapi.json`](#get-v1openapijson)).

## Enabling the server

Off by default. **Settings → General → Local Control API** → *Enable control
server*, optionally changing the port. The toggle takes effect immediately (no
restart) and is persisted in `~/.kiteloop/global-config.json` as
`controlServerEnabled` / `controlServerPort`. On app launch the server starts
automatically if it was left enabled.

| | |
|---|---|
| Default port | `4517` |
| Valid ports | `1024`–`65535`. The Settings field keeps the last saved port while the value you type is outside that range; a persisted port outside it falls back to `4517` at launch |
| Bind address | `127.0.0.1` only — the listener sets `requiredLocalEndpoint`, so it is never reachable off-device |
| Base URL | `http://127.0.0.1:4517` |
| Version prefix | `/v1` (only `/health` sits outside it) |

## Authentication

Every route except `GET /health` and [`POST /v1/pair`](#post-v1pair) — where a
pairing QR's one-time code stands in for it — requires a bearer token:

```
Authorization: Bearer <token>
```

There are **two** shared tokens, and a token per paired phone, all accepted on
the same header, differing only in what they authorize:

| Token | File | Authorized for |
|---|---|---|
| **Control token** | `~/.kiteloop/control-token` | The whole API. This is the operator's own credential. |
| **Operator token** | `~/.kiteloop/operator-token` | The whole API **except** the endpoints that resolve a human gate: [`POST /v1/backlog/approve`](#post-v1backlogapprove), [`POST /v1/runs/{runId}/approve`](#post-v1runsrunidapprove) and [`POST /v1/backlog/land`](#post-v1backlogland), the merge half of an approval taken later. All three answer **403** for this token. |
| **Phone token** | `~/.kiteloop/control-devices.json` (its SHA-256 only) | The whole API, as the control token. Minted for that one phone when it claims the one-time code **Pair a phone** shows ([`POST /v1/pair`](#post-v1pair)); revoked alone under **Settings → Control API → Paired phones**, leaving the other phones and the control token working. |

Both are minted the same way, at first use, `0600`: `cat ~/.kiteloop/control-token`
/ `cat ~/.kiteloop/operator-token`. The Settings pane shows the control token's
path when the server is enabled, next to the **Regenerate...** button that
replaces it; the operator token has no Settings UI and is not rotatable from the
app — replacing the file on disk is enough, since it is simply re-read.

Every request leaves one line in `~/.kiteloop/logs/control-access.log`
(`0600`): time, method, path without its query string, which credential —
`control`, `operator`, a paired phone by name, or `none` — the status, and
how long it took. Never a body, a query or a token. It rotates at 2 MB, keeping
one older file as `control-access.log.1`, so what was driven from a phone can
be read back afterwards.

**The operator token is how a chat agent gets to do what the operator's own
terminal session does** — tweak a config, start a run, read the fleet's state —
without holding the one credential that can approve its own team's work. It is
granted **per agent, off by default**: turn on **Operator Tools** in an agent's
settings, and only that agent's spawned CLI gets `KITELOOP_OPERATOR_TOKEN` and
`KITELOOP_CONTROL_URL` in its environment, plus a bundled knowledge note on how
to use them (read-first endpoints, the scope it does and doesn't have). An
agent without the grant carries neither variable. The file itself is minted the
moment the app builds its `KiteloopControlServer` (at launch, whether or not the
server is switched on) — the same way the control token is — so granting the
toggle to an agent does not by itself create or reveal the credential; it only
decides whether that agent's environment carries it.

Details that matter when scripting:

- The comparison is exact and full-string, against **either** token — a truncated
  token, a bare token with no `Bearer ` prefix, or a different scheme (`Token …`)
  all get **401**.
- Auth is checked **before** routing, so an unknown `/v1/...` path returns 401 (not
  404) when unauthenticated — the route table isn't discoverable without a token.
- 401 body: `{"error": "Missing or invalid bearer token"}`.
- 403 body for the operator token on an approve endpoint:
  `{"error": "the human gate takes the operator's own token (scope: approve)"}`.
- **Rotation is a Settings action, not an endpoint** — a credential is not rotated
  over the channel it authenticates. **Settings → General → Local Control API →
  Regenerate...** (available while the server is enabled) confirms first, then
  mints a new **control** token, rewrites the file — still `0600` — and swaps it
  into the running server. The old token starts returning **401** immediately and
  the new one works with no restart, so every client holding the old one,
  including a queue driver mid-run, has to re-read the file. This does not touch
  the operator token.

## Conventions

- **Request bodies** are JSON. `Content-Type` is not enforced, but the body must
  parse as a JSON object or the endpoint returns 400.
- **Boolean fields take `true` or `false` only.** `1` and `0` are **400**
  `"<field>" must be true or false`, as is any other type. A client that
  serialises booleans as numbers would otherwise clear an autonomous hold or
  approve an item it meant to reject; a rejected body changes nothing, so the
  fix is to resend it with real booleans.
- **Responses** are JSON (`application/json; charset=utf-8`), pretty-printed with
  sorted keys. Errors are always `{"error": "<message>"}`.
- **`project` identifier** — anywhere a `project` value is accepted you may pass the
  canonical project path, the raw path as typed, or just the project's folder name
  (e.g. `kiteloop`). Resolution is: canonical path → raw path → trailing folder
  name.
- **The project must already be open in the app** for anything except `/health`,
  `GET /v1/projects`, and `POST /v1/projects/open`. Otherwise: **409**
  `Project not open in Kiteloop: <key>`.
- **Connections are unary** — no keep-alive; each response closes the connection.
  The one exception is the SSE endpoint, which is held open.
- **Request size cap** is 2 MB; larger requests get **413**.
- **`runId`** is the workflow execution ID — except for a run the Planner's
  scheduler started itself, whose id is minted as `auto-<uuid>` before a workflow exists
  to be named after — for those, `executionId` reports the workflow it turned out
  to be, and is what its transcripts and its metric record are keyed by (see
  [Joining a run to its transcript](#joining-a-run-to-its-transcript)). Either way
  the `runId` keeps answering after an app restart: every run
  is written to `~/.kiteloop/control-runs.jsonl` and read back at launch as a
  **historical** record. See [Runs across a restart](#runs-across-a-restart).

Status codes used: 200, 201, 202, 400, 401, 403, 404, 409, 413, 422, 500, 503.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness probe — version, uptime, active-run count, and measured health (main-thread latency, memory, subprocesses) (no auth) |
| GET | `/v1/openapi.json` | This API as an OpenAPI 3.1 document, generated from the routing table |
| GET | `/v1/projects` | List open projects, what each one's autopilot is running and how deep its queue is |
| POST | `/v1/projects/open` | Open a project in the app |
| POST | `/v1/projects/reorder` | Move an open project's tab before another, or to the end — the order `GET /v1/projects` lists |
| POST | `/v1/projects/ask` | Ask the Planner about one project's **source**, read-only — costs a model call |
| GET | `/v1/backlog?project=` | List backlog items and statuses |
| GET | `/v1/metrics` | Recent measured run records (duration, cost, quality, opening context) + the escaped-defect rate |
| GET | `/v1/estimates` | Latest pre-run estimate for each scoped item |
| GET | `/v1/grooming` | Recent grooming records — items filed, and items a pre-run check refused |
| GET | `/v1/report` | The portfolio report for a window — merged ÷ filed per project, rejection causes, spend |
| GET | `/v1/autopilot?project=` | Read the project's autopilot configuration and run state |
| PUT | `/v1/autopilot` | Configure worker/reviewer and autopilot settings |
| POST | `/v1/autopilot/reset` | Reset the budget and behaviour flags to their defaults |
| POST | `/v1/autopilot/pause` | Hold the queue after the item in flight, and refuse new runs for this project |
| POST | `/v1/autopilot/resume` | Pick a paused queue back up |
| GET | `/v1/fleet/quiesce` | Is the fleet holding, and has the last run finished? |
| POST | `/v1/fleet/quiesce` | Stop the whole fleet taking new work, and wait for it to drain |
| POST | `/v1/fleet/resume` | Lift the hold and pick the held queues back up |
| GET | `/v1/usage` | How close the agents are to their rate limit, and the last day's spend per project |
| GET | `/v1/memory/proposals?project=` | List a project's pending memory proposals |
| POST | `/v1/memory/proposals/approve` | Approve one — applies it to the agent's memory |
| POST | `/v1/memory/proposals/reject` | Reject one — takes it off the list, writes nothing |
| GET | `/v1/agents?project=` | List a project's agents — id, name, model, state |
| POST | `/v1/agents` | Hire (summon) an agent into a project |
| POST | `/v1/agents/message` | Send a message to an agent — answers once it is in; `wait` holds for the reply |
| GET | `/v1/agents/transcript?project=&agent=` | The agent's recent chat transcript, oldest first |
| GET | `/v1/agents/events?project=&agent=` | An agent's chat as it happens (SSE) — the phone's live chat |
| POST | `/v1/agents/interrupt` | Stop an agent's running turn, as the Mac's Stop button does |
| POST | `/v1/agents/plan` | Answer a Plan-mode agent's plan card: build in a mode, or keep planning |
| POST | `/v1/agents/answer` | Answer the question an agent stopped to ask |
| POST | `/v1/pair` | Trade the pairing QR's one-time code for a phone's own token (no auth) |
| GET | `/v1/quick-replies` | The one-tap replies the phone offers above its chat composer |
| POST | `/v1/devices/push` | Register a phone's push token, so the Mac can tell it when something happens |
| POST | `/v1/devices/activity` | Register the Live Activity a phone started for an agent's turn |
| GET | `/v1/workspace/changes?project=` | The project's uncommitted changes — what an agent has done before any gate |
| GET | `/v1/workspace/file?project=&path=` | One file or folder of the project, read-only; git-ignored files refused |
| GET | `/v1/preview/screenshot?project=` | The Mac's web preview for the project, as a PNG |
| GET | `/v1/backlog/detail?project=&item=` | One item, drilled into: line fields plus the groomed detail |
| GET | `/v1/backlog/diff?project=&item=` | The item's unmerged branch as a reviewable diff — what approving merges |
| POST | `/v1/backlog/approve` | Approve/reject an item at its human gate |
| POST | `/v1/backlog/land` | Merge a done item's branch that never landed |
| POST | `/v1/backlog/groom` | Promote a groomed draft to `ready`, send one back to `draft`, or lift a `blocked` item to either |
| POST | `/v1/backlog/move` | Reorder an item — in front of another, or to the top of its epic; position is the queue's priority |
| POST | `/v1/backlog/lane` | Put an item in the `now` or `later` lane without moving it in the file |
| POST | `/v1/backlog/release` | Let an item the retry ceiling retired be picked up again |
| POST | `/v1/backlog/refresh` | Rebase a stale item at the approval gate by hand |
| GET | `/v1/backlog/templates?project=` | List the project's backlog templates and the variables each one takes |
| POST | `/v1/backlog/templates/stamp` | Stamp a template into items — previews by default, files with `apply` |
| POST | `/v1/backlog/items` | File one new item as a draft — the phone's Add, groomed on request |
| GET | `/v1/coordinator/proposals` | Retired with advisory mode — answers 410 |
| POST | `/v1/coordinator/proposals/approve` | Retired with advisory mode — answers 410 |
| POST | `/v1/coordinator/proposals/dismiss` | Retired with advisory mode — answers 410 |
| GET | `/v1/coordinator/refill` | Read the queue-refill loop: switch, cadence, budget, recent passes |
| PUT | `/v1/coordinator/refill` | Switch the queue-refill loop on; set its ceilings and cadence |
| GET | `/v1/coordinator/scheduling` | Read the autonomous run scheduler: switch, holds, budget, recent starts |
| PUT | `/v1/coordinator/scheduling` | Switch autonomous run starts on/off; set the portfolio's daily budget; clear every autonomous hold |
| POST | `/v1/runs` | Start a backlog item |
| GET | `/v1/runs` | List tracked runs, and what each is costing |
| GET | `/v1/runs/{runId}` | Poll run status |
| GET | `/v1/runs/{runId}/result` | Read the run's outcome and what it cost |
| GET | `/v1/runs/{runId}/events` | Live event stream (SSE) |
| GET | `/v1/runs/{runId}/log` | Read the autopilot's log lines for this run |
| POST | `/v1/runs/{runId}/approve` | Resolve this run's pending gate |
| POST | `/v1/runs/{runId}/cancel` | Abandon a run that is still in flight |
| POST | `/v1/runs/{runId}/note` | Hand this run's worker a steering note |

Throughout the examples:

```bash
TOKEN=$(cat ~/.kiteloop/control-token)
H="Authorization: Bearer $TOKEN"
B="http://127.0.0.1:4517/v1"
```

---

### GET /health

Unauthenticated liveness probe — use it to check whether the app is up, the
control server is enabled, and whether the app is actually keeping up rather
than merely reachable.

```bash
curl -s http://127.0.0.1:4517/health
```

```json
{
  "status": "ok",
  "version": "0.1.0",
  "apiVersion": 1,
  "uptimeSeconds": 8412,
  "projectsOpen": 2,
  "activeRuns": 1,
  "mainThreadLatencyMs": 4.2,
  "hitchCount": 0,
  "processMemoryMB": 312.5,
  "activeSubprocessCount": 3,
  "holds": [],
  "tools": [
    { "project": "kiteloop", "path": "/Users/me/code/kiteloop",
      "tools": [
        { "name": "cargo", "path": "/Users/me/.cargo/bin/cargo" },
        { "name": "lizard", "path": null,
          "searched": ["/usr/bin", "/bin", "/opt/homebrew/bin", "/Users/me/.local/bin"] }
      ],
      "exports": [
        { "name": "CARGO_TARGET_DIR", "value": "/Users/me/code/kiteloop/.kiteloop/build/cargo" }
      ] }
  ]
}
```

| Field | Meaning |
|---|---|
| `status` | `"degraded"` when `mainThreadLatencyMs` is at or above the app's hitch threshold (200ms); `"ok"` below it |
| `version` | The app's `CFBundleShortVersionString` (`"dev"` in unbundled builds) |
| `apiVersion` | The control API's version, a whole number. Raised whenever an endpoint the phone calls is added or changes shape — the change that adds or edits a row in `KiteloopMobile/README.md`'s list — so the phone can say the Mac needs updating (a lower number, or none from a Mac older than the field) or that the phone does (a higher one), instead of failing on a 404. Unlike `version`, it says nothing about the app's release |
| `uptimeSeconds` | Whole seconds since the app launched |
| `projectsOpen` | Projects currently open in the app |
| `activeRuns` | Tracked runs in flight — `running` or `awaiting_approval` |
| `mainThreadLatencyMs` | The latest main-thread latency probe, in milliseconds — what `status` is derived from |
| `hitchCount` | Main-thread hitches recorded since launch, capped at the monitor's retained window |
| `processMemoryMB` | Resident memory, in MB; `null` when the kernel refused the reading |
| `activeSubprocessCount` | Live Claude Code subprocesses |
| `holds` | Projects whose **autonomous** starts are being withheld by their own failed runs. Empty is the healthy state |
| `tools` | Per open project, every executable its verify commands run and where the app's search path resolved it — or `null` with the directories searched — and, as `exports`, the variables every verify and agent spawn on the project's behalf runs with beyond `PATH` |

Each entry in `holds` carries `project`, `path`, a `reason` naming the failures
and what would end the hold, the `failures` still standing as evidence, the
`items` distinct among them, and `systemic` — whether it is the same-cause kind:

```json
{"holds": [{"project": "kiteloop", "path": "/Users/me/code/kiteloop",
            "reason": "3 autonomous runs in kiteloop failed (last: summary-line blocked: verify failed) — held until its queue changes",
            "failures": 3, "items": 1, "systemic": false}]}
```

`tools` answers **which tools can this app reach for this project, and where?**
before a run is refused for one. Each entry names a project and carries one
row per distinct executable — lifted out of every item's `verify:` (the groomed
detail's, or the item line's) and the verify map's commands, sorted by name —
with `path` the absolute path it resolved to, or `null` beside `searched`, the
directories the app looked in. The search path is the app's one policy
(`ExecutableSearchPath`): the login shell's `PATH`, the fixed toolchain homes
(Homebrew, `/usr/local/bin`, `~/.local/bin`, `~/.npm/bin`, `~/.cargo/bin`),
then `extraExecutablePaths` from `~/.kiteloop/global-config.json` and from the
project's `.kiteloop/config.json`. The Diagnostics window's Health tab shows
the same rows. See `docs/autopilot-runbook.md` → "Tools the app must reach".

Each project entry also carries `exports`: `{name, value}` rows, sorted by
name, for the variables every verify shell and agent spawn on the project's
behalf runs with beyond `PATH` (`BuildEnvironment`) — build output shared
across the project's item worktrees, so a Rust item does not pay a cold
`cargo build` in every worktree. Derived from the tree (`Cargo.toml` →
`CARGO_TARGET_DIR=<root>/.kiteloop/build/cargo`, `package.json` →
`npm_config_cache=<root>/.kiteloop/build/npm`) and from the project's
`buildEnvironment` map in `.kiteloop/config.json`, whose entries win; `~` and
`$PROJECT_ROOT` in a value are already expanded here. Empty when the project
declares nothing and no marker is present. See `docs/worktree-isolation.md` →
"Shared build output".

An ordinary hold ends on its own when the project's queue changes — an item
re-groomed, a new one filed, a dependency reaching `done`, the retry ceiling
retiring the failing item. A `systemic` one (two *different* items failing with
the same text) waits on something outside those runs instead: the autopilot or
global config being edited, an app relaunch, or `resetBreaker` on
[`PUT /v1/coordinator/scheduling`](#put-v1coordinatorscheduling). Nothing here is
fleet-wide: a hold withholds starts in its own project only.

`uptimeSeconds` is how a long-lived driver detects a restart: an uptime that went
*down* means nothing it was watching is still running. The `runId`s it holds keep
answering — as historical records, and as `interrupted` for whatever was in
flight (see [Runs across a restart](#runs-across-a-restart)).

`activeRuns` counts what `GET /v1/runs` reports as `running` or
`awaiting_approval`. Runs whose project has since been closed read `unknown`
there and are not counted here — nothing is driving them any more.

---

### GET /v1/openapi.json

The machine-readable counterpart to this page: the control API as an **OpenAPI
3.1** document, for generating a client or diffing what a build actually serves.

```bash
curl -s -H "$H" $B/openapi.json | jq '.info.version, (.paths | keys | length)'
curl -s -H "$H" $B/openapi.json > kiteloop-control.openapi.json   # if you want a file
```

**There is no spec file in the repository.** It is generated on request by
`KiteloopCore/Sources/KiteloopCore/Services/Control/ControlAPISpec.swift`, and a checked-in copy would be
one more thing to keep in step — which is the problem this endpoint exists to
solve. Save the response if a build step needs a file.

**How it is produced.** Paths, methods and auth requirements are *derived* from
`ControlRouter.table` — the same list the server routes on — by walking
`ControlRouter.endpoints`. So there is no second list of endpoints to fall out of
date: an endpoint the app answers is an endpoint the document describes.

Everything the table doesn't carry — summaries, query parameters, request bodies,
status codes, response schemas — comes from a `switch` over `ControlRoute` in
`ControlAPISpec.detail(for:)`. That switch is exhaustive, so **adding a route
fails to compile until it is described**. `ControlAPISpecTests` covers the rest:
that every routed endpoint reaches the document and nothing else does, that
`/health` is the only operation marked as needing no auth, that every `$ref`
resolves, and that `operationId`s are unique.

**What it does and doesn't promise:**

- `info.version` is the running app's version, and `servers[0].url` carries the
  port this server is actually bound to — so the document you fetched describes
  the app you fetched it from.
- Every endpoint appears with its real method, path and auth requirement.
- Request and response schemas are maintained **by hand against the handlers**.
  Where a response body varies with run state (`GET /v1/runs/{runId}` gains
  `currentNode` only while the execution exists), only the keys the handler emits
  unconditionally are `required`; the conditional ones are present but optional.
- Not modelled: **413** (body over 2 MB) and **500**, which the transport can
  return for any route; and that a `project` value may be a canonical path, a raw
  path or a bare folder name — the schema says `string`, and the rules are in
  [Conventions](#conventions) above.

**Status:** 200 · 401.

---

### GET /v1/projects

Lists the projects currently open in the app, what each one's autopilot is doing
right now, and what each one has left to do — so "what is every project up to?"
is one call rather than one `GET /v1/autopilot` and one `GET /v1/backlog` per
project.

Projects come back in the app window's tab order — the order a person sees on
the Mac, and the one `POST /v1/projects/reorder` moves — so a phone showing
them in a row shows the same row.

```bash
curl -s -H "$H" $B/projects
```

```json
{
  "projects": [
    {
      "id": "/Users/me/code/kiteloop",
      "name": "kiteloop",
      "path": "/Users/me/code/kiteloop",
      "autopilotReady": true,
      "baseBranch": "main",
      "unattendedPermissions": "auto",
      "paused": false,
      "run": {
        "state": "running",
        "running": true,
        "item": "flaky-verify-command",
        "itemTitle": "Verify command is flaky under load",
        "runId": "exec-9F31…",
        "startedAt": "2026-08-09T11:04:22Z",
        "status": "running",
        "heldItems": 2,
        "detail": null,
        "phaseRail": {
          "currentStep": "review",
          "stepsDone": ["worker", "verify"],
          "attempt": 2,
          "lastOutputAgeSeconds": 40.2,
          "warnAtSeconds": 600
        }
      },
      "queue": {
        "ready": 7,
        "runnable": 4,
        "draft": 12,
        "active": 1,
        "inReview": 1,
        "awaitingApproval": 2,
        "refusedAtGate": 1,
        "blocked": 3
      },
      "hold": null
    }
  ]
}
```

`autopilotReady` is true only when **both** a worker and a reviewer agent are
assigned for that project. `run` is the same block
[`GET /v1/autopilot`](#get-v1autopilot) returns, from the same derivation — see
[Run state](#run-state) for what each field means.

`unattendedPermissions` is how an unattended run is permitted, and today it is
always `auto`: a run's worker and reviewer are spawned in Claude Code's auto
mode, whose classifier decides each tool call, with prompts off so anything that
would ask is refused. Only the agents' own denied tools are added; Kiteloop keeps
no deny list of its own. The boundaries a run answers to beyond the classifier
are the worktree, the gate and a person. A chat agent runs in its own mode, also
with prompts off — nothing in Kiteloop answers a prompt.

`baseBranch` is the branch this project's runs fork from and land on,
**resolved**: the project's `baseBranch` setting when it has one, otherwise the
branch the checkout is on right now — which is what an unset `baseBranch` means.
`null` when neither answers (the root is not a git repository, or its `HEAD` is
detached). [`GET /v1/autopilot`](#get-v1autopilot) reports the setting as
written; this is where to read what a run would actually use, so "run on
`quality/rebased`" is a `PUT` on the one project that owns the checkout rather
than a second registration of the same directory.

`paused` is true for either cause of the one hard stop: a human parked the
project with the paused switch on the fleet board, or its own autopilot is
holding the queue ([`POST /v1/autopilot/pause`](#post-v1autopilotpause)). Either way,
[`POST /v1/runs`](#post-v1runs) answers 409 for this project and
[`POST /v1/autopilot/resume`](#post-v1autopilotresume) lifts the hold.

`queue` is how much work the project has left, by status:

| Field | Type | Notes |
|---|---|---|
| `ready` | integer | Items at `ready`, groomed or not |
| `runnable` | integer | Of those, the ones the Definition-of-Ready gate would actually let autopilot pick up |
| `draft` | integer | Items at `draft` — filed, not yet triaged |
| `active` | integer | Items at `active` — in flight |
| `inReview` | integer | Items at `in-review` — the reviewer is judging them |
| `awaitingApproval` | integer | Items parked at the human gate |
| `refusedAtGate` | integer | Of those, the items whose merge gate already ran and refused (per-item `gate.state` of `refused`) — waiting on a fix, not a decision |
| `blocked` | integer | Items at `blocked` — stuck, waiting on triage |

`runnable` is the one that decides anything. `ready` counts items somebody
*called* ready; the gap between the two is the ungroomed work autopilot would
skip, so `"ready": 7, "runnable": 0` is a full queue nobody can run and reads
nothing like a drained one. It is the same verdict
[`GET /v1/backlog`](#get-v1backlog) reports as `"ready": true` per item, off the
same `DefinitionOfReady` gate — the two are counted from one derivation, so they
cannot disagree.

`inReview` and `blocked` are why work that is in flight or stuck no longer reads
as work that is finished: a project with one item under review and fourteen
blocked used to answer with every count at 0, byte-for-byte what a drained
project answers.

Every field of `queue` is always present. A project with no backlog, or one the
parser could make nothing of, reports zeros rather than omitting the block, so
"the queue is empty" is never read off a build too old to count.

`hold` is the project's own evidence-driven hold, or `null` while nothing is
withholding it — the same reading `/health`'s `holds` and
[`GET /v1/coordinator/scheduling`](#get-v1coordinatorscheduling)'s
`lastDecision` give any other hold. Today it carries exactly one kind:
`gateFull`, raised when `queue.awaitingApproval` holds more than the Planner's
own ready floor (`QueueRefill.Policy`'s `targetDepth`, 3 by default) **and**
the project's own autopilot won't clear the gate itself
(`approveReviewPassedRuns` off — [`PUT /v1/autopilot`](#put-v1autopilot)). A
project on that rung clears its own gate and is never held this way. The
`reason` carries both numbers, so a driver can act on it without a second
call:

```json
"hold": {
  "kind": "gateFull",
  "reason": "kiteloop: gate holds 37, more than 3 kept ready — approve or send back to resume"
}
```

The hold is a live reading, not a latch: it exists exactly while
`queue.awaitingApproval` is over the floor, and is gone the moment an approval
or a send-back drains it under.

To find the projects that are busy, or the ones that only think they are:

```bash
curl -s -H "$H" $B/projects | jq -r '.projects[] | "\(.name)\t\(.run.state)\t\(.run.item // "-")"'
```

To find the ones that have run dry, and the ones only *look* like they have:

```bash
curl -s -H "$H" $B/projects |
  jq -r '.projects[] | select(.queue.runnable == 0) |
         "\(.name)\trunnable 0\tready \(.queue.ready)\tdraft \(.queue.draft)\tgate \(.queue.awaitingApproval)"'
```

**Status:** 200 · 401.

---

### POST /v1/projects/open

Opens a project in the app window and registers it, so the rest of the API can
address it. Idempotent — opening an already-open project returns its entry, and
**re-reads its backlog from disk**.

| Field | Type | Required | Notes |
|---|---|---|---|
| `path` | string | yes | Absolute path; `~` is expanded |

```bash
curl -s -H "$H" -d '{"path":"~/code/kiteloop"}' $B/projects/open
```

```json
{ "id": "/Users/me/code/kiteloop", "name": "kiteloop", "autopilotReady": false,
  "alreadyOpen": false, "reloaded": false }
```

`alreadyOpen`/`reloaded` say which of the two happened: **201** with both false
means a session was booted, **200** with both true means the project was already
open and its backlog was re-read instead. Nothing was created in that case, and
the status code says so — a driver that groomed the backlog outside the app has
no other way to tell whether the app went back to the file.

The app also watches the backlog file and picks up external edits on its own
(including a write-to-temp + rename, which is how most editors save), so this
call is a way to force the read, not the only way to get one.

**Status:** 201 (opened) · 200 (already open, reloaded) · 400
(missing/unparseable `path`, or no project could be opened there) · 401 · 503
(the app window isn't running, so there is nothing to open the project into).

---

### POST /v1/projects/reorder

Moves one open project's tab before another, or to the end. It is the same move
a tab drop makes in the app window, through the window's own code path, so a
phone dragging its row of projects and a person dragging tabs on the Mac share
one saved order — and `GET /v1/projects` lists projects in that order.

| Field | Type | Required | Notes |
|---|---|---|---|
| `project` | string | yes | The project to move — name or path |
| `before` | string | no | The project to place it in front of — name or path. Omit or `null` for the end |

```bash
curl -s -H "$H" -d '{"project":"travel","before":"kiteloop"}' $B/projects/reorder
```

```json
{ "projects": ["website", "kiteloop", "inventory"] }
```

The answer is the new order, as names — the same order the next
`GET /v1/projects` walks.

**Status:** 200 · 400 (no `project` in the body) · 401 · 409 (`project` or
`before` names no open project) · 503 (the app window isn't running, so there is
no tab order to move).

---

### POST /v1/projects/ask

Asks the Planner a question about a named project's **source**, read-only.

**This is the expensive one.** Every other read on this API answers from state
the app already holds and costs nothing: `GET /v1/backlog` for the queue,
`GET /v1/runs` for what happened, `GET /v1/report` for the rollup. Reach for
those first. This endpoint spends a model call with tools, so expect a
materially higher per-call cost, and use it for what the backlog genuinely
cannot answer — "is that file still there", "does this symbol exist", "what does
this test actually assert".

| Field | Type | Required | Notes |
|---|---|---|---|
| `project` | string | yes | Project identifier — canonical path, raw path or folder name |
| `question` | string | yes | What to find out. Must not be empty. `q` is accepted as an alias |

```bash
curl -s -H "$H" -d '{"project":"kiteloop","question":"does GroundingCheck still refuse a relative path?"}' \
  $B/projects/ask
```

```json
{ "project": "kiteloop",
  "answer": "Yes — KiteloopCore/Sources/KiteloopCore/Services/GroundingCheck.swift …",
  "capped": false,
  "costUSD": 0.42 }
```

What the reading agent may do, and only this:

- **One project, named explicitly.** The name is resolved against the open
  projects by their own name or path and nothing else — no prefix match, no
  nearest neighbour. A name that matched nothing answers **404** listing the
  open ones rather than reading whichever project was closest. The session is
  rooted at the resolved project, so another project's files are not in scope.
- **`Glob`, `Grep`, `Read`, and nothing else.** It cannot write a file, run a
  command, or reach the network — every other tool the CLI offers is refused by
  name. Applying anything it concludes stays a separate, deliberate call to this
  API.
- **Charged to the portfolio's daily ceiling**, the same pool grooming draws on
  (`dailyBudgetUSD`, `PUT /v1/coordinator/scheduling`). A spent ceiling answers
  **429** and reads nothing at all. The grooming switch does not gate this: a
  question is not a pass, so `enabled: false` still answers, and a read starts no
  pass and blocks none.
- **Bounded.** The answer is capped, and a capped one says so — `capped` is true
  *and* the notice is appended to `answer` itself, so a driver that prints only
  `answer` still learns it was cut. Ask something narrower to see the rest.
- **It says when it has not looked.** Asked about something it did not read, it
  says so rather than answering from the backlog. Treat "I haven't looked at
  that" as the answer it is.

**Status:** 200 · 400 (missing `project`, or `question` absent or empty) · 401 ·
404 (no open project by that name — the open ones are in the message) · 429 (the
daily ceiling is spent; nothing was read) · 502 (the read happened and came back
empty) · 503 (no Planner attached to this window to do the reading).

---

### GET /v1/backlog

Flattens every epic section of the project's backlog file into one item list,
reports the lines the parser could not read as `issues`, and sweeps for work the
ledger has lost track of — `done` items on an unmerged branch or left
unreferenced by a branch that was deleted, plus a worktree still on disk holding
uncommitted changes nothing is coming back for — as `strandedWork`.

| Query | Required | Notes |
|---|---|---|
| `project` | yes | Path or folder name |

```bash
curl -s -H "$H" "$B/backlog?project=kiteloop"
```

```json
{
  "project": "kiteloop",
  "items": [
    { "id": "docs-control-api", "title": "Document the control API",
      "epic": "Docs", "status": "ready", "size": "M", "ready": true,
      "noWorkAttempts": 0 },
    { "id": "docs-control-api-examples", "title": "Add response examples",
      "epic": "Docs", "status": "ready", "size": "S", "from": "docs-control-api",
      "ready": true, "noWorkAttempts": 0 },
    { "id": "triaged-not-groomed", "title": "Make the thing better",
      "epic": "Docs", "status": "ready", "size": null, "ready": false,
      "noWorkAttempts": 0,
      "notReady": [
        "no groomed detail file — write backlog/triaged-not-groomed.md with What/How/Validation",
        "no verify: command — nothing objective for the run to pass",
        "no size set — autopilot runs XS/S/M"
      ] },
    { "id": "docs-control-api-errors", "title": "Document the error bodies",
      "epic": "Docs", "status": "ready", "size": "S",
      "needs": ["docs-control-api"], "ready": false, "noWorkAttempts": 0,
      "notReady": ["needs docs-control-api — not done (active)"] },
    { "id": "docs-control-api-openapi", "title": "Publish the OpenAPI document",
      "epic": "Docs", "status": "ready", "size": "S", "ready": false,
      "retired": true, "noWorkAttempts": 3,
      "notReady": [
        "retired: 3 attempts started and produced no work (ceiling 3) — re-groom it or release it before it runs again"
      ] },
    { "id": "docs-control-api-approve", "title": "Approve the endpoint's docs",
      "epic": "Docs", "status": "awaiting-approval", "size": "S",
      "freshness": { "clean": false, "conflicts": ["CHANGELOG.md"],
                     "checkedAt": "2026-08-28T14:03:00Z" } }
  ],
  "issues": [
    { "line": 42, "text": "- [~] docs-control-api-schemas | Describe the schemas | ready",
      "reason": "Unrecognized checkbox `[~]` — use `[ ]` or `[x]`." }
  ],
  "strandedWork": {
    "count": 3,
    "unreadable": false,
    "doneItemsConsidered": 312,
    "branchesExamined": 1,
    "danglingCandidatesExamined": 50,
    "danglingCandidatesNotExamined": 261,
    "items": [
      { "id": "ui-started-runs-leave-no-record",
        "branch": "kiteloop/ui-started-runs-leave-no-record",
        "commitsAhead": 1,
        "ledgerSays": "the item is Done",
        "gitSays": "kiteloop/ui-started-runs-leave-no-record is not merged — 1 commit exists only there" },
      { "id": "affiliate-redirect-rejects-non-http-targets",
        "branch": "kiteloop/affiliate-redirect-rejects-non-http-targets",
        "commitsAhead": 0,
        "ledgerSays": "the item is Done",
        "gitSays": "there is no branch kiteloop/affiliate-redirect-rejects-non-http-targets — its commits are still in the object store, unreferenced" },
      { "id": "health-endpoint-cannot-report-unhealthy",
        "branch": "kiteloop/health-endpoint-cannot-report-unhealthy",
        "commitsAhead": 0,
        "ledgerSays": "the item is Ready",
        "gitSays": "the worktree at /Users/.../kiteloop/.kiteloop/worktrees/health-endpoint-cannot-report-unhealthy holds 8 uncommitted files — nothing is coming back for them",
        "worktreePath": "/Users/.../kiteloop/.kiteloop/worktrees/health-endpoint-cannot-report-unhealthy",
        "uncommittedFiles": 8 }
    ]
  }
}
```

`status` is one of `draft`, `ready`, `active`, `in-review`, `awaiting-approval`,
`blocked`, `done`. `size` is `XS`/`S`/`M`/`L`/`XL`, or `null` when the item has no
size (autopilot only runs items ≤ `M`). `lane` is always present: `now` when the
line is marked `lane:now`, `later` otherwise — every `now` item runs before every
`later` one (see [`POST /v1/backlog/lane`](#post-v1backloglane)).

| Field | Notes |
|---|---|
| `needs` | The items this one is **waiting for** — its prerequisites, written on the backlog line as `needs:<id>` (comma-separated for several). **Omitted when the item names none**, which is most of them. Unlike `from`, this is read: an item whose prerequisite is not `done` is not `ready`, whatever else it carries |
| `from` | The item this one was **discovered from** — the parent it was split out of, or the failed item a regroom turned into new work. Written on the backlog line as `from:<id>`. **Omitted when the item records no parent**, which is most of them. Purely descriptive: it never affects `ready`, and the id it names may since have been finished and archived |
| `ready` | Whether autopilot would actually pick the item up — **both** pickup gates: the [Definition-of-Ready](../CLAUDE.md) gate on how the item is written, and the retry ceiling on what its attempts have produced. **Present only on `ready` items**: readiness at pickup means nothing for a `done`, `blocked` or `draft` item, and evaluating it costs a detail-file parse each |
| `notReady` | One phrase per unmet clause, in the gate's own words (missing detail file, missing `verify:`, missing or too-large size, an unsatisfied `needs:`, and last the retirement). Omitted when `ready` is `true`. A dependency gets one phrase each, naming it and why it doesn't count: `needs <id> — not done (<status>)`, `needs <id> — no such item` for an id that names nothing, or `needs <id> — dependency cycle: a → b → a` when two items wait on each other |
| `retired` | `true` when the **retry ceiling** has stopped autopilot starting the item — see below. **Omitted when it is false**, like `notReady`, so its presence is the whole signal |
| `noWorkAttempts` | Attempts in a row that left nothing behind, which is what `retired` is `true` at 3 of. Reported for every judged item, retired or not, so a streak building towards the ceiling is visible before it lands. Present alongside `ready`, and omitted with it — and omitted too when this build has no metric store attached, since nothing then recorded an attempt it could count |
| `issues` | The lines of BACKLOG.md the parser refused, the same ones the panel banners: `line` (1-based), `text` (the line as written, trimmed) and `reason` (what to type instead). **Always present** — `[]` on a file that parsed cleanly, so a clean backlog is distinguishable from a build too old to report this. A malformed line yields no item, so without this the list is simply shorter than the file; a line that *did* parse can also raise one (a dropped field, a duplicate id), in which case the item is in `items` too |
| `strandedWork` | Work the ledger has lost track of — `done` items whose work never reached `HEAD` (still on a branch nothing merged, or left unreferenced in the object store by a teardown that deleted the branch), plus a worktree still on disk holding uncommitted changes for an item nothing is coming back for. **Always present** — see below |
| `freshness` | Whether an item **at the gate** (`awaiting-approval`) still merges cleanly onto the project's current base — `{"clean": bool, "conflicts": [paths], "checkedAt": <ISO-8601>}`, checked with `git merge-tree` rather than by attempting the merge. **Present only for a checked gate item**: omitted for every other status, and for a gate item on a live-tree project (nothing to check) or one that predates this build (nothing cached yet). Checked when the item reaches the gate and again after every merge into the base since, so a sibling landing while this one waits turns `clean` false before anyone approves it |
| `gate` | The approval gate as a **step**, for an item at `awaiting-approval` only — `{"state": "verifying", "since": "…"}` while the merge gate is verifying the merged tree (a run's own gate, or an approval's), `{"state": "waiting"}` once it is a person's turn, `{"state": "refused", "since": "…", "reason": "…"}` when the last merge attempt refused, with the reason verbatim. A gate still verifying is not waiting on anyone; a driver that summons a person should look for `waiting` or `refused`, not for the status alone |

`issues` is why a queue depth read off `items` can be trusted: a typo'd checkbox
removes an item from the list with nothing else to show for it, and a driver — or
the Planner sizing the queue — would otherwise take the difference for work
that does not exist. The lines are not lost from the file; they are just not work
as far as the app is concerned until someone fixes them.

An item triaged to `ready` but never groomed looks identical to a runnable one by
id, title and status. These fields let a driver see which items `POST /v1/runs`
would refuse with a 422 *before* starting anything — the same checks
`BacklogAutopilot` filters its queue with, so the answers agree. They are the
cheap gates only: `GroundingCheck` (whether the item's claims match the codebase)
is not run here.

#### `retired` — groomed, and going nowhere

Grooming is only half of what pickup asks. The **retry ceiling** is the other
half: an item whose last `3` attempts each ended with nothing to show for them is
refused before a run starts, because starting it again buys the same answer at
full price — see *Autonomy* in `CLAUDE.md` and `RetryCeiling`. A perfectly
groomed item can sit in that state indefinitely, and it used to be reported
`"ready": true`, so a headless driver kept posting runs the app silently
declined.

`retired` and `noWorkAttempts` are what tell the two apart: **ungroomed** is a
section to write, **retired** is a release or a rewrite. The `notReady` phrase is
the ceiling's own, the same one the run log and the item's `## Notes` carry, and
it comes last — after every clause the groomer could act on, since an item can be
both.

Both are counted from the recorded run ledger (`~/.kiteloop/task-metrics.jsonl`),
so they survive a restart, and the judgement is exactly pickup's: an attempt that
produced work clears the streak outright, attempts recorded against a *different*
project are not counted, and the two releases lift it — the item rewritten since
(its What/How/Validation re-groomed), or a human's release
([`POST /v1/backlog/release`](#post-v1backlogrelease)). Both fields are omitted
entirely by a build with no metric
store attached: there is then no history to count, and reporting a clean one
would answer a question nothing asked.

#### `strandedWork` — work the ledger has lost track of

An item can be marked `done` with its commits still sitting on a branch `main`
has never seen. Kiteloop has been able to detect that for one item at a time
since `ItemDisagreements` landed, in a view a person has to open — so the answer
existed and nobody was given it. Two items were eventually found by walking
`git branch --list` by hand on 2026-08-11: one merged cleanly, the other had gone
stale (`main` was refactored underneath it) and the work has to be redone. That
is the cost of finding this late rather than at all.

A third case was found by hand the same way ten days later: a worktree still on
disk with uncommitted changes for an item that was never marked `done` at all —
nothing calls that running, so no run picks it back up, and the changes are in
no commit, so `git fsck` cannot find them either. A worktree in that state sat
dirty for ten days before anyone noticed, and an ordinary `git worktree prune`
would have destroyed it without a trace.

| Field | Notes |
|---|---|
| `count` | How many findings there are — stranded `done` items plus dirty worktrees. `0` on a clean sweep **and** when git could not be read — check `unreadable` to tell those apart |
| `unreadable` | `true` when git could not be asked at all: no repository, or the listing failed. **Always present.** A project whose git cannot be read reports no strandings rather than reporting every item as one |
| `reason` | Why nothing could be read. Present only when `unreadable` |
| `doneItemsConsidered` | How many `done` items the branch/dangling sweep was given — the denominator for those two passes only |
| `branchesExamined` | How many of them cost a second git call, i.e. how many were actually named by the branch listing |
| `branchesNotExamined` | Candidates left unasked because the branch budget (50) ran out. **Omitted when the sweep finished**, so a truncated sweep cannot be read as a complete one |
| `danglingCandidatesExamined` | How many `done` items the listing did *not* name — the candidates for a branch that was deleted — had their ref read, to tell a branch tidied away after a merge from one teardown dropped over unmerged work |
| `danglingCandidatesNotExamined` | Candidates left unasked because the dangling budget (50) ran out. **Omitted when that pass finished**, for the same reason as `branchesNotExamined` |
| `items[].commitsAhead` | Commits the branch carries that `HEAD` cannot reach. `0` for a dropped branch, and for a dirty-worktree finding — that one is about uncommitted files, not commits |
| `items[].ledgerSays` / `gitSays` | The disagreement in plain words — for the branch findings, the detection rule's own wording, the same the item detail view shows; for a dirty worktree, the item's current stage and what git found sitting there |
| `items[].worktreePath` | Present only for a dirty-worktree finding — the directory holding the uncommitted changes, to go look at directly |
| `items[].uncommittedFiles` | Present alongside `worktreePath`: how many files are uncommitted there |

**Three ways work strands, and all three are reported.** The first is a branch
nothing merged. The second is a branch that is not there at all: teardown
deletes the branch it built, and when it does that over commits nobody merged,
the work is left in the object store with nothing pointing at it. An item in
that state has no branch for the listing to name, so it used to be counted
clean — `gitSays` names it as *"its commits are still in the object store,
unreferenced"*, and `git fsck --no-reflogs --dangling` is where a person goes
looking. The third is the worktree case above: uncommitted changes for an item
that is neither running right now nor kept on purpose for a person to inspect
after a blocked run (`status: "blocked"`) — both of those are excluded because a
worktree looks identical whether it is mid-run or genuinely abandoned, and only
"is anything coming back for these changes" tells them apart.

**Nothing here acts on what it finds** — no commit, no delete, no prune, no
merge. Of the two done-item findings found by hand, one was mergeable and the
other was not, and nothing in the ledger could have told them apart; the same is
true of a stale worktree, where whether to redo the work, hand-commit it, or
throw it away is a person's call. Merging a `done` item's branch is still
`POST /v1/backlog/approve` and `autoMergeOnApproval` — this endpoint only ever
reports.

The sweep is bounded, because reading git per `done` item is not affordable on a
polled endpoint: a project with 300 done items would be 300 `git` invocations.
One `git branch --no-merged HEAD` answers "present and unmerged" for the whole
project at once, and only the handful of `done` items that appear in it cost a
second call. The dangling half costs one ref read per candidate, capped at 50,
plus a **single** `fsck` object walk for the whole sweep — never one per item,
and not at all when every `done` item still has its branch. That walk is the
expensive part (~2s on a repository this size), so a project whose merged
branches are deleted pays it on each call: poll `GET /v1/backlog` accordingly.
A backlog with nothing `done` does not spawn git at all. The dirty-worktree pass
is bounded by construction rather than by a budget: it costs one `git status`
per directory actually sitting under `.kiteloop/worktrees`, which is normally a
handful — one per run in flight or recently finished, never one per backlog item.

**Status:** 200 · 400 (missing `?project=`) · 401 · 409 (project not open).

---

### GET /v1/backlog/detail

One item, drilled into: the line fields plus the groomed detail file — What,
How, acceptance criteria, out-of-scope, notes, verify commands — as the gates
read it. An item with no detail file answers the line fields alone; the keys
for missing sections are simply absent.

```bash
curl -s -H "$H" "$B/backlog/detail?project=kiteloop&item=<id>"
```

```json
{"id": "…", "title": "…", "status": "ready", "epic": "Quality", "size": "M",
 "verify": "cd \"$(git rev-parse --show-toplevel)/Kiteloop\" && …",
 "what": "…", "approach": "…",
 "acceptanceCriteria": ["…"], "outOfScope": ["…"], "notes": "…", "why": "…"}
```

**Status:** 200 · 400 (missing `project`/`item`) · 404 (no such item) · 409
(project not open)

### GET /v1/backlog/diff

**What approving would merge**: the diff between the project's current HEAD and
the item's autopilot branch (`kiteloop/<item-id>`), three-dot so only the
branch's own work shows, plus a `--stat` summary. The human gate exists for
judgment; this is the thing to judge — from a phone as well as from the Mac.

```bash
curl -s -H "$H" "$B/backlog/diff?project=kiteloop&item=<id>"
```

```json
{"item": "…", "branch": "kiteloop/…",
 "stat": " Services/Foo.swift | 12 ++++++------\n 1 file changed…",
 "patch": "diff --git a/Services/Foo.swift b/Services/Foo.swift\n…",
 "truncated": false}
```

`patch` is capped at 200000 characters; `truncated: true` says the cap bit —
read the rest on the Mac. **404** when the item has no branch: it ran in the
live tree, or the branch was already merged and deleted.

**Status:** 200 · 400 (missing `project`/`item`) · 404 (no such item, or no
branch) · 409 (project not open)

### GET /v1/metrics

Recent **measured runs**, newest first. This is the *measurement* counterpart to
`GET /v1/runs`: that endpoint answers about runs, addressed by `runId`, while a
metric record is appended to `~/.kiteloop/task-metrics.jsonl` every time an item
finishes and is addressed by item and project. Both survive a restart; only this
one is scored. It
carries what the [success metrics](success-metrics.md) scorecard is scored on —
duration and cost (estimation accuracy), reviewer retries (rework), the outcome,
and the advisory judge score — plus both halves of metric #3, `firstPassRate`
(#3a) and `escapedDefects` (#3b), rolled up over the whole recorded history
rather than the page of records returned.

| Query | Required | Notes |
|---|---|---|
| `project` | no | Path or folder name; omit for every project. The project must be open |
| `limit` | no | How many records to return, `1…200` (default `20`) |

```bash
curl -s -H "$H" "$B/metrics?project=kiteloop&limit=5"
```

```json
{
  "project": "kiteloop",
  "count": 1,
  "metrics": [
    {
      "runId": "3F9A…",
      "item": "control-get-metrics",
      "title": "Add GET /v1/metrics returning recent run records",
      "project": "kiteloop",
      "epic": "Control API",
      "size": "M",
      "startedAt": "2026-08-04T09:12:00Z",
      "completedAt": "2026-08-04T09:27:42Z",
      "durationSec": 942,
      "costUSD": 1.25,
      "predictedCostUSD": 0.90,
      "overItemCap": true,
      "reviewerRetries": 1,
      "outcome": "done",
      "worker": "Builder",
      "reviewer": "Reviewer",
      "qualityScore": 0.87,
      "judgeDimensions": { "verify_passed": 1.0, "scope_respected": 0.75 },
      "qualityScoreDiffTruncated": false,
      "openingContext": {
        "worker": {
          "promptTokens": 33012,
          "billedTokens": 33012,
          "inputTokens": 2,
          "cacheWriteTokens": 33010,
          "cacheReadTokens": 0
        }
      }
    }
  ],
  "openingContextByRole": [
    {
      "role": "worker",
      "runs": 42,
      "promptTokens": { "p50": 33012, "p90": 41890 },
      "billedTokens": { "p50": 12440, "p90": 33012 }
    }
  ],
  "escapedDefects": {
    "windowDays": 7,
    "approvals": 12,
    "reopened": 1,
    "lateReopened": 2,
    "rate": 0.0833
  },
  "firstPassRate": {
    "judged": 16,
    "firstPass": 12,
    "rate": 0.75
  }
}
```

`runId` is the workflow execution id — the same handle `GET /v1/runs` reports, so
a run can be followed from its events into its metrics. It is `null` for a record
written without one. `qualityScore` and `judgeDimensions` are `null` when the run
wasn't scored (a cancelled run, or the judge gave no verdict) — `null` means *unscored*,
not zero. `project` at the top level is echoed only when you filtered by one.

`qualityScoreDiffTruncated` says whether the diff the judge actually saw was cut
short before it reached the judge — the raw diff text is capped at 8,000
characters, independent of the file-level `git diff --stat` summary the judge is
also shown. `null` when the judge was never asked (same cases as a null
`qualityScore`); `true`/`false` otherwise. A large diff scored through a
truncated window reads low for the window's size, not necessarily for the work's
quality — filter this out of an average, or read it beside the score, rather than
blending a keyhole reading in with ones taken over the whole diff.

`costUSD` is what the run actually cost; the two fields beside it say what it was
supposed to cost and whether it stayed there. Read them together — an overrun
without the forecast it overran says nothing about how far the estimate was out,
and a forecast says nothing about whether it held.

| Field | Meaning |
|---|---|
| `predictedCostUSD` | What the cost governor forecast this item would cost, taken at pickup — the number the item's cap was set from. `null` when there was nothing to predict from, or on a record written before the forecast was captured. Never `0`, which would read as a forecast of free |
| `overItemCap` | Whether the run crossed that per-item ceiling. `false` is a measurement — the run finished inside its cap. `null` is *unknown*: the record predates this field, so nobody asked, which is not the same as a run that stayed within budget |

The per-item cap is **advisory**, so `true` is not a failure and not an
interrupted run: the autopilot records the breach and lets the item finish, since
killing an item mid-review throws away work already paid for. It is the signal
for which items outgrew their estimate. The *session* cap is the hard stop, and a
run it ends shows up as an `outcome` of `blocked:…` instead.

`openingContext` is what each role was sent **before it had done anything** — the
CLAUDE.md autonomy rules, the agent's profile and the tool schemas, measured on
that role's first model call. `null`, and a role simply absent, means no turn of
that role reported one; every record written before the capture existed is in that
state, and none of them opened with zero tokens.

| Field | Meaning |
|---|---|
| `promptTokens` | How big the opening context is — everything the first call was sent, cached or not |
| `billedTokens` | What it cost to send at full price: `inputTokens + cacheWriteTokens` |
| `inputTokens` | The uncached remainder billed at the base rate |
| `cacheWriteTokens` | Written to the cache by this call — most of the context on a cold session |
| `cacheReadTokens` | Served from the cache — most of it on a session resumed from the previous item |

Read `promptTokens` for size and `billedTokens` for cost; they differ by an order
of magnitude between a cold session and a warm one, and reading either as the
other makes a cache hit look like a slimmer prompt.
[`docs/opening-context.md`](opening-context.md) decomposes the figure by
component and names the one that dominates.

`openingContextByRole` is the same figure as a distribution — p50 and p90 per
role, which is how the question is actually asked, since one run cannot say
whether 33k is normal. Unlike the two rates below it is computed over **the
records in this response only**, so `?limit=` is its window: taken over all
history it would answer for a `CLAUDE.md` and a knowledge package that have since
changed. `runs` counts the records that measured an opening context, which is
fewer than `count` while history written before the capture is still in the page.

`escapedDefects` is [success metric #3b](success-metrics.md#how-3b-escaped-defect-rate-is-measured):
the share of *approved* items that came back. It is computed from every approval
recorded in `~/.kiteloop/task-approvals.jsonl`, so unlike `metrics` it is not
narrowed by `limit` — the rate is about the whole history, not the page you asked
for. `?project=` does scope it.

| Field | Meaning |
|---|---|
| `windowDays` | How long after an approval a reopen still counts (`7`, inclusive of the boundary) |
| `approvals` | Items observed reaching `done` — the denominator. Approved twice counts twice |
| `reopened` | Approvals that came back to `ready`/`blocked` inside the window — the numerator |
| `lateReopened` | Reopens outside the window. Reported so a `0` rate isn't confused with "nothing came back" |
| `rate` | `reopened ÷ approvals`, or `null` when nothing has been approved yet |

`rate` is `null`, never `0`, before the first approval: 0/0 is *not measured yet*.
An item the reviewer bounced back to `ready` never reached `done`, so it is a
first-pass failure (metric #3a) and is deliberately absent from both sides here.

`firstPassRate` is [success metric #3a](success-metrics.md#the-scorecard), the
half that scores what review *looked at*: the share of judged runs it passed on
the first worker attempt. It is computed from every record in
`~/.kiteloop/task-metrics.jsonl`, so like `escapedDefects` it is not narrowed by
`limit` and is scoped by `?project=`.

| Field | Meaning |
|---|---|
| `judged` | Runs that reached a verdict — the denominator. See the population below |
| `firstPass` | Of those, the ones review passed with no rework loop behind them — the numerator |
| `rate` | `firstPass ÷ judged`, or `null` when nothing has been judged yet |

**The population**, decided by a record's `outcome` alone:

- **`done` and `awaiting-approval` are passes** — the two states a run reaches
  when review says yes, one per flow (the approval gate off, or a human waiting
  at it). A pass with `reviewerRetries` of `0` is a first pass, because
  `reviewerRetries` counts reviewer passes *beyond the first*.
- **`blocked:<reason>` is in the denominator and never the numerator.** That
  covers a reviewer rejection, and also the ways a run is cut short before any
  reviewer saw it — a stall, a timeout, a cost cap. All of them count against
  the rate: the SLO asks what share of started work review passed first time,
  and a run that never got that far did not.
- **`cancelled` is in neither half.** A human stopped it, so it says nothing
  about whether the loop's quality control works.

`rate` is `null`, never `0`, until a run has been judged: 0/0 is *not measured
yet*, not a loop that never passes.

**Status:** 200 · 400 (unusable `limit`) · 401 · 409 (project not open) · 503
(no metric store attached — the app wires one at launch, so this only shows up in
an embedded or test setup).

---

### GET /v1/estimates

The **current estimate for each scoped item**, newest first — the forecast side of
`GET /v1/metrics`. Scoping an item again appends to
`~/.kiteloop/task-estimates.jsonl` rather than replacing the old estimate, so this
endpoint reports only the newest one per item: that is what the run was planned
against, and what its actual should be scored against.

Items are keyed per project, so two projects that both have an `item-1` each keep
their own estimate.

| Query | Required | Notes |
|---|---|---|
| `project` | no | Path or folder name; omit for every project. The project must be open |
| `limit` | no | How many estimates to return, `1…200` (default `20`) |

```bash
curl -s -H "$H" "$B/estimates?project=kiteloop&limit=5"
```

```json
{
  "project": "kiteloop",
  "count": 1,
  "estimates": [
    {
      "item": "control-get-estimates",
      "project": "kiteloop",
      "createdAt": "2026-08-04T09:05:11Z",
      "size": "S",
      "predictedDurationSec": 900,
      "predictedCostUSD": 0.75,
      "predictedRetries": 1,
      "confidence": 0.62,
      "source": "hybrid",
      "rationale": "One endpoint plus a test."
    }
  ]
}
```

`confidence` (0…1) says how much real history backs the numbers — it is low when
the estimate is the scoping LLM's rough guess rather than an average of
size-matched actuals. In that ungrounded case `predictedCostUSD` and
`predictedRetries` are `null`: unknown, not zero. `project` at the top level is
echoed only when you filtered by one.

Pair an item's estimate here with its record in `GET /v1/metrics` to score
estimation accuracy.

**Status:** 200 · 400 (unusable `limit`) · 401 · 409 (project not open) · 503
(no metric store attached — the app wires one at launch, so this only shows up in
an embedded or test setup).

---

### GET /v1/grooming

What happened to items **before** they ran, newest first: each filing, and each
refusal by a pre-run check. `GET /v1/metrics` only has a record for an item that
actually ran, so on its own it can't tell a queue that drained because four items
were refused for a missing `verify:` from one that drained because the work is
done. Read from `~/.kiteloop/grooming.jsonl`, so it survives restarts and spans
every project unless you narrow it.

| Query | Required | Notes |
|---|---|---|
| `project` | no | Path or folder name; omit for every project. The project must be open |
| `limit` | no | How many records to return, `1…200` (default `20`) |

```bash
curl -s -H "$H" "$B/grooming?project=kiteloop&limit=5"
```

```json
{
  "project": "kiteloop",
  "count": 2,
  "grooming": [
    {
      "at": "2026-08-07T02:14:09Z",
      "item": "control-api-grooming-records",
      "project": "kiteloop",
      "event": "check-failed",
      "check": "definition-of-ready",
      "reason": "no verify: command — nothing objective for the run to pass"
    },
    {
      "at": "2026-08-07T01:58:44Z",
      "item": "merge-refusal-names-dirty-paths",
      "project": "kiteloop",
      "event": "filed-ready",
      "check": null,
      "reason": null
    }
  ]
}
```

`event` is one of:

| `event` | Meaning |
|---|---|
| `filed-ready` | Filed at `ready` — groomed well enough to be picked up |
| `filed-draft` | Filed at `draft` — filed, but not runnable as it stands |
| `check-failed` | A pre-run check refused the item at pickup |
| `released` | A human lifted the retry ceiling's refusal ([`POST /v1/backlog/release`](#post-v1backlogrelease)) |

`check` and `reason` are set on a `check-failed` and a `released` record, and
`null` on a filing. `check` is the check that refused it — `definition-of-ready`,
`grounding-check` or `retry-ceiling` — and `reason` is the failing clause as the
verdict phrased it. Grouping refusals by `check` is what separates "the item was
never groomed" (`definition-of-ready`, `grounding-check`) from "the item is
groomed and going nowhere" (`retry-ceiling`, the ceiling on attempts that produce
no work).

`project` at the top level is echoed only when you filtered by one.

**Status:** 200 · 400 (unusable `limit`) · 401 · 409 (project not open) · 503
(no grooming ledger attached — the app wires one at launch, so this only shows up
in an embedded or test setup).

---

### GET /v1/report

**What a period of unattended work produced**, per project and for the portfolio:
merged ÷ filed, why the rejections were rejected, what it cost and how much of the
window sat idle. The same report the Planner panel renders, over the same two
ledgers `GET /v1/metrics` and `GET /v1/grooming` serve raw — this aggregates them,
so a driver reading how a night went doesn't have to re-derive the rate (and can't
derive a different one).

The window is the whole portfolio; there is no `?project=` filter. Rows are one
per project, busiest first and capped at six, with everything else still counted
in `total` and named by `omittedProjects`.

| Query | Required | Notes |
|---|---|---|
| `hours` | no | Window to report on, `1…720` (default `24`) |

```bash
curl -s -H "$H" "$B/report?hours=24"
```

```json
{
  "period": {
    "hours": 24,
    "label": "last 24h",
    "start": "2026-08-09T02:00:00Z",
    "end": "2026-08-10T02:00:00Z"
  },
  "summary": "merged 3/5 filed (60%) · 1 rejected · $3.90",
  "empty": false,
  "rows": [
    {
      "project": "kiteloop",
      "filed": 5,
      "ready": 4,
      "draft": 1,
      "run": 4,
      "merged": 3,
      "rejected": 1,
      "awaitingApproval": 0,
      "skippedByCheck": 2,
      "spendUSD": 3.9,
      "idleSeconds": 68400,
      "quiet": false,
      "mergeRate": { "merged": 3, "of": 5, "basis": "filed", "fraction": 0.6 },
      "causes": [
        {
          "label": "grounding-check",
          "count": 1,
          "example": "No such file: Services/Ghost.swift"
        }
      ],
      "text": "filed 5 (4 ready · 1 draft) · run 4 · merged 3 · rejected 1 · $3.90 · idle 19h"
    }
  ],
  "total": { "project": "All projects", "...": "same shape as a row" },
  "omittedProjects": 0
}
```

`mergeRate.basis` is the field to read before the rate itself:

| `basis` | Denominator | What it answers |
|---|---|---|
| `filed` | Items filed in the period | Was the grooming any good — the headline |
| `run` | Items that ran in the period | Did what ran land? The fallback for a period in which nothing was filed |

Nothing files items in a period where the Planner did no grooming, and `0/0`
would report a good night as a blank — so the rate falls back rather than
disappearing, and names which of the two questions it is answering.
`fraction` is `null` when there is nothing to divide by at all: *not measured*,
not 0%.

`total` is a row in the same shape, covering every project including any the row
list left out, so a summary line and a project line read the same way. A row with
`quiet: true` had nothing filed, nothing run and nothing refused; `empty` says the
same about the whole portfolio. `causes` groups the period's rejections by the
pre-run check whose verdict still stands against the item — at most three, most
common first — with `label` `"no check verdict"` when none does, which points at
the run rather than at the grooming.

Items are counted in the period they *finished* in, so an item that straddled the
window's start is counted once. `idleSeconds` is period time with no item running
— a project that ran nothing is idle for the whole window.

`merged` counts the runs whose work is on record as having reached the project's
main line — recorded when that was decided, at the auto-merge or at the human
gate, which is after the run itself ended. A run whose gate nobody has resolved
has no such record and counts as **not merged**: unknown is not a merge, and the
rate does not guess in the direction that flatters it. Runs from before the app
recorded this at all read the same way. A run is counted in the period it
finished in whether or not its merge was decided inside that window, so approving
this morning's queue still credits last night.

**Status:** 200 · 400 (unusable `hours`) · 401 · 503 (no metric store or no
grooming ledger attached — the message says which; the app wires both at launch,
so this only shows up in an embedded or test setup).

---

### GET /v1/autopilot

Reads the project's current autopilot configuration — worker/reviewer, the
budget, the derived clocks, turn budget and cost cap, and the run flags — plus a `run` block saying **what it is doing with
them**, `sessionSpendUSD`, what the session has spent so far, and `paused`,
whether the project is held at all. The
configuration fields are the same shape as the `PUT` response, so a driver can
read back exactly what it wrote (or discover what the Autopilot UI is set to
before deciding whether it needs to write at all); `run`, `sessionSpendUSD` and
`paused` are on the read only, since a write never sets them.

| Query | Required | Notes |
|---|---|---|
| `project` | yes | Path or folder name |

```bash
curl -s -H "$H" "$B/autopilot?project=kiteloop"
```

```json
{
  "project": "kiteloop",
  "worker": "6B1F…",
  "reviewer": "9C42…",
  "autonomy": "off",
  "approvalGate": "propose",
  "maxRetries": 3,
  "stallTimeoutMinutes": 20,
  "budgetUSD": 25,
  "autoMergeOnApproval": false,
  "autoMergeVerifyTimeoutMinutes": 30,
  "runTimeoutSource": {"worker": "default", "gate": "default"},
  "workerMaxTurns": 50,
  "workerMaxTurnsSource": "default",
  "itemCostCapUSD": null,
  "itemCostCapSource": "default",
  "worktreeSetupCommand": null,
  "effectiveAutoMergeVerifyCommand": "./scripts/ci-local.sh",
  "autoMergeVerifyCommandSource": "from verify-map rule `apps/api/**`",
  "effectiveWorktreeSetupCommand": null,
  "worktreeSetupCommandSource": "nothing to set up — no lockfile or generator in the tree",
  "baseBranch": null,
  "openPullRequest": false,
  "approveReviewPassedRuns": false,
  "autonomousWorkEnabled": false,
  "sessionSpendUSD": 12.4,
  "paused": false,
  "run": {
    "state": "idle",
    "running": false,
    "item": null,
    "itemTitle": null,
    "runId": null,
    "startedAt": null,
    "status": "idle",
    "heldItems": 0,
    "detail": null,
    "phaseRail": null
  }
}
```

`worker` and `reviewer` are agent **ids** (never names), `null` until
assigned — the same condition `autopilotReady` reports in `GET /v1/projects`.
A `null` `reviewer` is also a setting — **no separate reviewer**: a run goes
from the worker straight to the gates. A project with no autopilot config yet
starts that way; one whose config names a reviewer keeps it.
`budgetUSD` and `baseBranch` are `null` when unset; a
`null` `baseBranch` means runs fork from and land on the checkout's own `HEAD`,
and [`GET /v1/projects`](#get-v1projects) reports which branch that resolves to.

#### The autonomy dial

`autonomy` is **one setting for how far this project may go on its own** —
`off`, `propose` or `land` — over two stored values: `autonomousWorkEnabled`
(who starts runs) and **`approvalGate`** (what happens to a run the reviewer
passed):

| `autonomy` | `autonomousWorkEnabled` | `approvalGate` |
|---|---|---|
| `off` | `false` | `propose` |
| `propose` | `true` | `propose` |
| `land` | `true` | `land` |

`off`: the fleet scheduler and the grooming loop never pick this project up —
a human-started run still works exactly as it does today. `propose`: unattended
runs start, and every review-passed item parks at the approval gate for a
person. `land`: a review-passed item is approved without asking and merged —
see [Approving without asking](#approving-without-asking) and
[Pull requests](#pull-requests) below. `autonomy` reads `off` whenever
`autonomousWorkEnabled` is `false`; with `approvalGate` at `land` such a project's
hand-started runs still land themselves when review passes, and the Autonomy
section of the settings page says so under the dial.

`approvalGate` is one value — `propose` (a person approves, and that approval does
not merge) or `land` (approved and merged when review passes) — so the gate has
no half-set state. `approveReviewPassedRuns` and `autoMergeOnApproval`, the two
switches it replaced, are **deprecated**: `GET` reports both, read off the gate
(`true` only at `land`), for one release. A `PUT` naming either is mapped onto
the gate: **`land` when both end up `true`** — a switch the body leaves out
keeps the value the gate gives it now — **`propose` otherwise**. An
`autopilot-config.json` written before the gate existed loads the same way:
`land` only when both stored switches are `true`. `approvalGate` wins over the
old switches when a body sends both, and `autonomy` wins over everything.

#### The one budget

`budgetUSD` is **this project's own** daily ceiling, not the portfolio's, and
also the hard stop that pauses autopilot for the rest of a sitting once it is
spent. `null` means the project has no ceiling of its own, in which case the
portfolio-wide one governs it alone; the portfolio ceiling is reported by
[`GET /v1/coordinator/scheduling`](#get-v1coordinatorscheduling) and set by its
`PUT`. Both apply — see [Two daily ceilings](#two-daily-ceilings).

`budgetUSD` **replaces** `perItemCostCapUSD`, `sessionCostCapUSD` and
`costCapMargin`: none of the three is a setting any more, or in the `GET`
payload; a `PUT` naming one is ignored, and a config file still holding one
loads with it ignored. The per-item ceiling that `perItemCostCapUSD` and
`costCapMargin` used to compute by hand is now derived like the two clocks —
see `itemCostCapUSD` under [The two timeouts are derived, not
set](#the-two-timeouts-are-derived-not-set).

`sessionSpendUSD` is what the **session** has spent — the figure `budgetUSD`
is measured against, and the same one the Autopilot panel's Session readout
shows. A session is not a run: every driver here starts one item per run, and
the ledger accumulates across all of them, from app launch until a
[resume](#post-v1autopilotresume) past a spent budget opens a new one. The item
in flight is included, trailing the live turn by up to one watchdog sample
(~16s). Reported at `0` for a project that has run nothing, never omitted — an
absent field would be indistinguishable from an older build. It is not
derivable from run costs: [`GET /v1/runs/{runId}`](#get-v1runsrunid) reports
what one item cost, which is a fraction of a night's sitting.

`paused` is the same reading [`GET /v1/projects`](#get-v1projects) gives for
this project: true when a human parked it with the paused switch on the fleet
board, or when its own autopilot is holding the queue
([`POST /v1/autopilot/pause`](#post-v1autopilotpause)). A pause taken while an
item is in flight keeps reading `true` once that item finishes — the hold
outlives the run it interrupted, and only
[`POST /v1/autopilot/resume`](#post-v1autopilotresume) lifts it. `run.state`
reads `held` for the same project, with `heldItems` counting what is left of the
queue behind the hold — `0` when the pause was taken over the last item.

#### The two timeouts are derived, not set

`stallTimeoutMinutes` and `autoMergeVerifyTimeoutMinutes` are **read-only**.
Neither was ever a preference: both describe how long this project's work
actually takes, and the ledger already records it. Each is derived from the
phase it bounds, never from the whole run:

| Clock | Bounds | Derivation | Until there is enough history |
|---|---|---|---|
| `stallTimeoutMinutes` | one worker/reviewer node activation | p95 worker-phase duration × 1.5, floored at 15 min, capped at 60 | `20` |
| `autoMergeVerifyTimeoutMinutes` | both verifies it bounds — the pre-review one and the merge gate's | p95 verify duration × 1.5, floored at 10 min, uncapped | `30` |

Each reads only the phases it bounds, so one can be measured while the other is
still on its default.

The gate's clock reads two phases because it bounds two: the pre-review verify
and the merge gate's verify are the item's own `verify:` run on the same class
of tree under the one deadline. A run that measured both contributes the larger
of the two as its one gate sample; a run that measured one contributes that one.

"Enough history" is **five runs carrying that clock's duration**, counted per
clock rather than per run: a run whose metric record carries a worker-phase
duration is a worker sample whether or not it also carries a verify one.
Records written before those fields existed carry neither and count for
nothing. A project whose runs stop at the approval gate — every project running
under `propose`, which parks a passed run there — therefore measures both
clocks all the same: it never reaches the merge gate, but it runs the
pre-review verify on every run.

`runTimeoutSource` says which side of that line each clock is on, one answer
per clock:

```json
"runTimeoutSource": {"worker": "derived", "gate": "default"}
```

Every reply carries both, so a measured `20` can be told from an unmeasured
one — and a project can be seen measuring one clock while the other waits.

The worker's turn budget is derived the same way, from the turn count each
run's metric record carries: `workerMaxTurns` is the p95 of those counts plus
half again, rounded up, floored at 50 and capped at 150, and
`workerMaxTurnsSource` says whether it was measured — `derived` once five runs
carry a count — or is still the `default` 50:

```json
"workerMaxTurns": 50,
"workerMaxTurnsSource": "default"
```

The per-item cost cap is derived the same way, from the cost each landed run
recorded: `itemCostCapUSD` is the p95 of those costs plus half again, and an
item whose own predicted cost is higher is capped at that instead.
`itemCostCapSource` is `derived` once five runs carry a cost; until then it is
`default`, `itemCostCapUSD` is `null`, and each item is capped at its
predicted cost plus half again — uncapped, the budget still bounding it, when
nothing predicts it:

```json
"itemCostCapUSD": null,
"itemCostCapSource": "default"
```

A `PUT` naming either is **accepted and ignored**, the way `coordinator` is,
and answered with the derived value rather than a 400 — an old caller keeps
working and reads what the project will really run under in the same reply.
Neither is written to `autopilot-config.json` any longer; a copy left in an
old file is read past.

A `coordinator` field in a `PUT` body is **deprecated and ignored** — the
per-project persona picker and the run supervisor it once configured are
retired; old configs and callers keep working, and the field is absent from
the `GET` payload.

#### Pull requests

`openPullRequest` is the **PR** in ADR-0001's sandbox → PR → human gate. With it
on, a run that ends at the approval gate with a branch has that branch pushed to
the project's remote and a GitHub pull request opened for it — title from the
item's backlog line, body from its detail file's What and Validation. The URL
lands in the item's Notes and in
[`GET /v1/runs/{runId}/result`](#get-v1runsrunidresult) as `pullRequestUrl`.

It **never merges**, and it changes nothing about approval: the pull request
presents the same branch the gate already guards, and `autoMergeOnApproval` alone
still decides whether that branch lands. With auto-merge on, an item whose branch
merged has nothing left to open a PR for and none is opened; one whose merge was
refused reaches the gate and does get a PR.

Three prerequisites, and a missing one costs the pull request rather than the
run: a project root that is a git repository (without one the item runs in the
live tree and there is no branch to push), a git remote, and a [`gh`](https://cli.github.com) that is installed and
authenticated. A run that can't satisfy them finishes exactly as it would have,
and the item's Notes say which one was missing.

**Opening the pull request is only half of it.** The run then follows the PR's
checks (`gh pr checks`) until they settle, and the approval notification fires
when they are green — not when the PR is merely open. A failing check is handed
back to the worker in a worktree checked out on the item's branch, for at most
**two fix rounds**, each committed and pushed to the PR; the item's own cost cap
is the real backstop, so a round the item can't pay for isn't started. Terminal
states — green (with how long it took), gave-up (naming the failing check),
timed out — land in the item's Notes next to the PR's URL, and the notification
carries the same verdict. A pull request with **no checks at all** is green
immediately, so a project without CI never waits. None of this is a separate
setting: it is what `openPullRequest` means.

```bash
curl -s -H "$H" -X PUT \
  -d '{"project":"kiteloop","openPullRequest":true}' $B/autopilot
curl -s -H "$H" $B/runs/$RUN/result | jq -r .pullRequestUrl
```

#### Approving without asking

`approvalGate: "land"` — or `autonomy: "land"`, see
[The autonomy dial](#the-autonomy-dial); `approveReviewPassedRuns` is its
deprecated spelling — is the
**human gate** in ADR-0001's sandbox → PR → human gate, made optional per
project. With it on, an item the reviewer passed
does not park at `awaiting-approval`: the run approves it itself, exactly as if a
person had, and the item goes to `done`. Off by default, and off is the gate.

It exists because an unattended night driven from the app alone stalls there —
the scheduler starts the runs, the reviewer passes them, and every one waits for
someone who is asleep. `kiteloop-verify.py --marathon --auto-approve` has always
been able to clear that gate from outside the app; this is the same lever for an
operator driving from inside it, and the harness flag is unchanged.

**Only a reviewer pass qualifies.** Four things have to hold, and each of the
others is deliberately left alone:

- the item is **at the gate** — a rejected or blocked run has no gate to clear
  and routes exactly as it does today;
- the setting is **on for this project** (there is no fleet-wide variant);
- the **reviewer passed**, rather than the run being salvaged by its own
  `verify:` after a stall or a cost cap — that clears the objective bar, not a
  review;
- **no merge was attempted and refused**. With `autoMergeOnApproval` on, a merge
  that could not be kept leaves the item at the gate for a person, because
  approving over it would stamp `done` on work that never landed.

Nothing about merging changes: the approval feeds the same `autoMergeOnApproval`
path it always has, and with auto-merge **off** the item reads `done` with its
work still on its branch, waiting for a human merge — the item's Notes say so.

**Every automatic approval is recorded as one**, so a morning reading of the
night can tell "a human accepted this" from "the setting accepted this":
`"approval": "automatic"` in
[`GET /v1/runs/{runId}/result`](#get-v1runsrunidresult) and in the durable run
record, an `approval=automatic` field on the run's `item.end` log line, and a
line in the item's `## Notes`. The field is **absent**, never `null`, on
everything else — including items a person approved, which happens after the run
record closes.

```bash
curl -s -H "$H" -X PUT \
  -d '{"project":"kiteloop","approvalGate":"land"}' $B/autopilot
curl -s -H "$H" $B/runs/$RUN/result | jq -r '.outcome, .approval'   # done, automatic
```

`autonomousWorkEnabled` is the project's **consent to unattended work** — off by
default, set the same way (`PUT` with `{"project":…,"autonomousWorkEnabled":true}`,
cleared by `reset`). Capability is not consent: a project with a worker and
reviewer is *startable*, and only this flag makes the fleet's scheduler
and the Planner's grooming loop pick it up on their own. A human start — the app's Run button
or `POST /v1/runs` — never consults it. While no open project has it on, the
scheduler holds with `noProjectOptedIn` and says so.

#### Run state

The `run` block answers "is this project running something, and is it stuck?".

The `gate` field beside it is the merge gate in progress, whoever asked for it —
`{"item": "<id>", "since": "<ISO 8601>", "state": "verifying"}` while a scratch
worktree is verifying a merged tree, `null` otherwise. A run's own gate also
shows on the `run` block's phase rail as the `merge` step for as long as the
verify runs; an approval's gate has no run, so this field is the only place it
shows. The gate's answer — waiting on a person, or refused with the reason — is
on the item, in [`GET /v1/backlog`](#get-v1backlog)'s `gate`.
The same block appears on every entry of [`GET /v1/projects`](#get-v1projects).

| Field | Type | Notes |
|---|---|---|
| `state` | string | `idle`, `running`, `held` or `inconsistent` — see below |
| `running` | bool | True exactly when `state` is `running` |
| `item` | string \| null | The item in flight; `null` unless running |
| `itemTitle` | string \| null | Its title |
| `runId` | string \| null | The execution driving it — the same id `POST /v1/runs` returns. `null` in the gap between pickup and the workflow spinning up |
| `startedAt` | string \| null | ISO 8601, when the item became the one in flight |
| `status` | string | What the autopilot's own status reads (`idle`, `running`, `reviewing`, `paused`) — the claim `state` was checked against |
| `heldItems` | integer | Items still queued from the current one on, it included. For `held`, exactly what a resume picks up |
| `detail` | string \| null | Why, for `held` and `inconsistent`; `null` otherwise |
| `phaseRail` | object \| null | Where the run is inside the pipeline — see [The phase rail](#the-phase-rail) |

The four states:

| `state` | Meaning |
|---|---|
| `idle` | Nothing running, nothing queued. A run can be started |
| `running` | An item is in flight. `POST /v1/runs` will refuse with 409 until it ends |
| `held` | A paused queue with items left — [`POST /v1/autopilot/resume`](#post-v1autopilotresume) picks them up. Not a fault |
| `inconsistent` | The autopilot's `status` claims a run with **none behind it**. A stale claim, not a run — see below |

`running` is derived from the **same check** that decides whether `POST /v1/runs`
refuses, so the two can never disagree: if `running` is true a run request gets a
409, and if it is false the request is judged on its own merits. That is the
point of the block — a status that could disagree with the guard is the failure
it exists to replace, not a second opinion about it.

**`inconsistent` is reported rather than smoothed over.** It means the autopilot
reads busy while nothing is running — the state that had a project refusing every
item with 409 and no run to wait for. It is not fatal and needs no repair call:
**the read that reports it clears it**, after answering, so the next read (and
the fleet's next look, and a run request) finds the slot free — as does posting a
run, or reopening the project. A project driven unattended used to sit in this
state for a day: no run was ever posted by hand, and the run's own watchdog had
gone with the run loop that carried it. Reporting it as `idle` would hide the
thing an operator most needs to see, and reporting it as `running` would send
them looking for a run that does not exist. `status` and `detail` say what the
stale claim was, and the run log says it was cleared and by which read.

```bash
# Is it stuck, or actually working?
curl -s -H "$H" "$B/autopilot?project=kiteloop" | jq '.run'
```

**Status:** 200 · 400 (missing `?project=`) · 401 · 409 (project not open).

#### The phase rail

`phaseRail` is where a `running`/`reviewing` run sits inside the worker → verify
→ review → waitingForGate → merge → gate pipeline, read off the same
`BacklogAutopilot.RunPhase` line the run log writes. It is `null` while `state`
isn't `running`, and also in the gap between pickup and the item's first phase
landing.

| Field | Type | Notes |
|---|---|---|
| `currentStep` | string | One of `worker`, `verify`, `review`, `waitingForGate`, `merge`, `gate` — the step this run is on right now. `waitingForGate` is a merge queued behind another merge on the same project: only one merge gate runs per project at a time, and a run that is waiting for its turn has not started verifying anything yet |
| `stepsDone` | string[] | Every step before `currentStep`, in pipeline order. `verify` is `currentStep` for as long as Kiteloop is running the item's own `verify:` itself — the check that stands between the work and the reviewer, and a build that can take the whole of the verify deadline. An item declaring no `verify:` never reaches that phase, and its `verify` step reads done the moment `review` (or anything after it) becomes current; `waitingForGate` reads done for a merge that never had to wait, for the same reason |
| `attempt` | integer | The worker/reviewer round the current step belongs to |
| `lastOutputAgeSeconds` | number | Seconds since the run last did anything recordable — the same clock the stall watchdog compares against its own `stallTimeoutMinutes` |
| `warnAtSeconds` | number | Half of `stallTimeoutMinutes`, in seconds. Past this, `lastOutputAgeSeconds` is a run worth a look, well ahead of the watchdog actually ending it |

This is the same derivation the fleet board's state cell and the Autopilot
tab's in-flight row both draw from (`PortfolioSnapshot.RunState.PhaseRail`) —
neither surface can disagree with the other, or with this endpoint, about
where a run is.

```bash
curl -s -H "$H" "$B/autopilot?project=kiteloop" \
  | jq '.run.phaseRail | "\(.currentStep) · attempt \(.attempt) · \(.lastOutputAgeSeconds)s ago"'
```

---

### PUT /v1/autopilot

Sets the project's autopilot configuration. Every field except `project` is
optional — omitted fields are left unchanged. Changes persist to the project's
autopilot config, exactly as if set in the Autopilot UI.

| Field | Type | Notes |
|---|---|---|
| `project` | string | **Required** |
| `worker` | string | Agent **id or name**; 400 if no agent matches |
| `reviewer` | string \| null | Agent **id or name**; 400 if no agent matches. `null` or `""` clears it — no separate reviewer, the settings page's **No separate reviewer** |
| `coordinator` | string \| null | **Deprecated, ignored** — the per-project persona picker retired; tolerated so old callers keep working, absent from `GET` |
| `autonomy` | string | `"off"` \| `"propose"` \| `"land"` — see [The autonomy dial](#the-autonomy-dial). Sets `autonomousWorkEnabled` and `approvalGate` together; wins over both |
| `approvalGate` | string | `"propose"` \| `"land"` (default `"propose"`) — what happens to a run the reviewer passed: `propose` parks it at the approval gate and a person's approval does not merge; `land` approves it without a person and merges it. Independent of `autonomousWorkEnabled`. 400 on any other value. See [The autonomy dial](#the-autonomy-dial) |
| `useWorktree` | bool | **Retired, ignored** — worktree isolation is not a setting: a project whose root is a git repository always runs its items in a worktree, and a plain directory runs in the live tree, saying why in the run log. Tolerated, whatever it holds, so old callers keep working, and absent from `GET`. A config file that still holds the key loads as before and ignores it. Model: [`worktree-isolation.md`](worktree-isolation.md) |
| `maxRetries` | int | Worker/reviewer rounds one item gets in a run — the Autopilot tab's **Review rounds** stepper, clamped to `1…10` (default `3`). A reviewer still sending the work back after the last round ends the run rather than looping. Not the across-runs retry ceiling on items that produce nothing |
| `stallTimeoutMinutes` | int | **Deprecated, ignored** — no longer a setting; tolerated so old callers keep working, and answered with the derived value. See [The two timeouts are derived, not set](#the-two-timeouts-are-derived-not-set) |
| `refuteRoundEnabled` | bool | **Retired, ignored** — the refute round was removed, and a rejecting review goes straight back to the worker; tolerated, whatever it holds, so old callers keep working, and absent from `GET`. A config file that still holds the key loads as before and ignores it |
| `budgetUSD` | number \| null | **This project's one budget** — most it may spend in one local day, and the hard stop that pauses autopilot for the rest of a sitting once spent ([`GET`](#get-v1autopilot) reports the spend). Must be positive, or `null` to clear it (400 otherwise). Not the portfolio ceiling — that is [`PUT /v1/coordinator/scheduling`](#put-v1coordinatorscheduling). See [The one budget](#the-one-budget) |
| `autoMergeOnApproval` | bool | **Deprecated in favour of `approvalGate`**, read for one release: with `approveReviewPassedRuns`, mapped onto the gate — `land` when both end up `true`, `propose` otherwise (see [The autonomy dial](#the-autonomy-dial)) |
| `autoMergeVerifyCommand` | string \| null | **Retired, ignored** — no longer a setting: the merge gate runs the verify map's rules, and a rule matching every path (`"glob": "**"`) is what this was. Tolerated so old callers keep working, and absent from `GET`. A value an earlier release stored still runs for this release while the map has no such rule, and the autopilot log names the rule to add |
| `autoMergeVerifyTimeoutMinutes` | int | **Deprecated, ignored** — no longer a setting; tolerated so old callers keep working, and answered with the derived value. See [The two timeouts are derived, not set](#the-two-timeouts-are-derived-not-set) |
| `runTimeoutSource` | object | **Read-only.** Where each of the two clocks above came from — `{"worker": "derived", "gate": "default"}`. Each is `derived` once five of this project's runs carry that phase's duration, `default` until then; the two are counted separately |
| `workerMaxTurns` | int | **Read-only.** How many turns the worker may take on one item — its workflow node's `maxTurns` and its Claude Code session's `--max-turns`. This project's p95 worker turn count plus half again, rounded up, floored at 50 and capped at 150; 50 until five of its runs carry a turn count. Not a setting: a `PUT` naming it is ignored |
| `workerMaxTurnsSource` | string | **Read-only.** Where `workerMaxTurns` came from — `derived` once five of this project's runs carry a worker turn count, `default` until then |
| `itemCostCapUSD` | number \| null | **Read-only.** The per-item cost ceiling this project's runs imply — their p95 cost plus half again, never below an item's own predicted cost. `null` until five of its runs carry a cost; each item is then capped at its predicted cost plus half again. Not a setting: a `PUT` naming it is ignored |
| `itemCostCapSource` | string | **Read-only.** Where `itemCostCapUSD` came from — `derived` once five of this project's runs carry a cost, `default` until then |
| `worktreeSetupCommand` | string \| null | Run once in a fresh worktree, right after it is checked out and before anything else touches it — dependency installs, code generation (`npm ci`, `xcodegen generate`). Runs on both the worker's own worktree and the merge gate's scratch tree, wrapped the same way a verify step is (builds redirected to that tree's own DerivedData); never retried. Send `null` to clear (default `null` = nothing runs beyond today's behaviour) |
| `effectiveAutoMergeVerifyCommand` | string \| null | **Read-only.** What the merge gate actually runs beside the item's `verify:` — a merge-verify command an earlier release stored, while the verify map has no rule matching every path; else the verify map's widest rule (the rule whose glob matches the most of the tree, ties to the longest command); `null` when neither says anything |
| `autoMergeVerifyCommandSource` | string | **Read-only.** Where that came from: `configured` (the stored command), or `from verify-map rule \`<glob>\``, or why there is none (`no verify map`) |
| `effectiveWorktreeSetupCommand` | string \| null | **Read-only.** What a fresh worktree runs first — `worktreeSetupCommand` when set, else what the tree implies: `npm ci` beside a `package-lock.json`, `pnpm install --frozen-lockfile` beside a pnpm lockfile, `yarn install --frozen-lockfile` beside a yarn lockfile, `pod install` beside a `Podfile.lock`, `xcodegen generate` beside a `project.yml` whose `.xcodeproj` is absent or gitignored — one step per directory, each in its own subshell; `null` when nothing |
| `worktreeSetupCommandSource` | string | **Read-only.** Where that came from: `configured`, or the lockfiles and generators it was read from (`from a package-lock under apps/web, …`), or `nothing to set up — …` |
| `baseBranch` | string \| null | The **local** branch runs fork from, read their diff against, land on and open pull requests against — the Autopilot tab's **Base branch** field (default `null` = the checkout's own `HEAD`, which is how every run behaved before). Send `null` or `""` to clear. A name no local branch has refuses the next run at start; a base checked out in another worktree refuses the merge, naming it. Never fetches. Model: [`worktree-isolation.md`](worktree-isolation.md#which-branch-is-the-work) |
| `openPullRequest` | bool | Push the item's branch, open a GitHub pull request for a run that reaches the approval gate, and follow its checks until they are green (default `false`). Never merges — see [Pull requests](#pull-requests) |
| `approveReviewPassedRuns` | bool | **Deprecated in favour of `approvalGate`**, read for one release: with `autoMergeOnApproval`, mapped onto the gate — `land` when both end up `true`, `propose` otherwise. Rejected and blocked runs route exactly as they do today — see [Approving without asking](#approving-without-asking) |
| `autonomousWorkEnabled` | bool | **Deprecated in favour of `autonomy`; still settable on its own.** This project's consent to unattended work (default `false`) |
| `protectedPaths` | array of strings | **Retired, ignored** — protected paths are no longer a setting; the repository's own guards (the verify map, the diff rules, stray-work detection) are where path rules live. Tolerated, whatever it holds, so old callers keep working, and absent from `GET`. A config file that still holds the key loads as before and ignores it |

```bash
curl -s -H "$H" -X PUT \
  -d '{"project":"kiteloop","worker":"Builder","reviewer":"Reviewer"}' \
  $B/autopilot
```

`worker`, `reviewer` and `coordinator` each accept an agent **id or a name** — the
name you hired the agent under (`POST /v1/agents`, or whatever the Agents sidebar
shows), matched exactly and only against agents in *this* project. Names are
resolved to ids before anything is written, so a body naming one known and one
unknown agent changes **nothing**: it's a 400 and the previous assignment stands.
The response reports ids, so a read-back is stable even if an agent is renamed.

The response echoes the **full** resulting configuration:

```json
{
  "project": "kiteloop",
  "worker": "6B1F…",
  "reviewer": "9C42…",
  "autonomy": "off",
  "approvalGate": "propose",
  "maxRetries": 3,
  "stallTimeoutMinutes": 20,
  "budgetUSD": 25,
  "autoMergeOnApproval": false,
  "autoMergeVerifyTimeoutMinutes": 30,
  "runTimeoutSource": {"worker": "default", "gate": "default"},
  "workerMaxTurns": 50,
  "workerMaxTurnsSource": "default",
  "itemCostCapUSD": null,
  "itemCostCapSource": "default",
  "worktreeSetupCommand": null,
  "effectiveAutoMergeVerifyCommand": "./scripts/ci-local.sh",
  "autoMergeVerifyCommandSource": "from verify-map rule `apps/api/**`",
  "effectiveWorktreeSetupCommand": null,
  "worktreeSetupCommandSource": "nothing to set up — no lockfile or generator in the tree",
  "baseBranch": null,
  "openPullRequest": false,
  "approveReviewPassedRuns": false,
  "autonomousWorkEnabled": false
}
```

**Status:** 200 · 400 (missing `project`; unresolvable
`worker`/`reviewer`; `budgetUSD` not a positive number or
`null`; an `autonomy` other than `off`/`propose`/`land`) · 401 · 409 (project not open).

---

### POST /v1/autopilot/reset

Puts the project's **budget and behaviour flags** back to their built-in
defaults — the way out of a session where a driver tuned the knobs and can no longer
tell what was changed. It is a **configuration** reset: it never touches a run, the
queue or an item — a stuck run is ended with
[`POST /v1/runs/{runId}/cancel`](#post-v1runsrunidcancel). The `worker`/`reviewer` assignment is **kept**, so autopilot
stays runnable; re-assign agents with `PUT /v1/autopilot` instead.

| Field | Type | Notes |
|---|---|---|
| `project` | string | **Required** |

Reset to:

| Setting | Default |
|---|---|
| `autonomy` | `off` (`autonomousWorkEnabled` clear, `approvalGate` at `propose`) |
| `maxRetries` | `3` |
| `budgetUSD` | `null` (no ceiling of its own) |
| `worktreeSetupCommand` | `null` |
| `baseBranch` | `null` (the checkout's own `HEAD`) |
| `openPullRequest` | `false` |
| `approvalGate` | `propose` |

The `worker` and `reviewer` assignments are **not** reset — putting the knobs
back isn't disbanding the team.

```bash
curl -s -H "$H" -d '{"project":"kiteloop"}' $B/autopilot/reset
```

The response echoes the **full** resulting configuration, same shape as `GET`/`PUT`:

```json
{
  "project": "kiteloop",
  "worker": "6B1F…",
  "reviewer": "9C42…",
  "autonomy": "off",
  "approvalGate": "propose",
  "maxRetries": 3,
  "stallTimeoutMinutes": 20,
  "budgetUSD": null,
  "autoMergeOnApproval": false,
  "autoMergeVerifyTimeoutMinutes": 30,
  "runTimeoutSource": {"worker": "default", "gate": "default"},
  "workerMaxTurns": 50,
  "workerMaxTurnsSource": "default",
  "itemCostCapUSD": null,
  "itemCostCapSource": "default",
  "worktreeSetupCommand": null,
  "effectiveAutoMergeVerifyCommand": "./scripts/ci-local.sh",
  "autoMergeVerifyCommandSource": "from verify-map rule `apps/api/**`",
  "effectiveWorktreeSetupCommand": null,
  "worktreeSetupCommandSource": "nothing to set up — no lockfile or generator in the tree",
  "baseBranch": null,
  "openPullRequest": false,
  "approveReviewPassedRuns": false,
  "autonomousWorkEnabled": false
}
```

The new values are persisted, so they survive a relaunch. The **portfolio-wide**
daily budget is deliberately not among them: it isn't this project's setting, and
a per-project reset must not be able to clear the number that bounds the whole
bill. Clear that one with `{"dailyBudgetUSD": null}` on
[`PUT /v1/coordinator/scheduling`](#put-v1coordinatorscheduling).

**Status:** 200 · 400 (missing `project`) · 401 · 409 (project not open, or autopilot
is not idle — the caps are enforced against the running item, so they can't be cleared
out from under it; the refusal says so and names
[`POST /v1/runs/{runId}/cancel`](#post-v1runsrunidcancel), because **reset changes
the configuration, never the run** — reaching for it to clear a stuck run wipes the
project's autonomy, budget and verify command and leaves the run exactly where it was).

---

### POST /v1/autopilot/pause

Holds the project's queue — the headless equivalent of the pause button in the
Autopilot tab. **The item in flight is not interrupted:** the pause lands at the next
item boundary, so the run already started still reaches its gate. To abandon a run
mid-item, use [`POST /v1/runs/{runId}/cancel`](#post-v1runsrunidcancel).

The hold outlives that run. Once the item in flight reaches its gate and the run
loop ends, the project is still paused — [`GET /v1/autopilot`](#get-v1autopilot)
and [`GET /v1/projects`](#get-v1projects) both keep reading `paused: true`, and
only [`POST /v1/autopilot/resume`](#post-v1autopilotresume) lifts it. (Stopping
instead of resuming ends the hold along with the queue it was over.)

Pausing is one act: once this project is paused, [`POST /v1/runs`](#post-v1runs)
refuses **409** for it — naming this call — and so does a human pressing **Run** in
the Autopilot tab. The Planner's refill and the autonomous run scheduler skip a
paused project the same way they already skip one parked with the paused switch on
the fleet board; [`GET /v1/projects`](#get-v1projects) reports `paused: true` for
either cause.

| Field | Type | Notes |
|---|---|---|
| `project` | string | **Required** |

```bash
curl -s -H "$H" -d '{"project":"kiteloop"}' $B/autopilot/pause
```

```json
{ "project": "kiteloop", "autopilot": "paused" }
```

Pausing an **already paused** autopilot is a no-op that still answers 200 — a driver
retrying after a dropped connection can't tell whether its first request landed.

**Status:** 200 · 400 (missing `project`) · 401 · 409 (project not open, or autopilot
is idle — there is no queue to hold).

---

### POST /v1/autopilot/resume

Lifts a pause, whichever way it was taken. Pausing is one act — the human's paused
switch on the fleet board reads the same as
[`POST /v1/autopilot/pause`](#post-v1autopilotpause) — so this lifts whichever of
the two, or both, are holding the project.

| Field | Type | Notes |
|---|---|---|
| `project` | string | **Required** |

```bash
curl -s -H "$H" -d '{"project":"kiteloop"}' $B/autopilot/resume
```

```json
{ "project": "kiteloop", "autopilot": "resuming", "resumed": "autopilot" }
```

A project held **only** by the fleet board's switch has no queue to pick back up:
the switch is cleared and this answers **200** with `"resumed": "paused"`
instead, `autopilot` left at `idle`. Any case where the autopilot itself was
paused — with or without that switch alongside it — still answers **202**
immediately and runs the remaining items in the background; `resumed` reads
`"autopilot"` or `"both"`. `resuming` is a transitional value specific to that
response, not one of the autopilot statuses — poll `GET /v1/runs/{runId}` for the
live `autopilot` state (`idle`, `running`, `reviewing`, `paused`).

The project must be paused one way or the other; the 409 names the state the
caller is actually in, e.g. `Autopilot is not paused for this project (status:
idle)`.

If the queue is held by a **spent session cost cap**, this is what opens a fresh
session budget: `sessionSpendUSD` goes back to `0` and the held items are picked
up, with the closed session's total recorded in the autopilot's log. That reset
is deliberate and deliberately here — asking a paused queue to keep going is a
person deciding the sitting continues, and starting another run does **not** clear
the ledger, so nothing else would. A pause for any other reason (the operator, the
circuit breaker, a [quiesce](#post-v1fleetquiesce)) resumes on the spend it had.
To keep the same session and give it more room, raise `budgetUSD` with
[`PUT /v1/autopilot`](#put-v1autopilot) instead.

**Status:** 200 (paused switch cleared, nothing to resume) · 202 (resuming) · 400
(missing `project`) · 401 · 409 (project not open, or not paused either way).

---

### GET /v1/fleet/quiesce

Where the whole fleet is, in one answer — whether new work is being refused, and how
many runs are still finishing. This replaces polling
[`GET /v1/projects`](#get-v1projects) and reading `run.running` off every entry.

A restart strands nothing exactly when **`quiesced` and `drained` are both true.**

Read-only: it starts nothing, stops nothing, and does not hold the fleet.

**In the app this is "Pause fleet"** — the sidebar's Pause · Fleet control, whose state
line reads "pausing — N run(s) finishing" and then "paused — all quiet". The endpoint,
its fields and their values keep the `quiesce`/`drained` spelling: that is what scripts
read, and it is not changing.

```bash
curl -s -H "$H" $B/fleet/quiesce
```

```json
{
  "quiesced": true,
  "drained": false,
  "running": 1,
  "summary": "quiesced, 1 run(s) still finishing",
  "projects": [
    { "id": "/Users/me/code/kiteloop", "name": "kiteloop", "status": "paused",
      "state": "running", "running": true, "item": "some-item", "heldItems": 3,
      "heldByQuiesce": true, "action": null }
  ]
}
```

| Field | Notes |
|---|---|
| `quiesced` | New work is being refused fleet-wide |
| `drained` | No run in flight anywhere |
| `running` | Projects with a run still finishing |
| `state` | The derived phase (`idle`, `running`, `held`, `inconsistent`) — read from the same check the run guard makes, so this and `GET /v1/projects` cannot disagree |
| `heldByQuiesce` | Whether [`POST /v1/fleet/resume`](#post-v1fleetresume) will pick this project up |
| `action` | What the quiesce did to it — on that call's reply only, `null` here |

**Status:** 200 · 401.

---

### POST /v1/fleet/quiesce

Stops the fleet taking new work, holds every queue that is advancing, and — with
`waitSeconds` — returns only once the last in-flight run has finished. This is the
call to make before quitting the app.

The same verb the sidebar calls **"Pause fleet"** (and the quit dialog offers as "Pause
the Fleet and Quit When It's Quiet"). Distinct from
[`POST /v1/autopilot/pause`](#post-v1autopilotpause), which holds one project's queue
rather than every open project's.

**The gate is what makes it work for the whole fleet.** A per-project pause already
refuses [`POST /v1/runs`](#post-v1runs) with 409 for that one project — see
[`POST /v1/autopilot/pause`](#post-v1autopilotpause). Quiescing is the fleet-wide
version of the same refusal, so a restart doesn't require pausing every project by
hand first. So while the fleet is quiesced:

- `POST /v1/runs` is refused with **409**, and
- the autonomous scheduler holds with `quiesced` (distinct from `disabled` — nobody
  touched the kill switch, and it picks up again when the hold is lifted).

Runs already in flight are **not** interrupted; they finish at their own gate, which
is what makes a restart after this cost nothing. To abandon one mid-item, use
[`POST /v1/runs/{runId}/cancel`](#post-v1runsrunidcancel).

| Field | Type | Default | Notes |
|---|---|---|---|
| `waitSeconds` | number | `0` | Wait up to this long for the last run to finish. `0…600`. Omitted answers immediately |

```bash
# hold the fleet and wait up to 10 minutes for it to drain
curl -s -H "$H" -d '{"waitSeconds":600}' $B/fleet/quiesce
```

```json
{
  "quiesced": true,
  "drained": true,
  "running": 0,
  "summary": "quiesced, drained",
  "projects": [
    { "name": "kiteloop", "action": "held", "heldByQuiesce": true, "heldItems": 3, "…": "…" },
    { "name": "kiu", "action": "idle", "heldByQuiesce": false, "heldItems": 0, "…": "…" }
  ]
}
```

`action` says what happened to each project:

| Value | Meaning |
|---|---|
| `held` | This call paused it. It is in the ledger, so `resume` picks it back up |
| `alreadyHeld` | Already paused when the call arrived — left alone, and left **out** of the ledger, so resuming won't start a queue you were holding for your own reasons |
| `idle` | Nothing to hold. Pausing an idle autopilot would manufacture a queue nobody can start; the gate is what stops an idle project taking new work |

A wait that runs out is still a **200**, carrying `drained: false` and a count of what
is left — a true answer to a bounded question. It never reports `drained` on a
timeout: that is the restart that strands an item. Wait again, or cancel the run.

Idempotent — a retry after a dropped connection adds nothing to the ledger.

**Not persisted.** A restart clears the hold and leaves every autopilot idle, which is
the state a restart is for. A quiesce that survived one would leave the fleet silently
refusing work after a crash.

**Status:** 200 · 400 (body isn't a JSON object, or `waitSeconds` is out of `0…600`) · 401.

---

### POST /v1/fleet/resume

Lifts the hold and picks back up exactly the queues the quiesce paused — never one
that was already paused when it arrived.

```bash
curl -s -X POST -H "$H" $B/fleet/resume
```

```json
{
  "quiesced": false,
  "drained": true,
  "running": 0,
  "summary": "not quiesced, drained",
  "resumed": ["kiteloop"],
  "skipped": [],
  "projects": ["…"]
}
```

The body is a [fleet reading](#get-v1fleetquiesce) plus `resumed` and `skipped`.

A ledgered project that is no longer paused is reported under `skipped` with the
reason rather than counted as resumed. **After the restart the quiesce was taken for,
that is all of them** — the ledger lives in memory and the autopilots come back idle,
so resume never depends on state the restart destroyed. An empty `resumed` is a
success, not an error.

Resuming goes through the same per-project `resume`, so a queue that cannot be
continued — a spent session cost cap — is **released** rather than left held. Nothing
is left holding a queue it cannot start.

**Status:** 200 · 401.

### GET /v1/usage

How close the agents are to their **rate limit**, and where the **last day's
spend** went — what the phone's Fleet screen shows under Usage.

```bash
curl -s -H "$H" $B/usage
```

```json
{
  "rateLimit": { "status": "allowed_warning", "window": "five_hour", "resetsAt": "2026-10-27T14:00:00Z", "utilization": 0.9 },
  "agentsReporting": 2,
  "spend": {
    "hours": 24,
    "totalUSD": 6.4,
    "projects": [ { "project": "kiteloop", "spendUSD": 5.1 }, { "project": "travel", "spendUSD": 1.3 } ],
    "omittedProjects": []
  }
}
```

| Field | Meaning |
|---|---|
| `rateLimit` | Of the readings every open project's agents last reported (the CLI's `rate_limit_event`), the one closest to its limit: a refusal (`rejected`) first, then any other warning, then the highest `utilization`. `null` when no agent has reported one since the app started |
| `agentsReporting` | How many agents' readings that was chosen from |
| `spend` | The last 24 hours — the day the shared daily budget covers — per project, busiest first, from the same report as [`GET /v1/report`](#get-v1report), capped as it is, with the rest named in `omittedProjects`. On a subscription these are token-equivalent dollars. `null` on a build that keeps no metrics |

**Status:** 200

---

### GET /v1/memory/proposals

A project's **pending** memory proposals — an agent's own `propose_memory` call,
or a fact the librarian pass wants merged, deleted or archived. This is the same
list the Memory tab's pending section shows a person; before this endpoint it had
exactly one reader, so a proposal filed during an unattended run sat invisible
until someone opened that tab. Read-only: nothing here approves, rejects or edits
a proposal.

| Query | Required | Notes |
|---|---|---|
| `project` | yes | Path or folder name |

```bash
curl -s -H "$H" "$B/memory/proposals?project=kiteloop"
```

```json
{
  "project": "kiteloop",
  "count": 2,
  "proposals": [
    {
      "id": "3F2A1B7C-9E4D-4A1C-8B3E-1D2C3B4A5E6F",
      "agent": "builder",
      "status": "pending",
      "source": "agent",
      "operation": "add",
      "content": "The build script lives at scripts/make-release.sh.",
      "rationale": null,
      "evidence": null,
      "timestamp": "2026-08-19T22:14:09Z"
    },
    {
      "id": "9C8B7A65-4321-4E5F-9A8B-7C6D5E4F3A2B",
      "agent": "builder",
      "status": "pending",
      "source": "librarian",
      "operation": "delete",
      "topics": ["legacy-deploy-path"],
      "content": "The old deploy path no longer exists.",
      "rationale": "Contradicted by the current deploy script.",
      "evidence": "scripts/make-release.sh no longer references it.",
      "timestamp": "2026-08-20T01:02:03Z"
    }
  ]
}
```

| Field | Notes |
|---|---|
| `agent` | The agent id the proposal is filed against |
| `status` | Always `"pending"` — an approved or rejected proposal is not reported here, the same set `MemoryManager.pendingProposals()` holds |
| `source` | `"agent"` for an agent's own `propose_memory` call, `"librarian"` for a consolidation pass over the corpus |
| `operation` | What approving the proposal would do to the index: `"add"`, `"merge"`, `"delete"` or `"archive"` |
| `topics` | The fact names a `merge`, `delete` or `archive` acts on. **Omitted for `add`**, which acts on none |
| `content` | The proposed fact text. For `delete`/`archive` this is the reason, not new content |
| `rationale` | Why this is being proposed, in the proposer's own words, or `null` |
| `evidence` | What contradicts the fact a `delete` removes, or `null` for every other operation |

A project with no pending proposals answers with an empty `proposals` array
rather than an error.

**Status:** 200 · 400 (missing `?project=`) · 401 · 409 (project not open).

---

### POST /v1/memory/proposals/approve

Applies a pending proposal's operation to the agent's memory — adds the fact,
merges the named ones, deletes or archives one — and marks the proposal approved.
The same button the Memory tab offers a person, pressed remotely; before this,
that button was `MemoryManager.approve`'s only caller, so a proposal filed during
an unattended run could never be answered and the index could never accumulate a
fact. This is an operator answering from somewhere else, not a loop that approves
its own memory.

| Field | Type | Notes |
|---|---|---|
| `project` | string | **Required**. Path or folder name |
| `id` | string | **Required**. The proposal id, as `GET /v1/memory/proposals` reports it |

```bash
curl -s -H "$H" -d "{\"project\":\"kiteloop\",\"id\":\"3F2A1B7C-9E4D-4A1C-8B3E-1D2C3B4A5E6F\"}" \
  $B/memory/proposals/approve
```

```json
{
  "project": "kiteloop",
  "id": "3F2A1B7C-9E4D-4A1C-8B3E-1D2C3B4A5E6F",
  "agent": "builder",
  "operation": "add",
  "status": "approved"
}
```

Only a **pending** proposal can be answered, so approving the same id twice is a
404 rather than a second write.

**A refusal stays a refusal.** The fact is written before the proposal is marked,
so a write the index turns away — the 50-fact cap reached, or the fact already
covered by one in the index — changes nothing and answers **422** carrying the
index's own reason. The proposal is still pending afterwards, for a human to edit
and approve again; this is the same sentence the Memory tab shows on the card.

```json
{
  "error": "Memory not written — already covered by an existing fact: The release script lives at scripts/make-release.sh. [release-script-lives-at]. Say something the index does not, or write `supersedes: release-script-lives-at` to replace it."
}
```

**Status:** 200 · 400 (body missing `project` or `id`) · 401 · 404 (no pending
proposal with that id) · 409 (project not open) · 422 (the index refused the
write; nothing changed).

---

### POST /v1/memory/proposals/reject

Marks the proposal rejected and takes it off the pending list, without touching
the agent's memory — the Memory tab's Reject button, pressed remotely. Takes the
same `project` and `id` as `approve` and answers the same shape, with
`"status": "rejected"`.

```bash
curl -s -H "$H" -d "{\"project\":\"kiteloop\",\"id\":\"3F2A1B7C-9E4D-4A1C-8B3E-1D2C3B4A5E6F\"}" \
  $B/memory/proposals/reject
```

Rejecting the same id twice is a 404. The status is written to the proposal's own
JSON before it is reported, so a write that did not land answers 422 with the
reason rather than a 200 the next launch would contradict.

**Status:** 200 · 400 (body missing `project` or `id`) · 401 · 404 (no pending
proposal with that id) · 409 (project not open) · 422 (the status could not be
written; the proposal is still pending).

---

### GET /v1/agents

The project's agents — everyone hired, whether or not they have spoken yet.
The `id` is what the message and transcript endpoints take, though both accept
the name too.

```bash
curl -s -H "$H" "$B/agents?project=kiteloop"
```

```json
{"agents": [{"id": "…", "name": "Planner", "model": "opus", "state": "idle"}]}
```

`state` is `idle`, `working` or `waitingForHuman` — the agent asked a question (`ask_human`) that has not been answered yet.

**Status:** 200 · 400 (missing `project`) · 409 (project not open)

### POST /v1/agents/message

Delivers a message into the agent's chat session exactly as if typed there —
same transcript, same tool handling, and the Mac's chat window shows it — and
answers as soon as the message is in: `started: true` when the agent was idle
and its turn has begun, `queued: true` when it was mid-turn and the message
waits its turn. `after` is the id of the chat's last message before this one:
open [`GET /v1/agents/events`](#get-v1agentsevents) with it to follow the
reply as it streams.

```bash
curl -s -H "$H" -d '{"project":"kiteloop","agent":"Planner","message":"status?"}' $B/agents/message
```

| Field | Type | Meaning |
|---|---|---|
| `project` | string | Project identifier. Required |
| `agent` | string | Agent id or name. Required |
| `message` | string | What to say. Required, non-empty |
| `wait` | bool | Answer only when the agent's turn ends, with its reply. Default false |
| `attachments` | array | Images sent with the message — `{"filename", "mediaType", "data"}`, the data base64 — as files dropped on the Mac's input. PNG, JPEG, GIF or WebP; `message` may be empty when they carry it |

```json
{"agent": "…", "queued": false, "started": true, "after": "…last message id…"}
```

With `"wait": true` the call holds the connection open until the agent
finishes — a turn can take minutes — and answers with the reply text, as it
did before the events stream existed:

```json
{"agent": "…", "queued": false, "reply": "…the agent's answer…"}
```

An agent mid-turn still answers `queued: true` at once under `wait`.

The whole body is capped at 2 MB, so a photo goes as a JPEG scaled to the
1568-pixel long edge a model looks at — the phone does this before sending.

**Status:** 200 · 400 (missing `project`/`agent`, or neither a message nor an
image) · 404 (no such agent) · 409 (project not open) · 413 (an image over
5 MB, or a body over 2 MB) · 415 (an attachment that is not an image)

### GET /v1/agents/transcript

The agent's conversation, flattened to what a phone can render and returned
oldest first. Tool traffic collapses to the tool's name and one line of what it was
pointed at — `Bash — Show working tree status`, `Edit — Services/Foo.swift`,
`Grep — func runSetupCommand` — never the raw input; approvals, images and
raw tool results are elided — this is the conversation, not the machinery.

```bash
curl -s -H "$H" "$B/agents/transcript?project=kiteloop&agent=Planner&limit=80"
```

| Query | Meaning |
|---|---|
| `project` | Project identifier. Required |
| `agent` | Agent id or name. Required |
| `limit` | Newest messages to return; default 50 |

```json
{"agent": "…", "messages": [
  {"id": "…", "sender": "you", "kind": "text", "text": "status?", "at": "2026-08-24T09:00:00Z"},
  {"id": "…", "sender": "Planner", "kind": "text", "text": "…", "at": "2026-08-24T09:00:41Z"}]}
```

`kind` is `text`, `thinking`, `tool`, `error`, `system`, `plan` or
`question`. A `plan` is a Plan-mode agent's plan card and carries
`"plan": {"open": true}` until answered, then `"answer"` too
(`approveAuto`, `approveAcceptEdits` or `keepPlanning`); answer it with
[`POST /v1/agents/plan`](#post-v1agentsplan). A `question` is one an agent
stopped to ask (`ask_human`) and carries `"question": {"request": "…",
"open": true}`; answer it with [`POST /v1/agents/answer`](#post-v1agentsanswer).
A file tool's `tool` message (Read, Edit, Write, MultiEdit, NotebookEdit)
also carries `path`, the whole path it touched — the one-line `text` keeps only
its last two components — for [`GET /v1/workspace/file`](#get-v1workspacefile).
An agent that has never chatted answers an empty list, not an error.

**Status:** 200 · 400 (missing `project`/`agent`) · 404 (no such agent) ·
409 (project not open)

### GET /v1/agents/events

The agent's chat as it happens, as Server-Sent Events. Each frame's data is
one JSON object:

```json
{"type": "state", "agent": "…", "working": true}
{"type": "message", "agent": "…", "message": {"id": "…", "sender": "Planner", "kind": "text", "text": "Found it: the", "at": "…"}}
{"type": "message", "agent": "…", "message": {"id": "…", "sender": "Planner", "kind": "text", "text": "Found it: the refund rounds…", "at": "…"}}
```

A `message` event carries a transcript message, the same shape
[`GET /v1/agents/transcript`](#get-v1agentstranscript) answers, each time it
is new or changes — a reply still streaming arrives again under the same id,
so replace by `id` rather than append. A `state` event says the agent started
or finished a turn, and goes out first on every connection. The stream wakes
on the chat's own changes, not on a clock; a `: keepalive` comment goes out
every 15s so an idle stream does not look dead.

```bash
curl -N -H "$H" "$B/agents/events?project=kiteloop&agent=Planner&after=<id>"
```

| Query | Meaning |
|---|---|
| `project` | Project identifier. Required |
| `agent` | Agent id or name. Required |
| `after` | The last message id the client holds: everything after it is sent at once. An id the chat does not hold sends the whole window again. Without it the stream starts from now |
| `limit` | Newest messages watched; default 50, the transcript's window |

The phone reads the transcript, then opens the stream with `after` set to
the last id it got; a dropped stream reopens with the last id it saw.

**Status:** 200 · 400 (missing `project`/`agent`) · 404 (no such agent) ·
409 (project not open)

### POST /v1/agents/interrupt

Stops the agent's running turn, as the Mac's Stop button does. Messages you
queued during the turn go back into the Mac's input box; `returned` carries
their text, so the phone can put it in its own draft too.

```bash
curl -s -H "$H" -d '{"project":"kiteloop","agent":"Builder"}' $B/agents/interrupt
```

```json
{"agent": "…", "interrupted": true, "returned": "and also check the refunds test"}
```

An agent with no turn running answers `"interrupted": false` and nothing
changes.

**Status:** 200 · 400 (missing `project`/`agent`) · 404 (no such agent) ·
409 (project not open)

### POST /v1/agents/plan

Answers a plan card — what its three buttons on the Mac do. `approveAuto` and
`approveAcceptEdits` switch the agent to that permission mode and tell it to
build; `keepPlanning` leaves it planning and sends `feedback`, if given, as
your message. Answered as soon as the card is; the build turn shows on the
events stream.

```bash
curl -s -H "$H" -d '{"project":"kiteloop","agent":"Planner","message":"<plan id>","answer":"approveAuto"}' $B/agents/plan
```

| Field | Type | Meaning |
|---|---|---|
| `project`, `agent` | string | Required |
| `message` | string | The plan message's `id` from the transcript. Required |
| `answer` | string | `approveAuto`, `approveAcceptEdits` or `keepPlanning`. Required |
| `feedback` | string | With `keepPlanning`: what should change |

**Status:** 200 · 400 (missing field, unknown answer) · 404 (no such agent) ·
409 (project not open, or no open plan with that id)

### POST /v1/agents/answer

Answers the question an agent stopped to ask (`ask_human`) — only the one it
is waiting on now — and its turn resumes. The question's `request` id is in
the transcript; the reply shows on the events stream.

```bash
curl -s -H "$H" -d '{"project":"kiteloop","agent":"Builder","request":"<request id>","answer":"Keep the old rounding"}' $B/agents/answer
```

**Status:** 200 · 400 (missing field, blank answer) · 404 (no such agent) ·
409 (project not open, or the agent is not waiting on that question)

### POST /v1/pair

How a phone gets its token. **Pair a phone** in Settings → Control API shows a
QR carrying a one-time `code` instead of a token; the phone posts it here, with
the name Settings should list it under, and gets back a token of its own:

```bash
curl -s -d '{"code":"<from the QR>","name":"My iPhone"}' $B/pair
```

```json
{ "token": "<the phone's bearer token>", "device": "6F1C…" }
```

A code pairs **one** phone, **once**, and only while the sheet that shows it is
open: closing the sheet withdraws it, a claim uses it up, and a relaunch forgets
every code on offer — so a photo of the QR is worth nothing once the sheet is
closed, and a sheet closed without a scan leaves no paired phone behind. The
sheet says which phone used its code. Needs no bearer token. On a Mac that keeps
no paired phones, the QR carries the control token as `token=` instead, as it did
before codes.

**Status:** 200 · 400 (no `code`) · 403 (the code is not on offer: used,
withdrawn or never shown) · 404 (this Mac keeps no paired phones)

### GET /v1/quick-replies

The replies kept under **Settings → Control API → Quick replies**, one per line
there, which the phone shows as chips above its chat composer: a tap sends one,
or puts it in the draft to queue while the agent is working.

```bash
curl -s -H "$H" $B/quick-replies
```

```json
{ "replies": ["Continue", "Yes, go ahead", "Run the tests"] }
```

Until the list is set it is those three starters; a list saved empty stays
empty, and the phone shows no chips.

**Status:** 200

### POST /v1/devices/push

The phone's APNs device token, kept in `~/.kiteloop/push-devices.json`
(readable by you only), so the Mac can push to it directly through Apple's
push service — no server in between. The Mac pushes when:

- an item reaches the approval gate (`kind: approval`, with `item`);
- an agent asks you something or has a plan ready (`kind: question`, with `agent`);
- a background project's agents finish, or a turn you started from the phone
  ends (`kind: finished`).

Every push carries `project` too, so the phone opens the right screen.

```bash
curl -s -H "$H" -d '{"token":"<hex>","environment":"production","name":"My iPhone"}' $B/devices/push
```

`environment` is `sandbox` for a build run from Xcode and `production` for a
TestFlight build. The same token again replaces its entry; one Apple says is
dead (410, or `BadDeviceToken`) is forgotten on the next push. Nothing is sent
until **Settings → Control API → Push to phones** holds an APNs key —
created at developer.apple.com → Certificates, Identifiers & Profiles → Keys
with Apple Push Notifications service enabled: the `.p8`, its key id and your
team id; until then `problem` says so.

**Status:** 200 · 400 (missing or non-hex token, unknown environment) · 503
(pushes not set up)

### POST /v1/devices/activity

The push token of the Live Activity the phone starts when it sends an agent a
message, so the lock screen follows the turn while the phone sleeps. The Mac
moves it on with live-activity pushes (`apns-push-type: liveactivity`): to
"Waiting for your answer" or "Plan ready for you" when the turn stops on one,
and ends it — kept on the lock screen for 15 minutes — when the turn finishes.
Held in memory for that one turn; the same push key as above signs it.

```bash
curl -s -H "$H" -d '{"token":"<hex>","environment":"production","project":"kiteloop","agent":"<agent id>"}' $B/devices/activity
```

**Status:** 200 · 400 (a missing field, non-hex token or unknown environment)

### GET /v1/workspace/changes

What an agent has changed in the project so far, before anything reaches a
gate: every changed or untracked file with its `git status --porcelain`
letters, and the patch against HEAD for the tracked ones, cut at 200,000
characters (the same cap as the gate's diff) with `truncated` saying so.

```bash
curl -s -H "$H" "$B/workspace/changes?project=kiteloop"
```

```json
{"files": [{"status": " M", "path": "src/refund.ts"}, {"status": "??", "path": "test/refund.test.ts"}],
 "patch": "diff --git a/src/refund.ts …", "truncated": false}
```

A clean tree answers an empty list. **Status:** 200 · 400 (missing
`project`) · 409 (project not open, or not a git repository) · 504 (git
timed out)

### GET /v1/workspace/file

One file or folder of the project, read-only. `path` is relative to the
project root (empty for the root itself), or absolute — what a tool message's
`path` carries — and held to the same check; a file answers
`{"kind": "file", "text"}`, a folder `{"kind": "directory", "entries": [{"name", "directory"}]}`.

```bash
curl -s -H "$H" "$B/workspace/file?project=kiteloop&path=src/refund.ts"
```

Refused: a path that leaves the project — `..`, or a symlink pointing out,
resolved before the check — anything under `.git`, and any file git ignores,
which is where `.env` files and keys live. **Status:** 200 · 400 · 403
(outside, `.git` or ignored) · 404 (no such file) · 409 (project not open) ·
413 (over 500,000 bytes) · 415 (not text)

### GET /v1/preview/screenshot

The Mac's web preview for the project as a PNG (`Content-Type: image/png`),
so UI work an agent does can be checked from the phone.

```bash
curl -s -H "$H" "$B/preview/screenshot?project=kiteloop" -o preview.png
```

**Status:** 200 · 400 · 409 (project not open, or no preview open for it)

### POST /v1/agents

Hires an agent into an open project — the headless equivalent of summoning one from
the sidebar.

| Field | Type | Default | Notes |
|---|---|---|---|
| `project` | string | — | **Required** |
| `name` | string | — | **Required**, non-empty |
| `model` | string | the project's model, else Settings → Default Model, else `"opus"` | Family alias (`opus`/`sonnet`/`haiku`), a pinned ID, or an Ollama model |
| `permissionMode` | string | the project's configured mode, `"auto"` unless set | Claude Code permission mode; defaults to the mode Project Settings gives new agents in that project |
| `systemPrompt` | string | built-in developer prompt | |
| `avatar` | string | none | Bundled avatar name |
| `tools` | string[] | built-in default tool set | |
| `select` | bool | `false` | Whether to switch the user's UI selection to the new agent |

```bash
curl -s -H "$H" \
  -d '{"project":"kiteloop","name":"Builder","model":"opus"}' \
  $B/agents
```

```json
{ "agentId": "6B1F…", "name": "Builder", "model": "opus" }
```

`select` defaults to `false` so a headless driver doesn't yank the human's current
view.

**Status:** 201 · 400 (missing `project`/`name`) · 401 · 409 (project not open).

---

### POST /v1/backlog/approve

Resolves a backlog item's human gate directly, without needing a run ID. This is
the path to use for a gate left behind by an earlier app run: a run record
survives a restart, but the run itself does not, and
`POST /v1/runs/{runId}/approve` resolves the gate a *live* run is holding.

Approving **merges the item's branch** when the project has `autoMergeOnApproval`,
on the same terms as the autopilot's own merge: a clean merge *and* a green verify
of the merged tree. The verify is the item's own `verify:` **and** the project's
merge-verify (`effectiveAutoMergeVerifyCommand`) — both of them, item's first, and every one must pass.
A project-level command is an addition to the item's verify, never a substitute
for it, so the last gate before `main` can't be weaker than the one the work was
built against. Only then does the item become `done`. Rejecting returns it to
`ready` and never merges; the reason is recorded as feedback for the next run —
written to the item's Notes, and opening the next run's worker and reviewer
prompt verbatim under a "Rejected last time" heading, alongside a ref naming
the rejected run's branch tip — until a run of the item passes review.

| Field | Type | Default | Notes |
|---|---|---|---|
| `project` | string | — | **Required** |
| `item` | string | — | **Required** (`itemId` also accepted) |
| `approve` | bool | `true` | `approved` also accepted |
| `reason` | string | `""` | Recorded as feedback on rejection |

```bash
curl -s -H "$H" \
  -d '{"project":"kiteloop","item":"docs-control-api","approve":true}' \
  $B/backlog/approve
```

```json
{ "item": "docs-control-api", "branch": "kiteloop/docs-control-api",
  "merged": true, "resolved": "approved", "status": "done",
  "verify": ["item verify: xcodebuild … build-for-testing", "merge-verify: ./scripts/ci.sh"] }
```

`verify` is present on a kept merge and lists what actually gated it, in run
order, each entry naming where the command came from. An **empty** list means
the merge was kept with nothing checking it (no project merge-verify, no
item `verify:`) — a driver that cares about the "main never breaks" invariant
should treat that as the finding it is.

`merged` is `false` with a `mergeSkipped` string when there was nothing to merge
(no branch, or already merged) or when `autoMergeOnApproval` is off — in which
case the branch is still the only place the work exists, and the response says so.

"Nothing to merge" covers two opposite states, and one of them is not done: a
branch that was merged, and work that never reached a branch at all. On a project
whose root is a git repository, an item whose branch **does not exist** while the project's
checkout holds tracked modifications is refused rather than approved — 409, with
`"reason": "the work is not where it should be — this item has no branch, and the
project's checkout has uncommitted changes (modified): …"`. Approving there would
stamp the item `done` over files nobody had committed. Commit or stash the
checkout and approve again, or reject the item. On a project that is not a git
repository there is no branch by design and this never fires.

If the merge is attempted and fails, the item **stays at the gate** rather than
being marked `done`: the response is 409 with `"resolved": "not approved"` and a
`reason` of `merge conflict`, `verify failed on merged tree (<command>)`, or a
dirty-tree message. The failing command is named in the reason — with two of them
running, which one refused is the first thing anyone asks. A command still
running at the project's `autoMergeVerifyTimeoutMinutes` deadline (30 minutes,
i.e. 1800 seconds, until the project has landed enough runs to derive its own —
see [The two timeouts are derived, not set](#the-two-timeouts-are-derived-not-set))
is killed, and reads `verify timed out after 1800s on merged tree (<command>)`
instead — the number in the sentence is that deadline in seconds, whatever the
project's own gate phases have made it: it judged nothing about the tree,
and a killed command that printed nothing sends no `verifyOutput` either, so
the reason is the only place that shows. An item is never reported as
delivered over work that did not land.

When the item's cached `freshness` (see [`GET /v1/backlog`](#get-v1backlog))
already reads `clean: false` — a sibling merged into the base while this item
sat at the gate — the same 409 comes back immediately, `reason` naming the
conflicting paths exactly as `merge conflict in: …` would, and **neither a
merge nor a verify runs**. An item nothing has checked yet (a live-tree
project, or one that reached the gate before this build) falls through to the
merge attempt as before.

When the refusal was the verify failing, the response also carries
`verifyOutput` — the tail (last 16 KB) of that command's combined stdout and
stderr. The refusal rolls the merged tree back, so this is the only surviving
evidence of the failure; without it a driver has nothing to decide between
retrying and rejecting. Refusals that never ran a command — a dirty tree, a
merge conflict — omit the field rather than sending an empty one.

```json
{ "item": "docs-control-api", "branch": "kiteloop/docs-control-api",
  "merged": false, "resolved": "not approved", "status": "awaiting-approval",
  "reason": "verify failed on merged tree (item verify: xcodebuild … build-for-testing)",
  "verifyOutput": "…\nBanner.swift:12: error: cannot find 'foo'\n** TEST BUILD FAILED **\n" }
```

To send the failure back to the worker rather than retrying, post the same
endpoint with `approve: false` and the reason and output as `reason` — it lands
in the item's detail file as the feedback the next run reads. (The Autopilot
panel's **Reject with this failure** button does exactly this.)

Only valid from `awaiting-approval`.

**Status:** 200 · 400 (missing `project`/`item`) · 401 · 403 (authenticated with
the [operator token](#authentication) — this gate takes the operator's own) ·
404 (no such item) · 409 (project not open, the item isn't awaiting approval —
the message includes its current status — or the merge could not be kept).

---

### POST /v1/backlog/groom

Moves a backlog item between `draft` and `ready`, and lifts a `blocked` one to
either.

```bash
curl -s -H "$H" -d '{"project":"kiteloop","item":"<id>"}' $B/backlog/groom
curl -s -H "$H" -d '{"project":"kiteloop","item":"<id>","status":"draft"}' $B/backlog/groom
curl -s -H "$H" -d '{"project":"kiteloop","item":"<blocked-id>","status":"draft"}' $B/backlog/groom   # lifts the block
```

| Field | Type | Meaning |
|---|---|---|
| `project` | string | Project identifier. Required |
| `item` / `itemId` | string | Backlog item id. Required |
| `status` | string | `ready` (default) or `draft` |
| `force` | boolean | Promote to `ready` even though the Definition-of-Ready refuses the item. Default `false` |

Sending a `ready` item back to `draft` writes `sent back to draft: over the
control API (POST /v1/backlog/groom)` to its Notes, the same line the pickup
gates write when they demote one — so an item found at `draft` in the morning
says who moved it.

It moves between those two, and out of `blocked` — the one stage nothing else
lifted, so a block used to be cleared by editing the backlog file by hand, which
lost the reason. Lifting a block writes the reason the item was blocked for to
its `## Notes` (`unblocked by hand; was: …`) before the status changes. An item
that is running, in review, at a gate or done answers **409** — every other
transition belongs to the machinery that earns it, and a general status setter
here would be a way to stamp `done` from outside the gate that grants it.

A promotion — `draft` to `ready` — **asserts readiness**: an item the
Definition-of-Ready would refuse at pickup is refused here instead, **422**,
with the clauses in `notReady` (the same phrases `GET /v1/backlog` reports) and
nothing moved. `force: true` promotes it anyway; pickup still judges it as it
always has, and `GroundingCheck` is only ever assessed there. Lifting a
`blocked` item and moving to `draft` are not promotions and are never refused
this way.

**Status:** 200 · 400 (missing `project`/`item`, or `status` is neither
`ready` nor `draft`) · 404 (no such item) · 409 (project not open, or the item
is in a status this verb does not move) · 422 (a promotion the
Definition-of-Ready refuses; `notReady` names the clauses).

### POST /v1/backlog/move

Reorders a backlog item. Within a lane the queue is document order — epics top
to bottom, items within an epic top to bottom — so position **is** priority;
there is no priority field, deliberately.

The **lane sits above position**: every item marked `lane:now` runs before every
item that is not, wherever in the file each of them sits, and moving a `later`
item to the top of the first epic does not put it in front of a `now` item in the
last. Promoting across that line is the lane, not a move — see
[docs/backlog-format.md](backlog-format.md#lanes).

```bash
curl -s -H "$H" -d '{"project":"kiteloop","item":"<id>"}' $B/backlog/move            # top of its epic
curl -s -H "$H" -d '{"project":"kiteloop","item":"<id>","before":"<other>"}' $B/backlog/move
```

| Field | Type | Meaning |
|---|---|---|
| `project` | string | Project identifier. Required |
| `item` / `itemId` | string | Backlog item id. Required |
| `before` | string | An item id to move in front of — following it into its epic when that differs. Omitted: top of the item's own epic |

Nothing else about the item changes: status, lane, grooming and `needs:` edges
stay as they were, and `DefinitionOfReady` still judges at pickup. A `done` item
answers **409** — order only matters for work still in play.

**Status:** 200 · 400 (missing `project`/`item`) · 404 (no such item, or no
such `before`) · 409 (project not open, or the item is done)

### POST /v1/backlog/lane

Puts an item in the `now` or `later` lane. `now` writes `lane:now` on the item's
line beside its size; `later` removes it. Unlike a move, the item keeps its
place in its epic — the lane is what puts it ahead of every `later` item, so
pushing work to the front is one call that leaves it where it belongs. See
[docs/backlog-format.md](backlog-format.md#lanes).

```bash
curl -s -H "$H" -d '{"project":"kiteloop","item":"<id>","lane":"now"}' $B/backlog/lane
curl -s -H "$H" -d '{"project":"kiteloop","item":"<id>","lane":"later"}' $B/backlog/lane
```

| Field | Type | Meaning |
|---|---|---|
| `project` | string | Project identifier. Required |
| `item` / `itemId` | string | Backlog item id. Required |
| `lane` | string | `now` or `later`. Required |

```json
{"item": "<id>", "was": "later", "lane": "now", "changed": true}
```

`changed` is `false` when the item was already in that lane, and nothing is
written. Status, grooming and `needs:` edges stay as they were. A `done` item
answers **409** — the lane only matters for work still in play.

**Status:** 200 · 400 (missing `project`/`item`/`lane`, or `lane` is neither
`now` nor `later`) · 404 (no such item) · 409 (project not open, or the item is
done)

### POST /v1/backlog/land

Merges a **`done`** item's branch that never landed — the merge half of an
approval, taken later. An item reads `done` with its work still on a branch
when its gate cleared without a merge: a `propose` project approved by hand,
or one whose gate changed before it landed. [`GET /v1/backlog`](#get-v1backlog)'s `strandedWork` names every such
item; until this endpoint existed nothing could land one, because
[`POST /v1/backlog/approve`](#post-v1backlogapprove) refuses an item that is
not at its gate.

The merge runs through the same gate as an approval's: a clean merge **and** a
green verify of the merged tree — the item's own `verify:` and the project's
merge-verify, both — on the configured base, with the same
`verifyOutput` on a refusal. The item's status does not change; it was `done`.
What changes is that the work is in the base, and the item's Notes gain the
same `Landed: merged as <sha> into <base>` line a run's own merge writes.
Takes the operator's **own** token, like approve: landing a branch is a
person's call, and an agent that could land its own team's branches would
collapse ADR-0001's human gate.

| Field | Type | Default | Notes |
|---|---|---|---|
| `project` | string | — | **Required** |
| `item` | string | — | **Required** (`itemId` also accepted) |

```bash
curl -s -H "$H" -d '{"project":"kiteloop","item":"docs-control-api"}' $B/backlog/land
```

```json
{ "item": "docs-control-api", "branch": "kiteloop/docs-control-api", "status": "done",
  "merged": true, "commit": "9f3c1a2b7e4d…",
  "verify": ["item verify: xcodebuild … build-for-testing", "merge-verify: ./scripts/ci.sh"] }
```

409, `merged: false`, with a `reason`, when: the item is not `done` (an item
at its gate lands through approve); the item has no branch; the base already
holds the branch (`nothing to land`) — not a failure, the sweep will no longer
name it; or the gate refused the merge, with the conflict or the failing
command in `reason` and a failing verify's tail in `verifyOutput`, exactly as
approve reports them. The branch is untouched by a refusal.

Also 400 (missing `project`/`item`) · 401 · 403 (operator token) · 404 (no such
item).

### POST /v1/backlog/release

Lets an item the **retry ceiling** retired be picked up again. Autopilot refuses
to start an item whose last three attempts all produced nothing (`GET
/v1/grooming` reports the refusal as `check: "retry-ceiling"`). Without a release
that is a one-way door: a retired item cannot run, and only a run could clear the
count.

There are two ways out, and this is the second one:

- **Re-groom the item.** Every attempt records a fingerprint of the item's What /
  How / Validation, so once you rewrite them the old attempts are visibly
  attempts at a different item and stop counting. Nothing to call — editing
  `backlog/<id>.md` is the whole action.
- **Release it as it stands** — this endpoint, or **Release for Autopilot** in the
  item's ⋯ menu in the backlog. Use it when you want the item re-attempted
  without changing what it asks for.

| Field | Type | Default | Notes |
|---|---|---|---|
| `project` | string | — | **Required** |
| `item` | string | — | **Required** (`itemId` also accepted) |
| `reason` | string | — | Why you released it. Recorded verbatim in the grooming ledger |

```bash
curl -s -H "$H" \
  -d '{"project":"kiteloop","item":"grounding-check-false-positives","reason":"rewrote it"}' \
  $B/backlog/release
```

```json
{
  "item": "grounding-check-false-positives",
  "released": "2026-08-09T11:04:22Z",
  "wasRetired": true,
  "noWorkAttemptsBefore": 3,
  "noWorkAttempts": 0,
  "ceiling": 3
}
```

Attempts that finished at or before `released` stop counting; `noWorkAttempts` is
what the next pickup reads. The release is written to
`~/.kiteloop/grooming.jsonl` as a `released` record — the one record in that file
the app reads back rather than only reporting, and the one exempt from its
retention trim — and noted in the item's own file, so "why did this run again"
has an answer in both places.

The ceiling is **not** raised: three more attempts that produce nothing retire the
item again. Nothing releases on a timer.

Releasing an item that isn't retired is allowed and answers `wasRetired: false` —
a 409 there would force a driver to reproduce the ceiling's arithmetic before it
was permitted to ask.

**Status:** 200 · 400 (missing `project`/`item`) · 401 · 404 (no such item) · 409
(project not open) · 503 (no grooming ledger attached to record it in — the app
wires one at launch, so this only shows up in an embedded or test setup).

---

### POST /v1/backlog/refresh

Rebases a stale item sitting at the approval gate, by hand — the same bounded
worker round autopilot runs on its own once the project goes idle: merges the
project's current branch into the item's, resolves conflicts, re-runs the
item's `verify:`, and commits. The item never leaves `awaiting-approval` and
the reviewer is not consulted again — the merge carries no new intent, so
`verify:` is the whole check.

| Field | Type | Default | Notes |
|---|---|---|---|
| `project` | string | — | **Required** |
| `item` | string | — | **Required** (`itemId` also accepted) |

```bash
curl -s -H "$H" -d '{"project":"kiteloop","item":"<id>"}' $B/backlog/refresh
```

```json
{ "item": "<id>", "result": "refreshed" }
```

`result` is `refreshed` (the branch reads clean again), `failed` (the round
ran and did not resolve it, with rounds still left — `detail` says why), or
`retired` (this was the third failed round in a row; the item stays at the
gate, stale, for a human to rebase or resolve by hand). A failed round is
recorded the same way a retry-ceiling pickup refusal is, so the ceiling counts
it: three failures in a row retire the item with the ceiling's own note,
though the item is never moved off the gate by this endpoint either way.

**Status:** 200 (`refreshed`, `failed` or `retired` — a round ran) · 400
(missing `project`/`item`) · 404 (no such item) · 409 (project not open, the
item isn't awaiting approval, has no branch to rebase, is already fresh, or
was already retired by an earlier call).

---

### GET /v1/backlog/templates

The recurring multi-item processes this project has written down.

A **backlog template** is a file of item lines and their groomed detail bodies —
in exactly the formats `BACKLOG.md` and `backlog/<id>.md` already use — with
`{{variable}}` placeholders where each run of the process differs, and a header
declaring each variable. Stamping it files pre-groomed items with `needs:` edges
between them, so a checklist that used to be re-derived from prose every time is
a file under version control instead.

Templates are read from `templates/` **beside the backlog file**, and from
`templates/` in the **project root** when the backlog lives elsewhere (a
vault-backed project keeps its backlog outside the repo, and a checklist about
that repo belongs under version control with it). The first directory holding a
name wins, so a project-local template shadows a repo one.

| Query | Required | Meaning |
|---|---|---|
| `project` | yes | Path or folder name |

```bash
curl -s -H "$H" "$B/backlog/templates?project=kiteloop"
```

```json
{
  "directories": ["/Users/me/vault/Projects/kiteloop/templates",
                  "/Users/me/code/kiteloop/templates"],
  "templates": [
    {
      "name": "release",
      "path": "/Users/me/code/kiteloop/templates/release.md",
      "description": "Ship a Kiteloop build — the three MARKETING_VERSION sites that must not drift, then the CHANGELOG heading.",
      "epic": "Releases",
      "items": 3,
      "variables": [
        {"name": "version", "description": "The version being shipped, e.g. 0.3.0.",
         "required": true, "pattern": "^\\d+\\.\\d+\\.\\d+$"}
      ]
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `directories` | Where the app looked, nearest first. An empty `templates` list is otherwise unreadable — it can't be told from "the app looked somewhere else" |
| `name` | The file's stem — what `POST .../stamp` takes as `template` |
| `items` | How many items it stamps |
| `variables[].pattern` | A regular expression the value must match **whole**. Absent when the variable accepts any single-line value |
| `error` | Why this file could not be read as a template. **Present only on a file that doesn't parse**, in which case the fields above it are absent. A broken template is listed rather than omitted: a missing name reads as "no such template" and sends whoever wrote it looking in the wrong directory |
| `kind` | `true` on the three built-in grooming skeletons — `bug`, `feature`, `tooling` — always listed alongside whatever `templates/*.md` the project has. They are Swift constants, not files, so they carry no `path`; a file-backed template of the same name shadows its skeleton |

**Status:** 200 · 400 (missing `?project=`) · 401 · 409 (project not open).

---

### POST /v1/backlog/items

File **one** new item, as the Mac's **Add item** does — the phone's queue uses
it to capture an idea away from the desk.

| Field | Required | Notes |
|---|---|---|
| `project` | yes | Project identifier |
| `title` | yes | The item's title. One holding the line's field separator, a pipe with a space each side, is refused |
| `note` | no | What the item is about, written as its detail file's `## What` |
| `epic` | no | The epic to file under; `Inbox` when omitted (created if missing) |
| `groom` | no | `true` runs the grooming pass after filing. Default `false` |

```bash
curl -s -H "$H" -d '{"project":"kiteloop","title":"Refunds round to the cent","note":"Seen on the order page.","groom":true}' $B/backlog/items
```

```json
{ "item": "refunds-round-to-the-cent", "epic": "Inbox", "status": "draft", "grooming": "started" }
```

The item is filed at `draft`, with an id slugged from the title and kept clear
of every id the project has used (`-2`, `-3` past a collision; a title that
slugs to nothing gets a generated id). The answer comes at once. With `groom`,
the same pass the Mac's **Groom** button runs then writes what it proposes —
the detail, the line's `verify:` and size — without the Mac's preview; the item
stays at `draft`, so promoting it ([`POST /v1/backlog/groom`](#post-v1backloggroom))
is still a person's step. A pass that fails says why in the item's Notes.
`grooming` is `started`, `not asked`, or why it could not start (no model
runner on this Mac).

**Status:** 201 · 400 (no project or title, a title holding the separator, a
non-boolean `groom`) · 409 (project not open, or it has no backlog) · 500 (a
write failed)

### POST /v1/backlog/templates/stamp

Instantiate a template: substitute the variables, check them, and file the items.

**Previews by default.** Without `apply` nothing is written and the response is
what *would* be filed — the lines, their statuses and the full text of each
`backlog/<id>.md`. With `"apply": true` the items are filed and the answer is
201.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `project` | string | yes | Path or folder name |
| `template` | string | yes | Template name — the file's stem under `templates/` |
| `variables` | object | — | Values by variable name. A JSON number is read as its text |
| `apply` | bool | — | File the items. Defaults to `false` |
| `kind` | string | — | `bug`, `feature` or `tooling`. Runs this kind's own gate on top of the usual two: a stamped item whose `## What` doesn't carry the kind's required sentence (`Repro:`, `User-visible outcome:` or `Serves:`) is filed `draft` with the reason, exactly like a failed Definition-of-Ready or grounding check. Absent leaves today's behaviour untouched; an unrecognised value is a 400 |

```bash
curl -s -H "$H" -d '{"project":"kiteloop","template":"release",
                     "variables":{"version":"0.3.0"},"apply":true}' \
  $B/backlog/templates/stamp
```

```json
{
  "template": "release",
  "epic": "Releases",
  "applied": true,
  "filed": ["release-0.3.0-spec", "release-0.3.0-pbxproj", "release-0.3.0-changelog"],
  "items": [
    {
      "id": "release-0.3.0-spec",
      "title": "Bump MARKETING_VERSION to 0.3.0 in the XcodeGen spec",
      "status": "ready",
      "size": "XS",
      "verify": "grep -q 'MARKETING_VERSION: \"0.3.0\"' Kiteloop/project.yml",
      "needs": [],
      "gates": [],
      "detail": "---\nid: release-0.3.0-spec\n…"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `epic` | The backlog section the items go under: the epic the template names when the backlog has one by that name, its first section otherwise |
| `applied` | `false` on a preview — nothing was written |
| `filed` | The ids written. **Present only when applied** |
| `items[].status` | What it was filed as: `ready`, or `draft` when a gate refused it |
| `items[].needs` | The stamped items this one waits for — the template's ordering, as the `needs:` edges the [Definition-of-Ready](../CLAUDE.md) reads. Resolved: an id naming neither an item in the backlog nor one of this stamp is dropped, and said in `gates` |
| `items[].gates` | What the stamp has to say about this item: why it isn't `ready`, in the gates' own words, and any `needs:` id it had to drop. Empty when there was nothing to say |
| `items[].detail` | The `backlog/<id>.md` this writes, as markdown |

Filing goes through the same path a coordinator filing takes, so a stamped item
and a drafted one are the same item, written the same way. It faces the same two
gates: an item that fails the **Definition-of-Ready** or the **grounding check**
is filed as `draft` with the reason in its `gates` and in its own `## Notes`,
rather than queued. That is not a formality — a template is written once and
stamped for years, so a stamp is exactly where a checklist goes stale, and a
`verify:` naming a file that has since moved is caught at the stamp instead of a
run.

**A `needs:` id that names nothing is dropped, not honoured.** The same staleness
reaches the ordering: an id the template waits for can be renamed or deleted, and
one that names neither an existing item nor another item of this stamp would
withhold the item at every pickup for ever, since nothing returns it to the
groomer. It is dropped from the line and named in `gates` and the item's
`## Notes`, and the item is still filed `ready` — parking it over an invented
prerequisite is the same never-runs failure by another route.

**A refusal is whole-stamp.** A variable that is missing or fails its pattern,
and an id already in the backlog, answer 422 and write **nothing** — not the
items that happened to be fine. Half a checklist is worse than none: the missing
half is invisible, and the half that landed waits on an id nobody will file.

That collision refusal is also the guard against filing the same release twice.
A stamped item keeps no link back to its template, so re-stamping `version=0.3.0`
simply collides on every id and refuses.

**Status:** 200 (preview) · 201 (filed) · 400 (missing `project`/`template`, a
non-string variable, or an unrecognised `kind`) · 401 · 404 (no such template) ·
409 (project not open) · 422 (the whole stamp was refused — nothing was
written) · 500 (a write failed part-way; the message names how many landed).

---

### The proposals endpoints — retired (410)

Advisory mode retired, and the review inbox with it: grooming either files
gated drafts (the switch on, within `DefinitionOfReady`, `GroundingCheck` and
the shared daily ceiling) or doesn't (the switch off), so there is nothing to
list, approve or dismiss. The three routes stay registered and answer **410
Gone** with a note — a named, permanent ending rather than a 404 a driver would
read as its own typo:

- `GET /v1/coordinator/proposals`
- `POST /v1/coordinator/proposals/approve`
- `POST /v1/coordinator/proposals/dismiss`

```bash
curl -s -H "$H" "$B/coordinator/proposals"
```

```json
{ "error": "Advisory mode retired: the proposals inbox is gone. Grooming files gated drafts directly while it is on — read what passes filed via GET /v1/coordinator/refill." }
```

What grooming filed reads back from `GET /v1/coordinator/refill` (`passes`) and
from the day's report surfaces.

**Status:** 410 · 401.

---

The portfolio agent that grooms and knows is the one thing left under this
prefix — the app calls it the **Planner**, and the `/v1/coordinator/*` paths,
stored keys and ledgers keep the `coordinator` spelling the way
`/v1/fleet/quiesce` keeps `quiesce` while the app says "Pause fleet".

### GET /v1/coordinator/refill

What the **queue-refill loop** is doing, and what its recent passes did. This is
the loop that drafts more backlog work when a project's `ready` queue runs dry —
the **Planner** (the endpoint keeps the `coordinator` spelling) as a groomer,
separate from the run scheduler below.

Both `budget` and `passes` describe **the day**, not the process answering: every
pass, what it spent and how it ended is appended to
`~/.kiteloop/coordinator-passes.jsonl` and read back at launch, so a restart
neither zeroes `passesUsed` nor hands the day its `maxPasses` back. `passes` is
still today's alone and bounded by `historyLimit`; the durable record of what was
*groomed* is the ledger and the portfolio report.

| Query | Required | Notes |
|---|---|---|
| `limit` | no | How many recent passes to return, newest first. Integer in `1...200`, default 20 |

```bash
curl -s -H "$H" "$B/coordinator/refill?limit=5"
```

```json
{
  "enabled": true,
  "passInFlight": false,
  "passInFlightSince": null,
  "passStage": null,
  "passStalled": false,
  "passDeadlineSeconds": 900,
  "checkIntervalSeconds": 900,
  "policy": { "threshold": 2, "targetDepth": 3, "maxItemsPerPass": 3, "maxProjectsPerPass": 3 },
  "budget": {
    "spentUSD": 2.46,
    "capUSD": 125,
    "passesUsed": 2,
    "maxPasses": 60,
    "abandonedPasses": 0,
    "day": "2026-08-11",
    "exhausted": false,
    "exhaustionReason": null
  },
  "historyLimit": 50,
  "count": 1,
  "passes": [
    {
      "at": "2026-08-11T03:31:04Z",
      "outcome": "filed",
      "detail": "kiteloop: filed 3 ready, 0 draft(s)",
      "project": "kiteloop",
      "ready": 3,
      "drafts": 0,
      "refused": 0
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `enabled` | The switch, and the whole choice: on files gated drafts, off doesn't. `false` is the shipped state, and an upgrade never turns it on |
| `passInFlight` | Whether a pass is running right now — a pass costs a model call, and two never overlap |
| `passInFlightSince` | When that pass started, `null` when none is. Read against `passDeadlineSeconds` this is what tells a pass apart from a wedge: the flag alone read `true` for 2h22m on 2026-08-12 beside a budget and a pass count that were both truthfully healthy, and nothing in this reply said grooming had stopped |
| `passStage` | What it is doing — `triaging`, `drafting`, `gating` or `filing`. `null` when no pass is running |
| `passStalled` | Whether a pass has been in flight past its deadline, or the last one had to be ended at it. The single field to alert on |
| `passDeadlineSeconds` | How long a pass may run before it is ended and the next one let through. A pass past it is stuck by definition — the work is one model call and a few file writes |
| `checkIntervalSeconds` | How often the loop looks. This is what the `PUT` sets, and what decides how fast an emptied queue refills |
| `policy` | Refill below `threshold` ready items, back up to `targetDepth`, at most `maxItemsPerPass` for one project and across at most `maxProjectsPerPass` projects in one pass. Reported **sanitized** — the policy a pass actually applies. The `PUT` writes all four |
| `budget` | The day's grooming ceilings and what has gone against them. `exhausted` stops passes outright, and `exhaustionReason` names which ceiling did it — `null` while there is room |
| `budget.abandonedPasses` | How many of today's passes were ended rather than finished — they outlived `passDeadlineSeconds`, or the loop was switched off under them. Counted **beside** `passesUsed`, never inside it: both are passes spent against the ceiling, and an abandoned one is a scheduled refill that filed nothing. This is the standing counterpart to `passStalled`, which only ever answers "right now" and goes back to `false` as soon as the deadline ends a stuck pass — an 18-minute stall on 2026-08-12 left no trace outside the bounded pass history half an hour later. Always present, including as `0`, and it zeroes with the rest of the day's counters |
| `budget.day` | The local calendar day these counters describe, as `YYYY-MM-DD` — they zero at local midnight, not at UTC midnight, so this names the same day `spentUSD`, `passesUsed` and `abandonedPasses` are counting against |
| `passes` | Recent passes, newest first. `outcome` is `disabled`, `held`, `noDrafts`, `filed`, `triaged` or `abandoned`, and the count fields are present only for the outcome that has them, so a `filed` pass is never confused with a `held` one reporting zeroes. A hold also carries `hold` and `reason` |
| `passes[].stage` | On an `abandoned` pass: where it was stuck when it was ended — `triaging`, `drafting`, `gating` or `filing` — alongside `ranForSeconds` and `abandonedBecause` (`deadline`, or `switchedOff`). A flag cleared on a timer and nothing else would leave the next wedge as undiagnosable as the first |
| `passes[].retry` | On a `triaged` pass: how the blocked pile was split, alongside `regroom` and `escalate` — the three counts a triage pass reports instead of `ready`/`drafts`/`refused`, since it filed nothing and sorted what was already there |
| `passes[].refused` | On a `filed` pass: how many drafts the backlog wouldn't take — an id already there, or a detail file that wouldn't write. Nothing was written for those, so they are in neither `ready` nor `drafts`; without this number the pass simply reported fewer items than it had groomed, with nothing saying why. Always present on a `filed` pass, including as `0`, and `detail` says so too once there is anything to say |

**Status:** 200 · 400 (bad `limit`) · 401 · 503 (no refill loop attached — the app
window isn't running).

---

### PUT /v1/coordinator/refill

The switch, the day's grooming ceilings, the cadence and the selection
policy. Every field is optional and an omitted one is left alone; only an explicit
`enabled: true` starts the loop. The response is the **settings only** — not the
pass history the `GET` returns.

**Arming requires a ceiling**: `enabled: true` while no daily autonomy budget is
set answers **422**, naming the budget — the same sentence the fleet drawer's toggle
shows. One call may set both (`{"enabled": true, "dailyBudgetUSD": 40}`); the
budget is applied first. Disarming is never gated, and an already-armed loop is
not re-judged.

**One ceiling since 0.3.3**: grooming draws from the portfolio's daily number —
the same ceiling `PUT /v1/coordinator/scheduling` sets — and charges the same
ledger unattended running does. `dailyBudgetUSD` here is a **deprecated alias**
that writes that shared number; prefer the scheduling PUT. This reply reports the
shared ceiling back as `dailyBudgetUSD`; the `GET` reports it, and this loop's own
draw against it, under `budget` as `capUSD` and `spentUSD`. A grooming-only
ceiling stored by an older build migrates into the portfolio number at launch
rather than vanishing.

| Field | Type | Notes |
|---|---|---|
| `enabled` | bool | `true` starts the loop, `false` stops it. Off means no timer at all, not one that wakes to refuse — and it ends whatever pass is running, so writing `false` then `true` is the way to clear a stuck `passInFlight` without restarting the app. Applied **last**, so one call can switch on against the ceilings sent with it |
| `mode` | string | **Deprecated** — advisory mode retired, so the field is tolerated and ignored (any value; nothing is validated, written or reported back). The switch is the whole choice |
| `dailyBudgetUSD` | number \| null | Most grooming may cost in one local day. Positive, or `null` to clear the ceiling (400 otherwise). **Persisted** — portfolio state, so it survives a launch |
| `maxPasses` | integer | Most passes the day allows — the **other ceiling on the same loop**, and usually the one reached first. Positive (400 otherwise); there is no `null` to clear it. **Persisted** as `coordinatorMaxPassesPerDay`, so it survives a restart |
| `checkIntervalSeconds` | integer | How often the loop looks, `60`…`86400` (400 otherwise, naming the range). Applying it **restarts the timer**, so the next pass comes on the new cadence rather than after the old sleep. Not persisted — a restart is back to the shipped `900` |
| `threshold` | integer | Ready-queue depth below which a project gets a refill, `0`…`50`. Not persisted |
| `targetDepth` | integer | The depth a refill tops a queue back up to, `1`…`50`. Held at or above `threshold` — a target below it would never settle — so the reply is what a pass will apply, not necessarily what was sent. Not persisted |
| `maxItemsPerPass` | integer | The most items one pass drafts **for one project**, `1`…`50`. Below `targetDepth` it is what actually decides the fill, and an emptied queue then needs several passes to reach the target. Not persisted |
| `maxProjectsPerPass` | integer | The most projects one pass serves, `1`…`50`. Not persisted |

A rejected policy field names the range it would have taken and leaves the **whole**
policy as it was, so a body that gets one field wrong never half-applies.

```bash
curl -s -X PUT -H "$H" -d '{"enabled":true}' $B/coordinator/refill
curl -s -X PUT -H "$H" -d '{"dailyBudgetUSD":125,"maxPasses":60}' $B/coordinator/refill
curl -s -X PUT -H "$H" -d '{"maxProjectsPerPass":6}' $B/coordinator/refill   # serve a wider fleet
```

```json
{
  "enabled": true,
  "dailyBudgetUSD": 125,
  "maxPasses": 60,
  "checkIntervalSeconds": 900,
  "policy": {
    "threshold": 2,
    "targetDepth": 3,
    "maxItemsPerPass": 3,
    "maxProjectsPerPass": 6
  }
}
```

| Field | Meaning |
|---|---|
| `enabled` | The switch after the write — what a `false`/`true` pair leaves behind, and the one field an arming refusal never gets to change |
| `dailyBudgetUSD` | The shared daily ceiling grooming draws from, `null` when there is none. The portfolio's number, not a grooming-only one |
| `maxPasses` | The day's other ceiling, in passes rather than dollars; `null` when there is none. Persisted as `coordinatorMaxPassesPerDay` — a restart keeps it, and the Planner card's stepper writes the same value — previously back to what the loop was built with |
| `checkIntervalSeconds` | The cadence after the write. Not persisted — a restart is back to `900` |
| `policy` | `threshold`, `targetDepth`, `maxItemsPerPass` and `maxProjectsPerPass`, reported **sanitized** — the policy a pass will actually apply, not necessarily the one that was sent |

There is no pass history here and no `budget` object: this is `RefillSettings`,
while the `GET` answers `RefillStatus`.

Both ceilings bound the same loop and either one stops grooming, so raise the one
that is actually going to bind. Measured on 2026-08-11, three hours into a
session: $47.72 of a $250 budget spent against 13 of 60 passes — on a 300-second
interval the passes run out in under four hours with $200 unspent, and once
grooming stops every queue drains behind it. `GET` reports both under `budget`
(`spentUSD`/`capUSD` and `passesUsed`/`maxPasses`), which is how you tell which
one is nearer before changing either.

When neither ceiling is binding and queues still run dry, reach for the **policy**
before the cadence. One pass serves the `maxProjectsPerPass` neediest projects,
emptiest queue first, so a wider fleet is a bigger `maxProjectsPerPass` rather
than a shorter interval — and it costs the same single pass either way.
Shortening `checkIntervalSeconds` instead spends a pass per tick whether or not
anyone needed one, and passes are the ceiling that stops grooming first: on
2026-08-12, three projects on a 300-second interval left two of them at `ready=0`
because a pass topped up exactly one, so a project's turn came round every twenty
minutes while grooming had spent 1 of 150 passes and $3.85 of $350.

`checkIntervalSeconds` remains the knob for how *often* the fleet is looked at,
and it is still worth shortening when every project drains inside one interval.
Shortening it costs model calls the `queuesHealthy` hold would otherwise avoid,
which is why the shipped default stays at 900.

**Status:** 200 · 400 (body not a JSON object; `enabled` not a boolean;
`dailyBudgetUSD` not a positive number or `null`; `maxPasses` not a
positive integer; `checkIntervalSeconds` not an integer in `60`…`86400`;
`threshold` not an integer in `0`…`50`; `targetDepth`, `maxItemsPerPass` or
`maxProjectsPerPass` not an integer in `1`…`50`) · 401 · 503 (no refill loop
attached).

---

### GET /v1/coordinator/scheduling

What the **autonomous run scheduler** is doing, and what it has started. This is
the loop that calls `BacklogAutopilot.start(initiator: .autonomous)` when a
project has ready work and nothing in flight — the fleet's operator beside the
Planner's groomer (the endpoint keeps the `coordinator` spelling). It is **off
by default** and its switch is separate from
the queue-refill loop's: filing work and running it unattended are different
levels of trust.

| Query | Required | Notes |
|---|---|---|
| `limit` | no | How many recent starts to return, newest first. Integer in `1...200`, default 20 |

```bash
curl -s -H "$H" $B/coordinator/scheduling
```

```json
{
  "enabled": true,
  "checkIntervalSeconds": 300,
  "startInFlight": false,
  "startsInFlight": 0,
  "maxConcurrentRuns": 1,
  "breaker": {
    "open": false,
    "reason": null,
    "holds": []
  },
  "budget": {
    "budgetUSD": 20,
    "spentTodayUSD": 6.4,
    "remainingUSD": 13.6,
    "exhausted": false
  },
  "lastDecision": {
    "kind": "start",
    "detail": "starting kiteloop/summary-line — idle 42m, 3 ready"
  },
  "historyLimit": 50,
  "count": 1,
  "starts": [
    {
      "at": "2026-08-07T02:14:03Z",
      "project": "kiteloop",
      "item": "summary-line",
      "title": "Summarise the backlog at the top of the file",
      "why": "idle 42m, 3 ready",
      "budget": "$6.40 of $20.00",
      "outcome": "done",
      "finishedAt": "2026-08-07T02:51:17Z"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `enabled` | The kill switch. `false` is the shipped state, and an upgrade never changes it |
| `startInFlight` | Whether an autonomous run is executing right now |
| `startsInFlight` | How many autonomous runs are executing right now, across projects |
| `maxConcurrentRuns` | How many the fleet may have in flight at once, `1…8` — each project still runs one at a time. `1` is the shipped default and how the fleet always ran: the scheduler awaits the run it starts before it looks again. Higher, and a look may proceed while another project's run is still being awaited, so two projects advance together. Every run is a worker and a reviewer session plus that project's builds |
| `breaker` | The autonomous **holds**, one per project — the same objects [`/health`](#get-health) lists. `open` is whether there are any and `reason` joins theirs. Keyed `breaker` because `resetBreaker` is still what clears them; it is no longer a fleet-wide latch, and a hold ends by itself when the queue it was about changes |
| `budget` | The **portfolio-wide** daily ceiling and today's spend across every project — the same pair the autopilot's `DailyBudget` gate reads, and what this endpoint's `PUT` sets. An exhausted day refuses **autonomous** starts only; a human start still runs. A project's own ceiling is separate, and on [`GET /v1/autopilot`](#get-v1autopilot) |
| `lastDecision` | What the last look decided — `start`, or a hold (`disabled`, `unwired`, `projectHeld`, `budgetExhausted`, `noEligibleProject`, `noProjectOptedIn`, `allBusy`, `nothingRunnable`, `itemsRefused`, `quiesced`, `gateFull`, `usageLimit`). The scheduler never proposes: advisory mode retired, so a decision is a start or a hold |
| `starts` | Recent autonomous starts, newest first — project, item, `why` it was chosen, the budget at the time, and how the run ended (`running`, `done`, `awaiting-approval`, `investigation`, `blocked`, `cancelled`, `usage-limit-parked`, `did-not-run`, `interrupted`) |

`starts` survives a restart: the durable record is
`~/.kiteloop/coordinator-starts.jsonl`, one line per start and one per finish,
and the newest 50 runs in it are read back at launch. A start whose finish line
never arrived — the app went away mid-run — reads `interrupted` rather than
`running`, the same statement a run record makes about the same event.

A quiet night has a reason, and `lastDecision` is it: "off", "the day's budget is
spent", "every project is busy" and "every idle project is holding on its own
failures" are four different answers, and this endpoint never reports them as the
same silence.

**Status:** 200 · 400 (bad `limit`) · 401 · 503 (no scheduler attached — the app
window isn't running).

---

### PUT /v1/coordinator/scheduling

The kill switch, the **portfolio-wide** daily ceiling, and the way to clear
every autonomous hold. Every field is optional and an omitted one is left alone; only
an explicit `enabled: true` ever starts runs. Returns the same payload as the
`GET`.

**Arming requires a ceiling**: `enabled: true` while no running budget is set
answers **422**, naming the budget — the same sentence the fleet drawer's toggle shows.
One call may set both (`{"enabled": true, "dailyBudgetUSD": 150}`); the budget is
applied first. Disarming is never gated, and an already-armed scheduler is not
re-judged. While no open project has `autonomousWorkEnabled` on
([`PUT /v1/autopilot`](#put-v1autopilot)), an armed scheduler holds with
`noProjectOptedIn` rather than starting anything.

| Field | Type | Notes |
|---|---|---|
| `enabled` | bool | `true` starts the loop, `false` stops it. Switching off tears the timer down and is re-read immediately before a start, so a look already in flight doesn't get one last run in. It does **not** kill a run already executing — use `POST /v1/runs/{runId}/cancel` or the Autopilot's Stop for that |
| `dailyBudgetUSD` | number \| null | The portfolio-wide ceiling — most **every project together** may spend in one local day. Must be positive, or `null` to clear it (400 otherwise). Written before `enabled`, so one call can raise the budget and switch the loop back on |
| `resetBreaker` | bool | `true` clears **every** hold, in every project. Applied before `enabled`, so one call can clear them and switch back on. Flipping `enabled` clears them too — turning the loop back on is a human saying they've seen the failures. The Planner box in the sidebar offers the same override on the line that reports the hold |
| `maxConcurrentRuns` | int | How many autonomous runs the fleet may have in flight at once, `1…8`; each project still runs one at a time. Persisted to `~/.kiteloop/global-config.json`; the drawer's **Runs at once** stepper sets the same value |

```bash
curl -s -X PUT -H "$H" -d '{"enabled":true}' $B/coordinator/scheduling
curl -s -X PUT -H "$H" -d '{"enabled":false}' $B/coordinator/scheduling   # the kill switch
curl -s -X PUT -H "$H" -d '{"dailyBudgetUSD":150}' $B/coordinator/scheduling
curl -s -X PUT -H "$H" -d '{"dailyBudgetUSD":null}' $B/coordinator/scheduling  # no ceiling
curl -s -X PUT -H "$H" -d '{"resetBreaker":true}' $B/coordinator/scheduling
```

The switch and the ceiling are persisted to `coordinatorSchedulingEnabled` and
`dailyBudgetUSD` in `~/.kiteloop/global-config.json`, so a driver that turned the
loop on, or raised the budget, has done so for the next launch too. Read the new
ceiling back in the `budget` block of the response.

**Status:** 200 · 400 (`enabled`/`resetBreaker` not booleans, `dailyBudgetUSD`
not a positive number or `null`, body not a JSON object) · 401 · 503 (no
scheduler attached).

#### Two daily ceilings

There are two, and **both apply**:

| Ceiling | Where it lives | Set by |
|---|---|---|
| **Portfolio** | `dailyBudgetUSD` in `~/.kiteloop/global-config.json` | `PUT /v1/coordinator/scheduling`, or the fleet drawer |
| **Project** | `dailyBudgetUSD` in the project's `.kiteloop/autopilot-config.json` | [`PUT /v1/autopilot`](#put-v1autopilot), or the Autopilot tab |

A project's own budget never licenses it past the portfolio ceiling, and the
portfolio ceiling never overrides a stricter project one. An autonomous start is
refused when **either** is exhausted, and the refusal names the one that stopped
it — so a quiet night reads as "raise *this* number", not as a mystery. A project
with no ceiling of its own is governed by the portfolio's alone.

Spend is attributed per project as each run finishes, so the per-project totals
for a day add up to the portfolio total for that day. Both reset at the user's
local midnight.

Neither ceiling refuses a **human** start. `POST /v1/runs`, the Autopilot's Run
button and the Backlog's are all `human` initiators and run regardless of the
day's spend — the ceiling governs unattended autonomy, not the person at the
keyboard.

---

### POST /v1/runs

Starts one backlog item through the autopilot workflow and returns its `runId`.
One run at a time per project.

| Field | Type | Notes |
|---|---|---|
| `project` | string | **Required** |
| `item` | string | **Required** (`itemId` also accepted) |

```bash
RUN=$(curl -s -H "$H" \
  -d '{"project":"kiteloop","item":"docs-control-api"}' \
  $B/runs | jq -r .runId)
```

```json
{ "runId": "F0A2…", "item": "docs-control-api",
  "title": "Document the control API", "status": "running" }
```

Behaviour worth knowing:

- What refuses a run is **another run in flight**, not the autopilot's status. If
  the previous one is still winding down (the advisory quality judge and agent
  teardown run *after* its result reads `finished`), this endpoint waits up to
  **30 s** for it to finish before giving up with 409. Back-to-back runs in a
  marathon loop therefore don't need their own sleep.
- The 409 **names what it believes is running**, e.g. `Autopilot is still busy for
  this project — running docs-control-api (Document the control API) as run F0A2…`.
  A run id you can look up in `GET /v1/runs` is what makes the claim checkable; a
  bare "still busy" is not. To ask *before* posting, read
  [`run.state`](#run-state) — it comes from the same check this refusal makes.
- A project **left claiming to be busy by a run that ended** does not refuse a
  run over that alone: a claim with no run behind it is reconciled to `idle`
  here, and it is written to the autopilot's log.
- A **paused** project refuses with 409, naming
  [`POST /v1/autopilot/resume`](#post-v1autopilotresume) — see
  [`POST /v1/autopilot/pause`](#post-v1autopilotpause). This holds whether the
  project is paused by its own autopilot or by the fleet board's paused switch;
  [`GET /v1/projects`](#get-v1projects) reports either as `paused: true`.
- After kicking off the workflow it waits up to **4 s** for the execution ID, then
  answers one of three things — and which one depends on what the autopilot
  *decided*, never on the clock:
  - the id, as above (**202**, `status: running`);
  - a refusal, in the refusing gate's own words (**409** or **422**, below);
  - **202 with `status: "starting"` and no `runId`** — nothing refused the run, it
    is simply still spinning up. Read the id from
    [`GET /v1/autopilot?project=`](#get-v1autopilot) (`run.runId`) or
    [`GET /v1/projects`](#get-v1projects), or post the item again: while it is in
    flight the 409 names the run rather than starting it a second time. A pickup
    gate that refuses the item *after* this reply — the grounding check decides
    late on a large tree — is not lost: the server keeps watching, closes a
    `did-not-run-…` record with the gate's reason (in `GET /v1/runs?project=`
    and its `/result`), and writes `run did not start: …` to the item's Notes.

  ```json
  { "item": "docs-control-api", "title": "Document the control API",
    "status": "starting", "detail": "The run was accepted and is spinning up; …" }
  ```

- **422 means the item, not the moment.** It is returned when the pickup gates take
  every selected item: the item isn't `ready`, or it fails the Definition-of-Ready
  gate (no groomed `backlog/<id>.md` with What/How/Validation, no `verify:` command,
  or a size that is unset or larger than `M`), or the grounding check found
  citations that don't resolve, or the retry ceiling retired it. That verdict stays
  true until somebody re-grooms the item, so a driver is right to drop it from its
  rotation. The reason names the clauses that failed; see
  [`autopilot-runbook.md`](autopilot-runbook.md) → §C.
- **409 means come back.** Everything else that can refuse a start — a spent daily
  ceiling, a spent **session** cost cap, a project with no orchestrator or backlog,
  worker/reviewer unset, agents with no session, a run already executing — is a
  condition of the moment, and the item is fine.
- A **spent session cost cap** is refused here rather than accepted: the error is
  the pause's own line, `Session cost cap $5.00 reached ($6.25) — pausing autopilot;
  resume to keep going on a fresh session budget`, so the answer names the ceiling
  and the spend on the first request. The way on is
  [`POST /v1/autopilot/resume`](#post-v1autopilotresume), which opens a fresh
  session budget; nothing else does.
- Every refusal reason comes from the gate that refused. It is **never** read off
  the autopilot's log: the log is a narration, and its last line four seconds into a
  start is the cost governor's informational `Cost cap: …` statement — the ceiling
  the run is *allowed* to spend. That line reported as a cause, with a 422 behind it,
  is what silently dropped live runs from a headless queue.

**Status:** 202 (started, or accepted and starting) · 400 (malformed body) · 401 ·
404 (no such item in this project) · 409 (project not open; autopilot still busy;
worker/reviewer not configured; start refused by a condition of the moment) · 422
(the pickup gates refused this item).

---

### GET /v1/runs

Lists every run this app has tracked since launch **plus what earlier launches
wrote down**, newest first. Useful when a driver lost a `runId`, or attached to an
app that was already working.

| Query | Required | Notes |
|---|---|---|
| `project` | no | Path or folder name; omit for every project. Unlike the other listings, the project **need not be open** — see below |
| `limit` | no | How many **historical** rows to return, `1…200` (default `20`). Live runs are not paged — see below |

```bash
curl -s -H "$H" "$B/runs?project=kiteloop&limit=5"
```

```json
{
  "runs": [
    {
      "runId": "F0A2…",
      "executionId": "F0A2…",
      "item": "docs-control-api",
      "title": "Document the control API",
      "project": "kiteloop",
      "startedAt": "2026-08-04T09:10:55Z",
      "state": "awaiting_approval",
      "historical": false,
      "costUSD": 1.87,
      "costCapUSD": 4.50,
      "predictionSource": "own history"
    },
    {
      "runId": "auto-9c41…",
      "executionId": "7B02…",
      "item": "run-records-never-finalize",
      "title": "Finalize every run record",
      "project": "kiteloop",
      "startedAt": "2026-08-03T22:40:02Z",
      "endedAt": "2026-08-03T22:55:15Z",
      "state": "finished",
      "historical": true,
      "outcome": "done",
      "costUSD": 3.02,
      "durationSec": 913,
      "qualityScore": 4.2,
      "judgeDimensions": { "correctness": 4.5, "scope": 4.0, "tests": 4.0 }
    },
    {
      "runId": "auto-3d18…",
      "item": "runs-listing-says-why",
      "title": "Say why a run was blocked",
      "project": "kiteloop",
      "startedAt": "2026-08-03T21:02:14Z",
      "state": "finished",
      "historical": true,
      "outcome": "blocked",
      "reason": "reviewer rejected: AC 3 is unimplemented",
      "costUSD": 1.44,
      "durationSec": 402,
      "judgeUnavailable": "judge returned no verdict"
    }
  ]
}
```

| Field | Notes |
|---|---|
| `executionId` | The workflow execution the run turned out to be — see [Joining a run to its transcript](#joining-a-run-to-its-transcript) |
| `project` | Folder name of the run's project |
| `startedAt` | When the run was started, ISO 8601 |
| `endedAt` | When the run reached its ending, ISO 8601 — the wall clock the run closed at, which is what lays a night of unattended work against the app's logs. On any run that has ended, whether it finished in this session or in an earlier one; **absent rather than null** while one is still working, and on an `interrupted` one, which reached no ending to report. Not `startedAt` plus `durationSec`: that measures the item rather than the run |
| `state` | `running`, `awaiting_approval`, `finished`, `interrupted` (an app restart ended it), or `unknown` if the project has since been closed |
| `historical` | `true` for a record read back from disk — nothing is driving it, and it has an outcome |
| `outcome` | On a run that reached an ending — whether it finished in this session or in an earlier one: `done`, `awaiting_approval`, `investigation`, `blocked`, `cancelled`, `usage_limit_parked`, or `did_not_run` — a start a pickup gate refused, which spent nothing and reached no ending of its own. `usage_limit_parked` is a run the account's usage limit stopped: the item is back in `ready` and scheduled runs hold until the limit resets. `investigation` is a run that changed no files because the worker checked the item's `## Premise` against the tree and refuted it; the item is at the approval gate with the report in its Notes |
| `reason` | Why the run ended that way, when the record kept a sentence for it — a reviewer's rejection, the cap a run ran into, or the item's own refusal. This is what distinguishes one `blocked` from another |
| `costUSD`, `costCapUSD`, `predictionSource` | What the run is costing — see [Run cost](#run-cost) |
| `durationSec` | How long the run took. On any run that has ended; absent while one is still working |
| `qualityScore`, `judgeDimensions` | The quality judge's verdict, when it returned one. `judgeDimensions` only ever appears alongside a score |
| `judgeUnavailable` | Present *instead of* a score when the judge didn't deliver one, saying why |

The ending time, the outcome, the reason, the duration and the judge's verdict
carry the same values as [`GET /v1/runs/{runId}/result`](#get-v1runsrunidresult)
for the same run, so reading a night of unattended work — how long each item took, why it
ended the way it did and whether it was scored — takes one request rather than
one per run. They are reported as soon as the run has ended, so a run that
finished in this session reads the same as one read back after a restart; the
two rows differ only in `historical`. Each is **absent rather than null** when
the run's record has nothing to report, and a run still working carries none of
them.

**Status:** 200 · 400 (`limit` isn't an integer in `1…200`) · 401. Notably **no
409**: see below.

#### Narrowing and paging

Two things differ from [`GET /v1/grooming`](#get-v1grooming) and
[`GET /v1/metrics`](#get-v1metrics), on purpose.

- **A closed project is not an error here.** Everywhere else `?project=` naming a
  project that isn't open answers 409. A run record outlives its project being
  open — closing a tab doesn't unhappen the run — so refusing would make a record
  unreachable by the only name a driver has for it. An open project resolves
  through the registry as usual (canonical path, raw path or folder name); a
  closed one is matched against the record's own path and the folder name derived
  from it. A project nothing has ever run is an empty list, not an error.
- **`limit` pages the history only.** Every run *this process is tracking* is
  listed regardless of `limit`, so the default can never hide a live run behind a
  page of newer finished ones. A driver polling for what's in flight can leave
  `limit` alone.
- **What the app is tracking is bounded too — just not by `limit`.** Every run
  still open is listed, plus at most the **50 most recently started runs that
  have since finished**; a run that finished before those is dropped from memory
  and listed from its durable record instead, with `historical` `true`. So one
  response holds at most `limit` historical rows, 50 recently finished ones and
  whatever is genuinely open, however long the app has been up — and no run is
  listed twice while it crosses that line. A run dropped this way still answers
  [`GET /v1/runs/{runId}/result`](#get-v1runsrunidresult) from its record,
  exactly as one from an earlier launch does; what a dropped run loses is only
  what a live run can say — `/events` and `/log` answer 409, the same as they
  already do for a run read back after a restart, since both are served from
  buffers this process keeps rather than from the record.

#### Runs nobody asked for

Runs the autonomous scheduler started by itself are listed here on the same
terms as the ones you asked for, and answer for themselves at `GET /v1/runs/{id}`
and `/result` — that is how a night of unattended work is read back. Their ids are
minted (`auto-<uuid>`) rather than taken from the workflow, so
`GET /v1/runs/{id}/events` has nothing to match on and stays empty for one; poll
`/result` instead. What they *were* is in `executionId` — see below.

Runs you start yourself from the **Autopilot tab** are listed here on the same
terms as well. They are picked up the moment their workflow spins up, so — unlike
the scheduler's — a run's id *is* its execution id, and every per-run surface
works for one while it lasts. Which surface pressed start is not something the
history depends on: every run leaves a record, and every record answers after the
app has been restarted.

#### Joining a run to its transcript

`executionId` is the workflow execution the run turned out to be. Two things are
keyed by it and not by `runId`: the run's transcripts, at
`<project>/.kiteloop/transcripts/<executionId>/<role>.jsonl`, and its measurement
in [`GET /v1/metrics`](#get-v1metrics), which reports the execution id as its own
`runId`.

For a run started through [`POST /v1/runs`](#post-v1runs), or from the Autopilot
tab, the two ids are the same and the field says nothing new. For a run the
scheduler started itself the
`runId` is a minted `auto-<uuid>`, and this field is the only thing that joins it
to either — which is why it is written into the durable record, so an unattended
night can still be read back after a restart.

Every per-run readout carries it: [`GET /v1/runs`](#get-v1runs),
[`GET /v1/runs/{runId}`](#get-v1runsrunid), and both bodies of
[`/result`](#get-v1runsrunidresult) — the 202 while the run is in flight and the
200 once it has finished — as well as the historical record. So a driver holding
one `runId` reads it off the endpoint it is already polling, rather than listing
every run or waiting for a restart.

It is **absent rather than null** when there is nothing to report: a run still in
flight that has not reached a workflow yet, a start the pickup gates refused
before one existed, and a record written before the field did. An id was never
invented to fill it, because it would name a transcript directory that isn't
there.

```bash
# Where did the run I am holding write its transcript?
curl -s -H "$H" "$B/runs/$RUN/result" | jq -r '.executionId // "none yet"'
```

#### Runs across a restart

Run *records* are durable; runs are not. Every run is written to
`~/.kiteloop/control-runs.jsonl` — an opening line when it starts, a closing line
when it ends — and the file is read back at launch, collapsed to one record per
`runId`. So a driver that restarts the app, or was holding a `runId` when the app
crashed, still gets an answer for it instead of a 404 for work that may have
merged.

- A run that **ended** before the restart reads `state: "finished"` with its
  outcome, branch, pull request and final cost.
- A run that was **in flight** when the app stopped reads
  `state: "interrupted"` and carries **no `outcome`** — it never reached one, and
  reporting it in the same column as `blocked` would corrupt a driver's tally of
  how a night went. Its item's own state is in the backlog file, where it always
  was.
- A `runId` **nothing ever issued** is still **404**. Persistence answers for runs
  that happened.

Only `GET /v1/runs`, `GET /v1/runs/{runId}` and `.../result` answer from the
record. The endpoints that need something live — `/events`, `/log`, `/approve`,
`/cancel`, `/note` — answer **409** naming the run's state, because the event bus,
the log buffer, the workflow and the worker's session all died with the process. A gate a historical run left
behind is resolved through [`POST /v1/backlog/approve`](#post-v1backlogapprove).

History is bounded so launch cost stays flat: the newest **500** runs, and nothing
older than **30 days**. Both bounds are applied on every write, not only when the
file is read, so they hold in an app left running for weeks as well as across a
relaunch. Trimming a record loses the run's timeline, not the work —
the item is in the backlog file and the measurement is in
[`GET /v1/metrics`](#get-v1metrics).

#### Run cost

Three fields say what a run is costing, on this listing and on
[`GET /v1/runs/{runId}/result`](#get-v1runsrunidresult): the two figures the
Autopilot panel shows, plus where the ceiling came from. A headless driver can
pace itself against that ceiling instead of discovering the bill afterwards in
`GET /v1/metrics`.

| Field | Notes |
|---|---|
| `costUSD` | What the run has spent so far; its final cost once it has finished |
| `costCapUSD` | The **effective** ceiling this run is measured against (`CostGovernor.effectiveItemCap(for:)`): this project's p95 run cost plus half again, never below the item's predicted cost, once five runs carry a cost; the predicted cost plus half again before then — never a flat per-item setting. See `itemCostCapUSD` on [`GET /v1/autopilot`](#get-v1autopilot) |
| `predictionSource` | Which rung of the prediction chain produced the forecast behind `costCapUSD`: `own history` (this item's own recent runs), `stored estimate`, or `size band p50`. Every rung reads only this project's history, so an item id that also exists in another project is not predicted from that project's runs |

**Each is absent rather than `0` or `null` when it can't be established** — a run
whose spend nothing could be attributed to did not cost $0, nobody could tell
what it cost, and a driver deciding whether tonight's queue is affordable reads
those two very differently. So:

- `costUSD` is absent until the run's first cost sample lands (the watchdog
  samples about every 16s, so a run reports nothing for its first few seconds),
  and on a finished run that neither recorded spend nor was ever sampled while it
  was in flight.
- `costCapUSD` is absent when the run is uncapped, and on a run this server never
  observed while it was in flight — the governor clears an item's ceiling the
  moment it ends, so a run nobody polled during keeps no record of the number it
  was measured against.
- `predictionSource` is absent when nothing was predicted and the flat cap is the
  whole story.

Spend so far trails the live turn by at most one watchdog sample. Once the run
has finished, `costUSD` is read from the metric record it wrote — the final
figure, and matched to the run by execution id, so an earlier attempt at the same
item is never billed to this one; a run that recorded nothing falls back to the
last figure seen while it was working. The budget is read and set, and the
derived per-item cap read, through [`GET`/`PUT /v1/autopilot`](#get-v1autopilot).

```bash
# Pace a queue: what is in flight, and how close is it to its ceiling?
curl -s -H "$H" $B/runs | jq '.runs[] | select(.state == "running")
  | {item, costUSD, costCapUSD, predictionSource}'
```

**Status:** 200 · 401.

---

### GET /v1/runs/{runId}

Polls a run. This is the primary monitoring path; SSE is the push alternative.

```bash
curl -s -H "$H" $B/runs/$RUN
```

```json
{
  "runId": "F0A2…",
  "executionId": "F0A2…",
  "item": "docs-control-api",
  "title": "Document the control API",
  "startedAt": "2026-08-04T09:10:55Z",
  "autopilot": "running",
  "itemStatus": "active",
  "historical": false,
  "currentNode": "worker",
  "executionStatus": "running",
  "events": [
    { "ts": "2026-08-04T09:12:03Z", "type": "workflow_transitioned", "source": "autopilot" }
  ]
}
```

| Field | Notes |
|---|---|
| `startedAt` | When the run was started, ISO 8601 — the same value [`GET /v1/runs`](#get-v1runs) reports for it |
| `endedAt` | When the run reached its ending, ISO 8601 — on a run this session finished as well as one read back from disk, and **absent rather than null** while it is still working or when a restart ended it. See [`/result`](#get-v1runsrunidresult) |
| `autopilot` | `idle`, `running`, `reviewing`, `paused`. Absent on a historical run whose project isn't open |
| `itemStatus` | Backlog status, or `unknown` if the item is gone from the file |
| `historical` | `true` when answered from the durable record rather than from anything live |
| `executionId` | The workflow execution the run turned out to be — on a live run as well as a historical one, **absent rather than null** when there is nothing to report. See [Joining a run to its transcript](#joining-a-run-to-its-transcript) |
| `currentNode`, `executionStatus` | Present only while a workflow execution exists |
| `events` | Last **20** bus events for this run (`ts`, `type`, `source`) |
| `approvalQuestion` | Present only when a workflow approval node is waiting |

A run from an earlier launch answers here too, in the shape
[`/result`](#get-v1runsrunidresult) returns — plus `events: []`, because bus
history is not durable. See [Runs across a restart](#runs-across-a-restart).

**Status:** 200 · 401 · 404 (no run with this id, live or on record).

---

### GET /v1/runs/{runId}/result

Reads the run's outcome. Returns **202** while the run is still in flight, **200**
once a result has been recorded — so a poll loop can simply wait for 200.

```bash
curl -s -H "$H" $B/runs/$RUN/result
```

Finished (200):

```json
{
  "runId": "F0A2…",
  "executionId": "F0A2…",
  "item": "docs-control-api",
  "title": "Document the control API",
  "startedAt": "2026-08-04T09:10:55Z",
  "endedAt": "2026-08-04T09:17:47Z",
  "state": "finished",
  "outcome": "awaiting_approval",
  "durationSec": 412,
  "itemStatus": "awaiting-approval",
  "historical": false,
  "branch": "kiteloop/docs-control-api",
  "pullRequestUrl": "https://github.com/acme/kiteloop/pull/42",
  "qualityScore": 0.86,
  "judgeDimensions": { "scope": 1.0, "tests": 0.8 },
  "verifyExitStatus": 0,
  "verifyCommand": "cd Kiteloop && xcodebuild -scheme Kiteloop build-for-testing",
  "verifyOutputTail": "** TEST BUILD SUCCEEDED **",
  "verifyTimedOut": false,
  "verifyDirectory": "/Users/you/kiteloop/.kiteloop/worktrees/docs-control-api",
  "costUSD": 2.13,
  "costCapUSD": 4.50,
  "predictionSource": "own history"
}
```

Still going (202):

```json
{
  "runId": "F0A2…",
  "executionId": "F0A2…",
  "item": "docs-control-api",
  "title": "Document the control API",
  "startedAt": "2026-08-04T09:10:55Z",
  "state": "awaiting_approval",
  "itemStatus": "awaiting-approval",
  "historical": false,
  "approvalQuestion": "Merge the worker's changes?",
  "costUSD": 1.87,
  "costCapUSD": 4.50,
  "predictionSource": "own history"
}
```

From an earlier launch (200) — the run is over, whatever happened to it:

```json
{
  "runId": "auto-9c41…",
  "executionId": "7B02…",
  "item": "run-records-never-finalize",
  "title": "Finalize every run record",
  "startedAt": "2026-08-03T22:40:02Z",
  "state": "interrupted",
  "itemStatus": "ready",
  "historical": true
}
```

That one carries no `endedAt`: a restart ended it, so it never reached one. A
run that *did* reach an ending carries both, which is what places `durationSec`
in time — the two bracket the run — and it carries them as soon as it ends,
without waiting for a restart.

| Field | Notes |
|---|---|
| `startedAt` | When the run was started, ISO 8601. On **all three** bodies — the 200, the 202 and the historical record — so a driver holding a `runId` can place the run in time without listing every run. The same value [`GET /v1/runs`](#get-v1runs) reports for it |
| `endedAt` | When the run reached its ending, ISO 8601 — the wall clock the run closed at, read off the run's durable record, so the 200 this session serves and the one served after a restart report the same instant. On the 200 only: a run still working (the 202) has not ended, and one whose `state` is `interrupted` is **absent rather than null** — a restart ended it before it reached an ending, and there is no time to report. Not `startedAt` plus `durationSec`: that measures the item rather than the run |
| `state` | `finished` (200), `running` / `awaiting_approval` (202), or — on a record from an earlier launch — `interrupted` (a restart ended it) or `unknown` (its project was closed while it was open) |
| `executionId` | The workflow execution the run turned out to be. On **all three** bodies — the 200, the 202 and the historical record — so a poll loop reaches the run's transcript from the endpoint it is already sitting on. **Absent rather than null** when there is nothing to report. See [Joining a run to its transcript](#joining-a-run-to-its-transcript) |
| `outcome` | `done`, `awaiting_approval`, `investigation`, `blocked`, `cancelled`, `usage_limit_parked`, `did_not_run` — only when the run reached an ending. Absent when `state` is `interrupted` or `unknown`. `did_not_run` is a start a pickup gate refused: it spent nothing and reached no ending of its own, which is why it is not `blocked`. `investigation` is a run that changed no files because the worker refuted the item's `## Premise` with a measurement; like `awaiting_approval`, the item is at the gate, carrying the report |
| `historical` | `true` when answered from `~/.kiteloop/control-runs.jsonl` rather than from a run this process finished. Such a run is never **202**: there is nothing left to wait for, so a poll loop across a restart is released rather than parked forever |
| `itemStatus` | The backlog item's status *now* when its project is open, otherwise what the record froze at the run's end |
| `reason` | Why the run ended as it did — when `outcome` is `blocked`, and on a `did_not_run` start, where it carries the pickup gate's own words |
| `branch` | Worktree/branch used, when the run created one |
| `pullRequestUrl` | The pull request opened for that branch — only with `openPullRequest` on, and only when one was opened. Absent when it was skipped; the item's Notes say why |
| `approval` | `automatic` when the run cleared the item's approval gate itself (`approveReviewPassedRuns` — see [Approving without asking](#approving-without-asking)). **Absent, never null**, otherwise, including for an item a person approved: that happens after this record closes, so its absence means "nobody approved it here", not "nobody approved it" |
| `merged` | Present **only when the run attempted its own merge** — `autonomy: land`, or `autoMergeOnApproval` beside `approveReviewPassedRuns`: `true` when the branch landed, `false` when the gate refused it (the item's Notes and [`strandedWork`](#get-v1backlog) say why). **Absent, never null**, when this run attempted none — a gate waiting for a person, a project that never merges — which is not the same as unmerged: a merge a person triggers at the gate happens after this record closes. Kept on the durable record, so a night read back the next morning still says which of its `done` runs shipped |
| `mergeCommit` | The commit the branch became on the base. Present only alongside `merged: true` |
| `qualityScore`, `judgeDimensions`, `judgeUnavailable` | The judge's verdict on **this** run, or why it has none. Read off the metric row this run's execution wrote, so an item that ran twice in one session never reports the other attempt's score here. **Absent, never null**, when this run wrote no row — which is not a score of zero |
| `verifyExitStatus`, `verifyCommand`, `verifyOutputTail`, `verifyTimedOut`, `verifyDirectory` | What the item's own `verify:` answered when the app ran it on the run's tree, at the gate before the reviewer: the exit status (`0` and only `0` is a pass; a negative status is a command that never returned one), the command as it was run, the last 40 lines it printed, whether the **deadline** is what ended it rather than the command answering, and the directory it ran in. `verifyTimedOut` is what makes a negative status readable — `true` is a command the clock killed, which judged nothing about the tree; `false` is one that could not be spawned. `verifyDirectory` is the run's worktree, or the project root for a live-tree run, and is what says a verify passed in the wrong tree. Kept on the run's durable record, so a run read back after a restart still says what its `verify:` answered. **Absent, never null**, when no verdict was taken — an item declaring no `verify:`, or a run that ended before that gate — and on a record written before these fields existed, neither of which is the same as a verify that passed; a record that kept a verdict before `verifyTimedOut` and `verifyDirectory` existed reports the other three without them. Addressed by this run's execution too, so a second attempt at the same item does not answer for the first. A run whose verify is non-zero never reaches the reviewer: it ends `blocked`, and `reason` carries the same words |
| `costUSD`, `costCapUSD`, `predictionSource` | What the run cost, and the ceiling it was measured against — see [Run cost](#run-cost). Carried on **both** the 200 and the 202, so a poll loop reads spend so far and then the final bill from the same fields |

**Status:** 200 (finished, or a historical record) · 202 (in progress) · 401 · 404
(no run with this id, live or on record).

---

### GET /v1/runs/{runId}/events

Server-Sent Events for one run. The connection is held open (unlike every other
endpoint) and each frame is `data: ` followed by one compact JSON object:

```
data: {"ts":"2026-08-04T09:12:03Z","type":"workflow_transitioned","source":"autopilot","payload":{"executionID":"F0A2…","node":"reviewer"}}
```

```bash
curl -N -H "$H" $B/runs/$RUN/events
```

- The stream **backfills** this run's history from the event bus first, then
  switches to live events. Only events whose payload carries this run's
  `executionID` are sent.
- It closes on the first terminal event — `workflow_completed`, `workflow_failed`,
  or `workflow_cancelled`. If the run already ended before you connected, the
  backfill is sent and the stream closes immediately.
- Client disconnects are detected and unsubscribe the stream, so it is safe to
  `Ctrl-C` out of `curl -N`.
- While the run is quiet, the server sends a keepalive comment every 15s so an
  idle stream doesn't look dead. Comment lines start with `:` and carry no data —
  SSE clients ignore them, and a line-oriented reader should skip them:

  ```
  : keepalive
  ```
- There is no `Last-Event-ID` resume; reconnecting replays the backfill.
- The bus does not survive the app, so a run from an earlier launch has no stream
  to open: **409**, naming its state. Read
  [`/result`](#get-v1runsrunidresult) instead.

**Status:** 200 (stream) · 401 · 404 (no run with this id, live or on record) ·
409 (the run is on record but not live).

---

### GET /v1/runs/{runId}/log

The autopilot's own narration for this run — the same lines the Autopilot tab
prints. Where `/events` reports what the machine did, this reports why a run
ended the way it did: the retry that sent the item back to the worker, the stall
or cost cap that ended it early, the reason a review didn't pass.

```bash
curl -s -H "$H" $B/runs/$RUN/log
curl -s -H "$H" "$B/runs/$RUN/log?limit=10"     # just the tail
```

```json
{
  "runId": "F0A2…",
  "item": "docs-control-api",
  "title": "Document the control API",
  "project": "kiteloop",
  "count": 4,
  "truncated": false,
  "lines": [
    { "ts": "2026-08-04T09:10:55Z", "message": "Executing: Document the control API" },
    { "ts": "2026-08-04T09:10:55Z", "message": "Isolated run in worktree kiteloop/docs-control-api" },
    { "ts": "2026-08-04T09:10:56Z", "message": "→ Worker started" },
    { "ts": "2026-08-04T09:16:41Z", "message": "→ Reviewer (attempt 1)" }
  ]
}
```

| Field | Notes |
|---|---|
| `lines` | Oldest first — a log read top-down. `ts` is ISO 8601 |
| `count` | Number of lines returned, after `limit` |
| `truncated` | `true` when these are not all of the run's lines (see below) |

- **`?limit=`** keeps the newest N lines (1–50; default: the whole window). Outside
  that range, or not a number, is **400** — 50 is the whole buffer, so a larger
  limit is a caller expecting history that never existed.
- The autopilot keeps **one rolling 50-line log per project**, not one per run, so
  a run's lines are the slice from when it started until the next run in the same
  project began. One run at a time per project makes that slice exact; the newest
  run's window stays open, so a live run's lines keep arriving as it goes.
- `truncated` is `true` when the answer is not the run's complete log — either
  `limit` cut it, or the rolling buffer already evicted its earlier lines (a run
  that logged more than 50 lines). Nothing recovers evicted lines; for a full
  record of a long run, follow `/events` while it runs.
- Only runs this server started are tracked, so the log of a run started from the
  Autopilot tab is not readable here (**404**) even though its lines are in the
  same buffer.
- The buffer holds only the current process's lines, so a run from an earlier
  launch answers **409** rather than an empty log — its record survived the
  restart, its narration did not.

**Status:** 200 · 400 (bad `limit`) · 401 · 404 (no run with this id, live or on
record) · 409 (the run is on record but not live).

---

### POST /v1/runs/{runId}/approve

Resolves whichever gate this run is currently waiting at. A mid-workflow
human-approval node takes priority; otherwise the item's `awaiting-approval` gate
is resolved (same effect as `POST /v1/backlog/approve`).

| Field | Type | Default | Notes |
|---|---|---|---|
| `approve` | bool | `true` | `approved` also accepted |
| `note` | string | none | Rejection reason / approval note |

```bash
curl -s -H "$H" -d '{"approve":true}' $B/runs/$RUN/approve
```

Workflow node resolved:

```json
{ "runId": "F0A2…", "gate": "workflow", "resolved": "approved" }
```

Backlog item gate resolved:

```json
{ "runId": "F0A2…", "item": "docs-control-api",
  "resolved": "approved", "status": "done" }
```

An empty body is valid and means "approve".

An item gate resolved here refuses on the same terms as `POST
/v1/backlog/approve`, and its 409 carries the same `reason` and `verifyOutput`.

This resolves the gate a **live** run is holding. A run from an earlier launch
holds none — it answers **409** naming the item, whose gate is resolved with
[`POST /v1/backlog/approve`](#post-v1backlogapprove).

**Status:** 200 · 401 · 403 (authenticated with the [operator token](#authentication)
— this gate takes the operator's own) · 404 (no run with this id, live or on
record) · 409 (no pending approval for this run — neither a workflow node nor
an item awaiting sign-off; the run is only on record; or the merge could not be
kept).

---

### POST /v1/runs/{runId}/cancel

Abandons a run that is still in flight — the headless equivalent of the Autopilot
tab's stop button. No body.

Three things happen, in order:

1. The agent holding the current node (worker or reviewer) is **interrupted**, so its
   Claude Code subprocess stops streaming — and stops billing — against a workflow
   nobody is waiting on. It is interrupted, not stopped, so its session survives and
   the next run can start without a human reopening the chat.
2. The **workflow execution is cancelled**, which also closes any open SSE stream for
   this run with a `workflow_cancelled` event.
3. The project's **autopilot queue is stopped**, so it doesn't move straight on to the
   next item. This only happens when the run being cancelled is the one actually in
   flight: a stale `runId` cancels nothing and leaves the current item alone.

```bash
curl -s -X POST -H "$H" $B/runs/$RUN/cancel
```

```json
{ "runId": "F0A2…", "item": "docs-control-api", "title": "Document the control API",
  "state": "cancelling", "autopilot": "idle" }
```

`cancelling` is a transitional value specific to this response, not one of the run
states: autopilot notices the cancellation on its next poll (~2s) and only then puts
the item back to **`ready`** and records the run's outcome as `cancelled`. Poll
`GET /v1/runs/{runId}/result` for the unwound state. `autopilot` is the project's
status as of the response — `idle` once the queue has been stopped.

Cancelling is only for a run still in progress. A **finished** run — its item done,
blocked, or sitting at its human gate — answers 409; use
`POST /v1/runs/{runId}/approve` to resolve a gate. A run from an earlier launch
answers 409 for the same reason: there is nothing left to cancel.

**Status:** 202 · 401 · 404 (no run with this id, live or on record) · 409 (run
already finished, or only on record).

---

### POST /v1/runs/{runId}/note

Hands the run's **worker** a short note, delivered at its next turn boundary. This
is the third option beside cancelling and waiting: an in-flight run you can watch
through [`GET /v1/runs/{runId}/log`](#get-v1runsrunidlog) going the wrong way used
to leave a headless driver with nothing between losing the run and losing the
money. Same seam as the Autopilot tab's note field — same gate, same refusals,
same record.

| Field | Type | Default | Notes |
|---|---|---|---|
| `note` | string | required | Trimmed. Truncated at **1000** characters rather than refused, so a long paste still sends the part that fits |

```bash
curl -s -H "$H" -d '{"note":"the fix belongs in the parser, not the view"}' $B/runs/$RUN/note
```

```json
{ "runId": "F0A2…", "item": "docs-control-api", "title": "Document the control API",
  "state": "sent", "note": "the fix belongs in the parser, not the view" }
```

`note` in the reply is the note **as it was queued** — trimmed, and truncated if it
ran long — so a caller can see what the worker will actually be shown.

**A note is advice, not re-scoping.** The framing it is wrapped in tells the worker
so directly: it cannot approve the work, raise any spending cap, change the item or
speak for the reviewer, and where it contradicts the item's What / How / Validation
the item wins and the worker says so. Those criteria are still what the reviewer
checks against.

**Only the worker, and only while it is working.** The reviewer is never reachable
— its independence is part of what its verdict is worth — so a run in review is
refused (**409** `No worker running — a note can only be handed to a run in
flight`), as is a note that is only whitespace (**409** `Nothing to send`). A
`runId` that is no longer the run in flight for its project is refused too: one
project runs one item at a time, and a stale id must not steer whatever has taken
its place.

**Every note is recorded** — in the run log, in the phase log, and in the item's
`## Notes` with the time it was sent. A steer that left no trace would make the run
unattributable: nobody reading the merged diff afterwards could tell which of its
decisions were the worker's own.

Delivery is at the **next turn boundary**, not mid-turn: the worker finishes what it
is doing, then gets a full turn to act on the note in the same session, with all of
its context. Several notes sent during one turn are delivered together.

**Status:** 200 · 400 (body has no `"note"`) · 401 · 404 (no run with this id, live
or on record) · 409 (no worker to hand it to — the reviewer holds the run, the run
is over or is only on record, it is not the run in flight, or the note sanitized to
nothing).

---

## End-to-end example

Open a project, staff it, run one item, watch it, approve it:

```bash
TOKEN=$(cat ~/.kiteloop/control-token)
H="Authorization: Bearer $TOKEN"
B="http://127.0.0.1:4517/v1"
P=kiteloop

curl -s http://127.0.0.1:4517/health

# 1. Open the project and make sure it has a worker + reviewer.
curl -s -H "$H" -d '{"path":"~/code/kiteloop"}' $B/projects/open
curl -s -H "$H" -d "{\"project\":\"$P\",\"name\":\"Builder\"}"  $B/agents
curl -s -H "$H" -d "{\"project\":\"$P\",\"name\":\"Reviewer\"}" $B/agents
curl -s -H "$H" -X PUT \
  -d "{\"project\":\"$P\",\"worker\":\"Builder\",\"reviewer\":\"Reviewer\"}" \
  $B/autopilot

# 2. Pick a ready item and start it.
curl -s -H "$H" "$B/backlog?project=$P" | jq '.items[] | select(.status=="ready")'
RUN=$(curl -s -H "$H" -d "{\"project\":\"$P\",\"item\":\"docs-control-api\"}" \
  $B/runs | jq -r .runId)

# 3. Watch it (SSE), or poll the result until it stops returning 202.
curl -N -H "$H" $B/runs/$RUN/events
until curl -s -o /tmp/r.json -w '%{http_code}' -H "$H" $B/runs/$RUN/result \
      | grep -q 200; do sleep 10; done
jq . /tmp/r.json

# 4. Clear the human gate.
curl -s -H "$H" -d '{"approve":true}' $B/runs/$RUN/approve
```

## Limits (v1)

- **The app must be running** and the target project open (or opened via
  `POST /v1/projects/open`); there is no headless boot.
- **One run at a time per project.** A second `POST /v1/runs` waits out the previous
  run's tail, then 409s naming the run it is waiting for. Only a run actually in
  flight refuses another — a paused or stale-looking autopilot does not.
- **A restart ends every run, but not its record.** Run records survive in
  `~/.kiteloop/control-runs.jsonl` (newest 500, 30 days) and previously issued run
  IDs keep answering — a run that was in flight reads `interrupted`. What does not
  survive is anything live: no resuming a run, and `/events`, `/log`, `/approve`,
  `/cancel` and `/note` answer 409 for a run only on record. See
  [Runs across a restart](#runs-across-a-restart).
- **Cancelling is per run, not per item.** `POST /v1/runs/{runId}/cancel` stops the
  project's whole queue, not just the one item; there is no "skip this item, keep
  going" verb.
- **No pagination or filtering** on `/v1/backlog`; it returns every item in the file.
- **Token auth only** — no per-caller identity, scopes, or audit trail beyond the
  event bus. This is safe only because the listener is loopback-bound; do not port-
  forward or proxy it.
