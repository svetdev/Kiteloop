# Kiteloop

Native macOS multi-agent team app — chat-first, always running.

## Quick Context

- **What:** A native macOS app where a human leads a team of AI agents that communicate with each other
- **Stack:** Swift, SwiftUI, Claude Code subprocesses (stream-json protocol)
- **LLM Backend:** Claude via the CLI login, an API key or Bedrock; Ollama locally
- **Status:** see `CHANGELOG.md`

## Architecture

All app code lives under `Kiteloop/` (the Xcode project directory):

- `KiteloopCore/` — a local Swift package, the host-less core: code the app runs
  that needs no app to run it. Its tests run under `swift test` with no test
  host, so they are safe while Kiteloop is up and an item's `verify:` can run
  them. A file moves here when every type it references is already here
  (`package` access; the app carries `SWIFT_PACKAGE_NAME = kiteloopcore`).

- `KiteloopApp.swift` — App entry, global state (config stores, runtime factory, control server)
- `MainWindow.swift` — Project tabs, agent sidebar, home workspace auto-open, setup wizard
- `Orchestrator.swift` — @MainActor @Observable, manages agents, sessions, event bus
- `ClaudeCodeCLIRuntime.swift` — Spawns `claude` CLI processes, manages stdin/stdout/FIFO pipes
- `ChatViewModel.swift` — Per-agent message stream processing, tool handling, inter-agent messaging
- `BacklogAutopilot.swift` — Worker/reviewer autopilot over `ready` backlog items
- `Services/Control/` — local HTTP control API (127.0.0.1) for headless drive: run/monitor/approve items, hire agents

## Key Patterns

- **Agent lifecycle:** Template → Agent → Session (CLI process). Agents persist across messages.
- **Tool bridge:** Named pipes (FIFOs) for MCP tool calls between Claude Code and Kiteloop
- **Permissions:** spawn flags — `--permission-mode` (default `auto`), `--permission-prompts host`/`none`
- **Subprocess seam:** every child the app runs to completion goes through
  `SubprocessOutput` → `SubprocessRunning` (`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/SubprocessOutput.swift`);
  a test installs `ScriptedSubprocessRunner` (`KiteloopTestSupport`) via
  `withScriptedSubprocesses` to make git refuse or a command time out without a
  child. The control server answers in process through
  `KiteloopControlServer.handle(_:)` — same routing and auth as the socket.
