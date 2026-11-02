# Contributing to Kiteloop

Thanks for wanting to work on Kiteloop. This is the practical guide: how to get a
build, how to run the tests, where code goes, and the conventions a change is
expected to match.

Kiteloop is a native macOS app (Swift + SwiftUI) that spawns Claude Code CLI
subprocesses as agents. For *why* it is shaped the way it is, read
[`docs/how-kiteloop-works.md`](docs/how-kiteloop-works.md) first and
[`docs/architecture.md`](docs/architecture.md) second; for the autonomy rules
the agents themselves run under, read [`CLAUDE.md`](CLAUDE.md).

Kiteloop eats its own dog food: most items are executed by its autopilot (worker
agent → reviewer agent → human gate), which is why `CLAUDE.md` reads like a
contract. The same rules apply to a change made by hand.

## Prerequisites

| Tool | Install | Why |
|------|---------|-----|
| macOS 14+ | — | `MACOSX_DEPLOYMENT_TARGET` is 14.0 |
| Xcode 16+ | Mac App Store | Builds the app (`project.yml` pins `xcodeVersion: 16.0`); Swift 6 — `KiteloopCore/Package.swift` is `swift-tools-version: 6.0` |
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` | The agent runtime |
| Node.js 20+ | `brew install node` | Required by Claude Code |
| jq | `brew install jq` | The tracked `.claude/settings.json` hook uses it |
| lizard | `brew install lizard-analyzer` (or `pip install lizard`) — not `brew install lizard`, a compressor with the same binary name | What the suite's preflight complexity gate measures with, over Swift, Python and TypeScript; the preflight runs `gate.py --skip-missing-tools`, so a missing tool reports the gate as skipped, not failed |
| SwiftLint | `brew install swiftlint` | What the CRAP postflight reads function complexity from after a green suite run — CRAP is a complexity-vs-coverage score, `cc² × (1 − coverage)³ + cc`, computed by `quality/bin/check-crap.py` |
| XcodeGen (optional) | `brew install xcodegen` | Only for regenerating the Xcode project from its spec, a last resort — see [Adding files](#adding-files-to-the-project) |

You also need one way to authenticate to Claude: a Claude account (run `claude`
once and sign in), an Anthropic API key, or AWS Bedrock via SSO. Ollama covers
local-model-only use. [`Kiteloop/GETTING_STARTED.md`](Kiteloop/GETTING_STARTED.md)
walks through first launch and the setup wizard.

## Build and run

```bash
git clone https://github.com/svetdev/Kiteloop.git
cd Kiteloop/Kiteloop
open Kiteloop.xcodeproj      # scheme "Kiteloop", target "My Mac", Cmd+R
```

From the command line — this is the check every change must pass:

```bash
cd Kiteloop
xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing
```

Not plain `build`: the shared scheme's BuildAction lists only `Kiteloop.app`, so
`build` never compiles `KiteloopTests`. `build-for-testing` compiles the test
bundles too and runs nothing.

**Signing.** A fresh clone builds ad-hoc signed with no team, which is all a
local build needs. The settings live in `Kiteloop/Signing.xcconfig` (and
`KiteloopMobile/Signing.xcconfig` for the iOS companion), and each includes a
gitignored `Signing.local.xcconfig` beside it, so your own identity or team id
goes there and never into a commit:

```
# Kiteloop/Signing.local.xcconfig
CODE_SIGN_IDENTITY = Kiteloop Local Signing
```

Worth doing once you run agents unattended: macOS keys its permission grants to
the signing certificate, and an ad-hoc signature is new on every build — see
`docs/unattended-permissions.md`.

Dependencies resolve through SwiftPM on first build: `Highlightr` is the one
remote package, and `KiteloopCore` is local. `Package.resolved` is committed, so
the remote version is pinned.

## Tests

Tests live in `Kiteloop/KiteloopTests/`, mirroring the app's source directories
(`Models/`, `Runtime/`, `Services/`, `ViewModels/`, `Views/`). UI tests are in
`Kiteloop/KiteloopUITests/`. Almost all tests are XCTest (`final class …:
XCTestCase`); a couple use swift-testing (`import Testing`) — match whatever the
file next to yours uses.

Run the suite through the script — it is the only sanctioned way:

```bash
./scripts/run-unit-suite.sh            # the full unit suite, from any directory
./scripts/run-unit-suite.sh --dry-run  # print the commands it would run, start nothing
./scripts/run-unit-suite.sh --last     # the last measurement, and the drift since
./scripts/run-core-tests.sh            # the host-less core's tests — safe while the app runs
```

It runs the preflight checks first, refuses to start while Kiteloop is running
(see below), runs the app-hosted suite in parallel, and appends the measured row
to `docs/suite-status.md`. Underneath, what it runs is `xcodebuild … test`
with `-only-testing:KiteloopTests` from `Kiteloop/`; the raw forms are useful
for one class or one method, with the app quit:

```bash
cd Kiteloop

