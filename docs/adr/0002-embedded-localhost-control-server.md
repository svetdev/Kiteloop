# ADR-0002: Headless drive goes through an embedded loopback HTTP server

- **Status:** Accepted (2026-08-05) — describes the design shipped 2026-08-02
- **Deciders:** the maintainer
- **Related:** [`docs/control-api.md`](../control-api.md) (reference),
  [`docs/autopilot-runbook.md`](../autopilot-runbook.md) (operations),
  [ADR-0001](0001-autonomous-run-model.md) (what a run is)

## Context

Kiteloop is a native macOS app whose state lives in memory on the main actor:
`Orchestrator` owns the agents, `ProjectSession` owns a project's open state, and
`BacklogAutopilot` owns the run queue. Driving a run means touching that state —
starting an item, watching its events, clearing the human gate.

That is fine when a human is at the keyboard, and useless otherwise. Three things
need to drive the app without one:

- **Unattended endurance runs** — the #1 SLO in [`success-metrics.md`](../success-metrics.md)
  is a long queue executing with no operator present; something has to start the
  next item and answer for it.
- **A Claude Code session outside the app** — the most convenient driver of
  Kiteloop is an agent that is not one of Kiteloop's own agents.
- **Scripts and harnesses** — eval sweeps, long unattended runs, CI-shaped automation.

None of these can be served by the UI, and none of them should reimplement the
app's state. So the app has to expose its own control surface, and the question is
what that surface is.

## Decision

Kiteloop embeds a **loopback HTTP server inside the app process** and exposes a
versioned JSON API over it (`Services/Control/`).

1. **In-process, not a separate daemon.** The server's handlers run on the main
   actor and read the live `Orchestrator` / `ProjectSession` / `BacklogAutopilot`
   objects through `ControlSessionRegistry`. There is one source of truth, and the
   API is a view onto it rather than a copy of it.
2. **HTTP + JSON over TCP on `127.0.0.1`.** The listener sets
   `requiredLocalEndpoint` to `127.0.0.1`, so it is never reachable off-device.
   Default port `4517`; ports below 1024 are refused.
3. **Off by default, opt-in per install.** *Settings → General → Local Control API*,
   persisted as `controlServerEnabled` / `controlServerPort` in
   `~/.kiteloop/global-config.json`. The toggle applies immediately and the server
   restarts on launch if it was left on.
4. **Bearer-token auth on everything except `GET /health`.** The token is generated
   on first use into `~/.kiteloop/control-token` (mode `0600`) and compared as an
   exact full string. Auth is checked *before* routing, so an unauthenticated
   request to any `/v1` path gets 401 rather than a 404 that would map the route
   table.
5. **Hand-rolled transport, no server framework.** `HTTPServer.swift` is ~440 lines
   over a BSD socket bound to 127.0.0.1 (`LoopbackSocket.swift`): unary
   request→response with `Connection: close`, one exception for SSE streams, a
   2 MB request cap. It started on `Network.framework`, whose `NWListener`
   refuses the port whenever any other socket holds it on another address —
   the pairing forwarder does, on the LAN and tailnet addresses.
6. **Routing is a pure function.** `ControlRouter.match(method:path:)` turns a
   request into a `ControlRoute` value with no app state involved, so the table is
   unit-testable without binding a port or opening a project
   (`ControlRouterTests`).

## Implementation status

Shipped and in daily use — this ADR records a decision already made in code, which
is why it is dated after the commit it describes.

Twenty-three routes (`ControlRouter.table`): projects, agents, backlog, metrics and
estimates, autopilot config and queue control, coordinator, and runs — start, list,
status, result, log, SSE events, approve, cancel. The full contract is
[`control-api.md`](../control-api.md); `CLAUDE.md` carries the short form.

Two limits are deliberate for v1 and visible in the API:

- **The project must already be open in the app** for everything except `/health`,
  `GET /v1/projects` and `POST /v1/projects/open` — 409 otherwise. Headless boot of
  a cold project was not worth the state machine.