- **Team persistence:** `.kiteloop/team.json` (PackageTeamConfig: agent refs + overrides)
- **Knowledge:** `knowledge/` directory with per-agent packages (profile.md + knowledge/*.md); bundled examples in `Kiteloop/examples/agents/`
- **Home workspace:** `~/.kiteloop/home/` — default project for managers

## Conventions

- SwiftUI views in `Views/`, ViewModels in `ViewModels/`, services in `Services/`
- Tests mirror the source layout; `KiteloopTests/Services/` is split by subsystem —
  `Control/`, `Autopilot/`, `Backlog/`, `Coordinator/`, `Workflow/`, `Metrics/`,
  `Agents/`, `Sessions/` — and the helpers both test targets share (`eventually`,
  `makeTemporaryDirectory`, `ScriptedSubprocessRunner`) live once, in the
  package's `KiteloopTestSupport` target
- @Observable for ViewModels and services, @MainActor for UI-bound classes
- Orchestrator is @MainActor — never block it with synchronous I/O
- Background work via `DispatchQueue.global` or `Task.detached`
- Agent packages defined in `knowledge/agents/<name>/agent.json`

## Testing

```bash
cd Kiteloop
# the standing check — compiles the app *and* the test bundles, runs nothing
xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing
```

```bash
./scripts/run-core-tests.sh            # the host-less core's tests — safe while the app runs
./scripts/run-unit-suite.sh            # the full unit suite, from any directory
./scripts/run-unit-suite.sh --dry-run  # print the commands it would run, start nothing
./scripts/run-unit-suite.sh --last     # the last measurement, and the drift since
```

- **`build-for-testing`, not `build`.** The scheme's BuildAction lists only
  `Kiteloop.app`, so plain `build` never compiles `KiteloopTests`.
- **Run the suite only through the script.** `KiteloopTests` is hosted by
  `Kiteloop.app`, so a test run launches a second Kiteloop and macOS kills the
  running one. The script refuses, starting nothing, while Kiteloop is running —
  and when `pgrep` could not answer at all.
- **The preflight runs before xcodebuild**, in the order `--dry-run` prints.
  A failure in one exits with that check's status, builds nothing and records
  nothing. Run
  `./scripts/check-target-membership.py` after adding a file from the command
  line: a `.swift` file missing from `project.pbxproj` is in no target, so it
  never fails — it goes silent.
- **`quality/` is cleat, vendored.** `python3 quality/bin/gate.py` runs every
  gate `quality.json` configures, each a ratchet over its baseline: complexity
  (no production function over cyclomatic 8 or 60 lines, `lizard` over app,
  package, companion and tooling), layering (Views/App > ViewModels > Services
  > Runtime > Models > Extensions, downward only, exemptions per root with a
  reason), doc-citations and reachability over `docs/features.md` and
  `Services/*`, test-hygiene (use `eventually`, `ControlServerHarness`,
  `makeTemporaryDirectory`), escapes, duplication, conventions, doc-size,
  guard-suites.
  `quality/bin/check-complexity.sh` and `quality/bin/check-features-map.py` are
  this repo's spellings of those gates, kept for the verify map and older
  `verify:` lines.
- **None over CRAP 8** — complexity the tests do not pay for,
  `cc² × (1 − coverage)³ + cc` — read off the last run's coverage by
  `quality/bin/check-crap.py`, a postflight after a green row, baseline in
  `Kiteloop/.crap-baseline.json`.
- **Only the script writes `docs/suite-status.md`.** Every finished run appends a
  row — tally, commit, result bundle, failing and skipped names, duration. A
  hand-written row is a fabricated measurement and a blocking review finding.
  A run that did not come back clean also keeps its full output under
  `.kiteloop/suite-logs/`.
- **Tests run in parallel** across host-app clones (`parallelizable` in the
  shared scheme, `-parallel-testing-enabled` in the script). A test owns its own
  temp directory and loopback port and never writes under `~/.kiteloop`.

- **Mutation testing over the package**: `./quality/bin/mutate.py <file>` flips
  operators one at a time and expects `swift test` to go red; a survivor is a
  path no test pins down. Not a preflight.

What each preflight check asserts and why: `docs/testing.md`.

## Common Tasks

- **Add a new agent package:** Create `knowledge/agents/<name>/` with agent.json + profile.md + knowledge/
- **Add a bundled avatar:** Drop PNG in `Assets.xcassets/<Name>.imageset/`, add to `AgentAvatarView.bundledAvatars`
- **Add a new setting:** Add field to `GlobalConfig` struct in `KiteloopCore/…/Services/GlobalConfig.swift`
- **Ship a build:** bump `MARKETING_VERSION` in **three** places that must not
  drift — the Debug and Release entries in `Kiteloop.xcodeproj/project.pbxproj`,
  and `Kiteloop/project.yml` (the XcodeGen spec `xcodegen generate` regenerates
  the pbxproj from) — and turn the
  `unreleased` heading in `CHANGELOG.md` into `## <version> — <date>`. The version
  is what `/health` and the About panel report, read from
  `CFBundleShortVersionString`. Patch for fixes, minor for new capability.
  `scripts/make-release.sh` refuses to build if the three sites disagree, and
  `--dry-run` rehearses the whole release without credentials; the signed,
  notarized path and its one-time setup are `docs/release-runbook.md`.
- **Add a control API endpoint:** Case in `ControlRoute` + row in `ControlRouter.table` (`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control/ControlRouter.swift`), arm in `dispatch(_:_:)`'s area handler + handler in `Services/Control/KiteloopControlServer.swift`; arm in `detail(for:)` + its family switch in `Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control/ControlAPISpec.swift` — that switch is exhaustive over `ControlRoute`, so a missing arm is a compile error, not an optional extra; add the endpoint to `ControlRouterTests.testEveryEndpointMatchesItsRoute`, a case to `KiteloopTests/Services/Control/KiteloopControlServer*Tests.swift`, and check it against `ControlAPISpecTests`; document it in `docs/control-api.md` (endpoint table + its own section), which `./scripts/check-control-api-docs.py` checks against the routing table
- **Add an autopilot setting:** Property + `Defaults` entry in `Services/BacklogAutopilot.swift`, field in its `AutopilotConfig` Codable (load/save), in `resetConfigToDefaults()` and in `isConfigAtDefaults` (enables Reset), a control in `Views/Settings/AutopilotRunSettingsForm.swift` if the page needs one, and the field in the `GET`/`PUT`/`reset` payloads in `KiteloopControlServer.swift` + `docs/control-api.md`

Driving the app headlessly (control API) and configuring autopilot for a
project: full reference `docs/control-api.md`; operational walkthrough
`docs/autopilot-runbook.md` (section B).

## Autonomy: ODD, Definition-of-Ready / Done, Review Rubric

Kiteloop runs the backlog unattended inside an **Operational Design Domain**;
see `docs/success-metrics.md` and `docs/adr/0001-autonomous-run-model.md`. Most
of what follows is enforced by a check, named beside the rule; the rest is
judgement the reviewer owes. The worker and reviewer read this every run.

**Definition-of-Ready** — enforced at pickup by `Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/DefinitionOfReady.swift`,
which names the failing clause: a groomed detail file with **What / How /
Validation**; a **`verify:`**, unless a verify-map rule matches
every path; **size ≤ M**; every **`needs:<id>`** on the
line `done` (an unknown id or cycle counts as unmet; the queue is never
reordered). An explicit **out-of-scope** list is a grooming rule — empty is
legitimate, so no check judges it. `GroundingCheck` refuses
a draft whose backticked paths and symbols name nothing in the repo.

**Writing a `verify:`** — three rules, each with a check behind it:
- It runs from the project root, so here the path is `Kiteloop/Kiteloop.xcodeproj`;
  write `cd "$(git rev-parse --show-toplevel)/Kiteloop" && …`. `GroundingCheck`
  refuses a path that resolves nowhere from the root.
- A pipe is written without spaces — `a --json|python3 -c '…'` — because a
  backlog line is split on `" | "`. `DefinitionOfReady` refuses a spaced pipe.
- An item that changes `Kiteloop/KiteloopCore/` declares `./scripts/run-core-tests.sh`
  beside whatever else it runs; the verify map (`kiteloop-verify.json`)
  refuses a diff that reaches the package without it. Those tests need no test
  host, so this is the one `verify:` that runs real tests.

**Definition-of-Done** — what the worker must satisfy:
- The `verify:` passes — and **a pass on an unchanged tree is not done**. The
  run is refused (`EmptyDiffHandoff`, `RunWorkEvidence`): either change files
  or say plainly that the item is already implemented and why. Refuting the
  item's `## Premise` with a measurement also ends a run — an
  **investigation**, judged on its own terms (`PremiseReport`).
- Only files the item implies change. Work outside the branch is refused as
  stray (`RunWorkEvidence.strayWork`).
- Tests added or updated for any change in behaviour. A change that alters
  none — docs, a comment, an ADR — has nothing to assert and must not invent a
  test. Its bar is accuracy against the code as it exists today.
- Nothing half-done; no TODO in place of an acceptance criterion.
- **Never write `docs/suite-status.md` by hand.** It is an instrument only
  `scripts/run-unit-suite.sh` writes; a diff touching it from an unrelated item
  is refused at the gate (`DiffRules`).
- A change in behaviour gets **one line in `CHANGELOG.md`** under the current
  `## <MARKETING_VERSION> — unreleased` heading (`### Added` / `### Fixes`),
  saying what changed for someone using the app — not the item id, files or
  reasoning. A diff that changes Swift and not `CHANGELOG.md` is noted on the
  item (`DiffRules`); whether behaviour changed is your call.

**Reviewer rubric** — block on any unmet:
1. `verify:` passes.
2. Scope: the diff matches What/How. Three failures here are **blocking**, and
   all three have shipped past a reviewer: the item said not to do something
   and the diff does it; the diff widens a default the item did not ask to
   widen (templates, presets, default lists); the diff touches
   `docs/suite-status.md` from an unrelated item.
3. Every acceptance criterion in Validation is met by the diff — checked one by
   one against the code, not against the run's summary of itself.
4. Tests present and meaningful for a change in behaviour; not demanded of a
   change with none, and a test invented to satisfy a checklist is a defect.
5. A documentation-only diff: accurate against the current code, covering what
   was asked, every command, path and symbol real — verified in the code.
6. Matches surrounding conventions.
7. Unmet → **reject with a specific reason**; never approve marginal work.

**The verdict** is JSON — `passed`, `reason`, optional `findings`, each with a
severity (`ReviewFindings` routes it):

```json
{"passed": false, "reason": "AC 3 is unimplemented",
 "findings": [{"severity": "blocking", "text": "AC 3 is unimplemented", "file": "Services/Foo.swift"},
              {"severity": "advisory", "text": "`n` reads oddly next to the names around it"}]}
```

`blocking` is rubric 7 — one rejects the run and the findings go to the next
worker pass. `advisory` is worth saying, not worth rejecting for — a nit, a
follow-up — and is written to the item's `## Notes` when the review passes.
Do not soften a blocking finding to let work through, nor raise a nit to make
a point.

**Scope discipline:** touch only what the item requires; propose a broad
refactor as a new item.

**Never run the app-hosted test suite during a run.** `KiteloopTests` is hosted
by `Kiteloop.app`, so `xcodebuild … test` launches a second Kiteloop and macOS
kills the running one, autopilot included. Verify with `build-for-testing` or
`./scripts/run-core-tests.sh`; a `PreToolUse` hook denies the test actions
while the app runs. To run the suite by hand, quit Kiteloop and use
`./scripts/run-unit-suite.sh`. How the hook works: `docs/testing.md`.

## Quality gates (cleat)

`python3 quality/bin/gate.py` runs every quality gate; it also runs when you
stop, and a failing gate is handed back to you as the next thing to fix. A
failure names the file, the line and what fixes it — split the function, give
the value its real type, make the test pass, handle the error.

Do not edit `quality.json`, anything under `quality/`, or the hooks to make a
gate pass, and do not run `--write-baseline`: the baselines record debt a
person accepted, and only a person loosens them, in a reviewed commit. The
gates only ever tighten; that is the point.

## Decisions log

A choice made, an assumption disproven or a rule set gets an entry appended to
`DECISIONS.md`, whose header gives the format and the public-repo rule. Only
what outlives the change; git records the change itself.