# one class, or one method
xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" \
    test -only-testing:KiteloopTests/KiteloopControlServerAutopilotTests

# the host-less core (Kiteloop/KiteloopCore) — no test host, so this is safe
# while the app is running; `--filter LineBufferTests` narrows it
(cd KiteloopCore && swift test)
```

The package's own tests (`ControlRouterTests`, `LineBufferTests`, …) are not in
`KiteloopTests`: they run under `swift test`, or `./scripts/run-core-tests.sh`
from any directory.

### Before you open a pull request

There is no hosted CI: every check runs on your Mac. A pull request should have
passed these, in this order:

```bash
./scripts/run-unit-suite.sh            # preflight, the full unit suite, the CRAP postflight
xcodebuild -project KiteloopMobile/KiteloopMobile.xcodeproj -scheme KiteloopMobile \
  -destination "platform=iOS Simulator,name=<a simulator you have>" \
  -only-testing:KiteloopMobileTests test   # the phone companion's tests
(cd copilot-bridge-extension && npm ci && npx tsc --noEmit -p .)   # if you touched the bridge
```

`xcrun simctl list devices available` names the simulators you have.

[`docs/suite-status.md`](docs/suite-status.md) is a committed instrument tape:
only `run-unit-suite.sh` writes it, one row per measured run, and a hand-written
row is a fabricated measurement. Every row is a run someone took on their own
Mac.

The shared scheme marks `KiteloopTests` parallelizable, so `xcodebuild … test`
spreads it over several clones of the app; the whole suite takes about two
minutes. A test that runs there owns its own temp directory
(`makeTemporaryDirectory()`) and loopback port (`ControlServerHarness`), waits
with `eventually { … }` rather than a fixed sleep, and never writes under
`~/.kiteloop`. The helpers both test targets share — `eventually`,
`makeTemporaryDirectory`, `ScriptedSubprocessRunner`, `RepositoryRoot` — live
once, in the package's `KiteloopTestSupport` target
(`Kiteloop/KiteloopCore/Tests/KiteloopTestSupport/`); `KiteloopTests/Support/`
re-exports that target and holds `ControlServerHarness`, which needs the app, and
`quality/bin/check-test-hygiene.py` keeps the old spellings from creeping back.

### Quit Kiteloop before running tests

`KiteloopTests` is **hosted by `Kiteloop.app`** (`TEST_HOST` / `BUNDLE_LOADER`,
bundle id `ai.kasatkin.kiteloop`). Running `xcodebuild … test` launches a second
Kiteloop as the XCTest host, and macOS terminates the instance you already have
running — including any autopilot run inside it.

A `PreToolUse` hook in [`.claude/settings.json`](.claude/settings.json) denies the
command for agent sessions while the app is running. It is a backstop, not a
policy: during an autonomous run, verify with `build-for-testing` — it compiles
the test bundles without launching a host, so it is safe while the app is
running — and let the harness run the item's `verify:` command. To run the full
suite by hand, quit Kiteloop first.

### Writing tests

- Test the service, not the UI. Most coverage sits in `KiteloopTests/Services/`
  and `KiteloopTests/ViewModels/`.
- Don't spawn a real `claude` process. `Kiteloop/Testing/MockAgentRuntime.swift`
  is an `AgentRuntime` stand-in that most orchestrator and chat tests use;
  `RecordingAgentRuntime` / `ReplayAgentRuntime` in `Kiteloop/Runtime/` cover
  record-and-replay of real sessions.
- Anything that touches the filesystem should write under a temp directory it
  creates and tears down — tests must not touch `~/.kiteloop/`.
- [`docs/features.md`](docs/features.md) maps each capability to the test that
  covers it. Keep it current when you add a feature: a row pointing at a file
  that is gone still reads as coverage somebody checked.
  `./quality/bin/check-features-map.py` fails, and says which row, when a cited path
  resolves nowhere. `scripts/run-unit-suite.sh` runs it as a preflight, so a
  suite run catches this whether or not you remember to — run it on its own for a
  quicker answer after moving or deleting a file it names.

### Adding files to the project

The tracked `Kiteloop/Kiteloop.xcodeproj/project.pbxproj` **is** the project —
it is what Xcode and `xcodebuild` read, and it is hand-edited.
`Kiteloop/project.yml` is a second copy kept in step by hand, not the source of
truth (its own header says so). The project does not discover files on its own:
if you add a Swift file from Xcode, Xcode registers it for you; if you add one any
other way (an editor, a script, an agent), register it in the pbxproj by hand —
or open Xcode and add it there — and then check:

```bash
python3 scripts/check-target-membership.py
```

`xcodegen generate` is a last resort, not a routine step: it overwrites the real
project with whatever the spec says and rewrites every id in the pbxproj, a
whole-file diff nobody can review (`templates/release.md` keeps it out of scope
for the same reason).

Skipping the registration is the single most common way a change silently does
nothing: an unregistered test file compiles nowhere and never runs, so the suite
stays green because the test is invisible rather than because it passed. Nothing
is in that state today — the check above says so.

It resolves every `.swift` file under `Kiteloop/`, `KiteloopTests/` and
`KiteloopUITests/` through `project.pbxproj` into some target's compile phase,
and names the files if any are missing. It finds the repo root itself, so it runs
from any directory; `scripts/run-unit-suite.sh` runs it at the head of its
preflight, before anything is built — behind only
`scripts/test-check-target-membership.py`, which asserts it, so a check that has
stopped matching this project's layout stops the run rather than vouching for
every file from inside it.

## Repo layout

```
kiteloop/
├── Kiteloop/                  # Xcode project
│   ├── project.yml            # XcodeGen spec, mirrored by hand from the tracked pbxproj
│   ├── Kiteloop/              # App source
│   │   ├── KiteloopApp.swift  # @main — config stores, runtime factory, control server
│   │   ├── AppDelegate.swift  # Menu bar, notifications, app lifecycle
│   │   ├── Models/            # Codable domain types (Agent, BacklogItem, KiteloopEvent, …)
│   │   ├── Services/          # Orchestrator, autopilot, stores, Control/ (HTTP API)
│   │   ├── Runtime/           # AgentRuntime implementations (Claude CLI, Ollama, Copilot)
│   │   ├── ViewModels/        # @Observable, @MainActor view models
│   │   ├── Views/             # SwiftUI, one subdirectory per surface
│   │   ├── Testing/           # Mocks the app target exports to tests
│   │   └── Resources/         # Assets.xcassets
│   ├── KiteloopCore/          # Host-less core: a local Swift package, tested under `swift test`
│   ├── KiteloopTests/         # Unit tests (mirrors the source tree)
│   ├── KiteloopUITests/       # UI tests
│   └── examples/agents/       # Bundled example agent packages
├── KiteloopMobile/            # iOS companion: drives the Mac's control API from a phone
├── knowledge/                 # Agent packages (agents/ starts empty) + schema
├── copilot-bridge-extension/  # VS Code extension exposing Copilot over a socket (experimental)
├── scripts/                   # run-unit-suite.sh, run-core-tests.sh, the preflight checks and their guard suites, check-target-membership.py, make-release.sh, kiteloop-verify.py, core-package/ movers
├── quality/                   # cleat, vendored: the quality gates `quality.json` configures (same author, same MIT licence)
└── docs/                      # Architecture, features, ADRs, runbooks
```

cleat's adoption guide — the config key by key, the ratchet, the tiers — is
[`quality/README.md`](quality/README.md).

Some entry points worth knowing: `Services/Orchestrator.swift` (agents, sessions,
event bus), `Runtime/ClaudeCodeCLIRuntime.swift` (subprocess + FIFO plumbing),
`ViewModels/ChatViewModel.swift` (per-agent message stream), and
`Services/BacklogAutopilot.swift` (the worker/reviewer loop).

## Conventions

**Concurrency.** `Orchestrator` is `@Observable @MainActor` and so are the view
models — never block it with synchronous I/O. Push work to `DispatchQueue.global`
or `Task.detached` and hop back for state updates.

**Observation.** Use `@Observable` for view models and services that drive UI, not
`ObservableObject`/`@Published` in new code.

**Placement.** SwiftUI views in `Views/` (grouped by surface), view models in
`ViewModels/`, everything else in `Services/`. Runtime implementations conforming
to `AgentRuntime` go in `Runtime/`. Codable domain types go in `Models/`, in a
file named after the type they define.

**Logging.** `os.Logger` with `subsystem: "ai.kasatkin.kiteloop"` and a category
naming the area — every logger in the app uses that subsystem. No `print` in
shipping paths.

**Persistence.** State is plain files, not a database: `~/.kiteloop/` for global
config, `.kiteloop/` inside a project for per-project state, all human-readable
JSON/JSONL/Markdown. Config that an unclean shutdown must not truncate goes
through `AtomicFileWriter` (`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/AtomicFileWriter.swift`,
as `GlobalConfigStore` does) rather than `Data.write(options: .atomic)`.

**Comments.** Doc comments explain *why* a thing exists and what breaks without
it — see `AtomicFileWriter` for the register. Don't narrate what the code already
says.

**Match the neighbourhood.** Naming, comment density and structure should look
like the file you are editing.

### Multi-file changes

Some changes have a fixed checklist because the state is spread across layers.
[`CLAUDE.md`](CLAUDE.md) ("Common Tasks") is the authoritative list; the two that
bite most often:

- **A control API endpoint** — case in `ControlRoute` + row in
  `ControlRouter.table`, dispatch arm and handler in `KiteloopControlServer.swift`,
  a row in `ControlRouterTests.testEveryEndpointMatchesItsRoute`, an endpoint test,
  and a section in [`docs/control-api.md`](docs/control-api.md).
- **An autopilot setting** — property + `Defaults` entry in `BacklogAutopilot`,
  field in its `AutopilotConfig` Codable (load/save), `resetConfigToDefaults()`,
  `isConfigAtDefaults`, and the field in the `GET`/`PUT`/`reset` payloads in
  `KiteloopControlServer.swift` plus `docs/control-api.md`. A control in
  `Views/Settings/AutopilotRunSettingsForm.swift` only if the setting earns one:
  the form deliberately shows eight (autonomy, worker, reviewer, budget, the
  merge-verify and worktree-setup commands, the verify map, pickup stages), and
  everything else is set over `PUT /v1/autopilot` or the config file.

## Documentation

Docs live in `docs/` and follow [Diátaxis](https://diataxis.fr) — each file says
which mode it is in and links to its siblings:

- *Explanation* — why something is the way it is (`architecture.md`,
  `worktree-isolation.md`)
- *How-to* — operating steps (`autopilot-runbook.md`)
- *Reference* — exhaustive surface (`control-api.md`)
- *Decisions* — `docs/adr/NNNN-title.md`, with Status / Deciders / Related, then
  Context → Decision → Consequences. An ADR may be amended in place with a dated
  `**Since (date):**` line under its Status, as 0001 and 0003 do, rather than
  rewritten

Two habits the existing docs keep and a new one should too: cite the implementing
file so a reader can check the claim, and verify commands and paths against the
code before writing them down. User-visible changes also get a `CHANGELOG.md`
entry under the current version's **Added** / **Changed** / **Fixed** heading.

## Working through the backlog

If you pick up a backlog item — by hand or by autopilot — the same rules apply.
The backlog runs inside an ODD (Operational Design Domain — the conditions under
which an unattended run is trusted; `docs/autonomy.md`):

- **Definition of Ready** — a groomed detail file with What / How / Validation, a
  `verify:` command, size ≤ M, explicit out-of-scope.
- **Definition of Done** — `verify:` passes; only the files the item implies are
  changed; tests added or updated for any change in behaviour (a docs-only change
  has no behaviour to assert — its bar is accuracy against the code instead);
  nothing left half-done.
- **Scope discipline** — touch only what the item requires. Opportunistic
  refactors belong in a new backlog item, not in this diff.

The full rubric, including what a reviewer blocks on, is in
[`CLAUDE.md`](CLAUDE.md#autonomy-odd-definition-of-ready--done-review-rubric).
Operational detail: [`docs/autopilot-runbook.md`](docs/autopilot-runbook.md) and
[`docs/worktree-isolation.md`](docs/worktree-isolation.md).

## Submitting a change

1. Branch off `main`. Autopilot uses `kiteloop/<item-id>`; anything descriptive is
   fine by hand.
2. Keep the diff scoped to one item, with the commit subject in the imperative
   mood.
3. Run the build (and the tests, with the app quit) before pushing.
4. Update the docs the change invalidates — `docs/control-api.md` for API surface,
   `docs/features.md` for a new capability, `CHANGELOG.md` for anything a user
   would notice.
5. Open a PR describing what changed and how you verified it.

## Licensing

Inbound = outbound: by opening a pull request you agree that your contribution is
licensed under the same [MIT License](LICENSE) the project ships under, with no
additional terms. There is no CLA to sign.

Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md). If you
have found a security vulnerability, don't open an issue — [`SECURITY.md`](SECURITY.md)
says where to send it.