- **Run records are in memory.** A `runId` is the workflow execution ID and does not
  survive a restart; a known id 404s afterwards. `GET /health` reports uptime partly
  so a driver can detect exactly that.

The app is not sandboxed (`com.apple.security.app-sandbox` is `false` in
`Kiteloop.entitlements`), so binding a listener needs no entitlement work. The port
floor of 1024 is kept anyway rather than offering a privileged port that may fail to
bind.

## Consequences

**Positive**
- Any HTTP client is a driver: `curl`, `jq`, a Claude Code session, a Python
  harness. No SDK, no code generation, no client to keep in sync.
- SSE gives live run events over the same socket and the same auth, so monitoring
  needs no second channel.
- Off-by-default + loopback + token means the attack surface of a default install is
  zero, and of an enabled install is "local processes that can read a `0600` file in
  your home directory".
- The routing table is a value, so adding an endpoint is a row plus a handler, and
  the table itself is covered by tests without any I/O.

**Costs / follow-ups**
- **A hand-rolled HTTP server is ours to maintain.** It intentionally does not do
  keep-alive, chunked encoding, compression, HTTP/2, or concurrent pipelining. Every
  gap is a thing a client library might assume; the mitigation is that the API is
  small and `HTTPServerTests` covers the parser.
- **Token in a file, not the Keychain.** Any process running as the user can read
  it. Loopback + user-owned `0600` is the threat model we accepted; there is no
  rotation endpoint (rotate by deleting the file and restarting).
- **No browser-origin defence.** Nothing checks `Origin`, so a page in a local
  browser could reach the port — but not usefully without the token, which it cannot
  read. Revisit if a route ever becomes token-free.
- **Handlers run on the main actor**, so a slow handler stalls the UI. The existing
  rule applies: never block the orchestrator with synchronous I/O.
- **In-memory run state** means a restart loses run history for in-flight drivers;
  durable run records are a follow-up if unattended queues need to survive crashes.

## Alternatives rejected

- **A separate headless daemon or CLI binary.** Would need its own copy of the
  orchestrator, agent sessions and autopilot — two implementations of the run model,
  drifting. The app is already the process that owns agent subprocesses; putting the
  API anywhere else means duplicating that ownership.
- **A server framework (Vapor, Swifter, Hummingbird).** Brings a dependency tree,
  build time, and a concurrency model to reconcile with `@MainActor`, to serve two
  dozen unary JSON routes. The project's only remote SPM dependency is UI-side
  (Highlightr; the other package is the local `KiteloopCore`) and this did not
  justify another.
- **A Unix domain socket instead of TCP.** Better default access control (filesystem
  permissions instead of a token), but it costs every client the `--unix-socket`
  dance and rules out plain `http://127.0.0.1:4517/...` in a browser, a `fetch`, or
  any library that only speaks URLs. Loopback + token reaches the same place with a
  friendlier surface.
- **Extending the MCP tool bridge.** Kiteloop already speaks MCP over FIFOs to its
  own agents, but that channel exists *inside* a session Kiteloop spawned. The
  driver here is an external process that has to be able to start the first session —
  it needs a socket, not a pipe into a session that does not exist yet.
- **AppleScript / a custom URL scheme.** Fire-and-forget, awkward structured payloads,
  and no way to stream a run's events back. Fine for "open this window", wrong for
  "run this item and tell me how it went".
- **Binding `0.0.0.0` for remote drive.** Turns a local convenience into a networked
  service with an agent behind it that edits code and runs commands. Out of scope;
  remote access, if ever, is an SSH tunnel to the loopback port.

---

*Addendum 2026-08-17: the implementation has outgrown the status snapshot
above — the route table has grown well past twenty-three, and run records now
persist across restarts (`~/.kiteloop/control-runs.jsonl`), so a `runId`
answers as a historical record. The decision and its rationale stand.*
