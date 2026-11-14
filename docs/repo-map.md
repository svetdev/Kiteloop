# Repo map

Every tracked file, and why it is here. Non-source files carry individual
justifications; Swift sources are grouped by subsystem, since what holds for
them is structural: every source file's top-level types are referenced by
production code reachable from the app entry point — the standing bar for
anything added: a file nobody can justify on this page is a file that
shouldn't be merged.

## Root

| File | Why it's here |
|---|---|
| `README.md` | Front door: pitch, features, quick start, How-it-works links |
| `CLAUDE.md` | Project instructions for agents and contributors: testing discipline, ODD / Definition-of-Ready & -Done, reviewer rubric, common tasks |
| `CHANGELOG.md` | One user-facing line per behavior change, newest first; heading tracks `MARKETING_VERSION` |
| `CONTRIBUTING.md` | Build, test and PR conventions |
| `DECISIONS.md` | Append-only log of choices, findings, disproven assumptions and rules that outlive the change itself, newest at the bottom |
| `CODE_OF_CONDUCT.md` | Contributor Covenant |
| `SECURITY.md` | Reporting channel and scope (control server, copilot bridge) |
| `LICENSE` | MIT |
| `llms.txt` | Machine-readable repo summary for LLM crawlers |
| `.gitignore` | Excludes `.kiteloop/` (all runtime state), dist, DerivedData |
| `.gitattributes` | `CHANGELOG.md merge=union`: every branch adds its one line at the top of the current section, so two finishing close together conflict there and nowhere else — union keeps both lines instead of stopping the merge |
| `.claude/settings.json` | Three hooks: a PreToolUse on `Bash` that denies `xcodebuild … test` and `… test-without-building` while the app runs — the test host would kill the running instance; a PreToolUse on `Bash|Edit|Write|MultiEdit` running `quality/bin/gate.py --guard`; and a Stop hook running `quality/bin/gate.py --hook --changed` |

## docs/

Living documentation only — pre-implementation sketches and dated internal
records don't belong here. `README.md` is the folder's index.

| File | Why it's here |
|---|---|
| `README.md` | The folder's index: one line per doc, grouped Start here / How it works / Operating / Reference / Decisions |
| `how-kiteloop-works.md` | **Start here.** The operating model: loops / instruments / agents, Planner + fleet, one ceiling, the trust ladder |
| `architecture.md` | The structural read: which boundaries are load-bearing and why — not a file inventory |
| `architecture-controls.drawio` | The picture: operator → arming gate → loops → one ledger → project pipeline |
| `autopilot-runbook.md` | How to operate it: in the app, headless via the API, gates, recovery, remote access |
| `control-api.md` | Every endpoint of the localhost control server |
| `how-work-flows.md` | The execution pipeline: worker → reviewer → gate → verified merge, and where money is bounded |
| `clean-code-loop.md` | The clean-code loop workflow and how to start one |
| `backlog-format.md` | The plan-file contract the parser implements |
| `backlog-branch.md` | The shared-backlog orphan-branch design (`kiteloop/backlog`, private checkout, sync) |
| `autonomy.md` | ODD and the machine-checked Definition-of-Ready clauses |
| `worktree-isolation.md` | What a run's isolated worktree creates and what survives it |
| `unattended-permissions.md` | Clearing macOS privacy prompts once, so unattended runs don't stall |
| `release-runbook.md` | Signed/notarized release mechanics — what `make-release.sh` and the release workflow link to |
| `success-metrics.md` | The autonomy SLOs and where each metric is measured |
| `testing.md` | What each preflight check asserts, and the test-host hook |
| `features.md` | Capability-to-test map, machine-checked by cleat's doc-citations and reachability gates |
| `suite-status.md` | **Instrument, not prose** — written only by `run-unit-suite.sh`; one row per measured suite run |
| `opening-context.md` | Where the opening-context cost figure comes from |
| `web-preview.md` | The sandboxed web preview's trust model |
| `adr/0001-autonomous-run-model.md` | ADR: sandbox → review → human gate |
| `adr/0002-embedded-localhost-control-server.md` | ADR: why the control server lives in-process |
| `adr/0003-run-sandboxing.md` | ADR: run sandboxing |
| `adr/0004-parallel-disjoint-runs.md` | ADR (proposed): parallel disjoint runs |
| `adr/0005-multi-repository-items.md` | ADR: one item across several repositories, one gate (proposed) |
| `repo-map.md` | This file |

## quality/

cleat, vendored: the quality gates as a template a project carries with it,
refreshed from the cleat checkout with `attach.py --refresh`, which replaces
the template's files — `bin/` and `tests/` wholesale — and keeps everything
else here; the two shims under `bin/` are restored with `git checkout --`
after a refresh. What is Kiteloop's own
lives outside the template: `quality.json` at the repository root, the
baselines it names, and the two shims below. Nothing under `bin/` names
Kiteloop except those shims. `python3 quality/bin/gate.py` runs every gate the
config configures; `quality/README.md` is the adoption guide.

| File | Why it's here |
|---|---|
| `README.md` | cleat's adoption guide: the config key by key, the ratchet, the tiers |
| `STRATEGY.md` | cleat's strategy: why these gates, in this order |
| `quality.example.json` | cleat's own config, as the documented example of every section |
| `escapes-baseline.json`, `duplication-baseline.json`, `conventions-baseline.json` | The escapes, duplication and conventions ratchets' baselines: the sites, the duplicated share and the convention sites that stood the day each gate was adopted, with the tool and config they were measured under |
| `complexity-baseline.json` | The complexity ratchet's baseline: the functions over cyclomatic 8 or 60 lines the day cleat was attached, keyed by file and declaration, with the tool and config they were measured under |
| `bin/gate.py` | The runner: every gate `quality.json` configures, `--postflight` for the ones that read a coverage run, `--hook` and `--guard` for the agent hooks, `--changed` to scope to a diff, `--stats` for what the hooks did |
| `bin/ratchet.py` | The one ratchet every gate shares: new, worsened, held, improved and stale findings against a baseline that carries its provenance |
| `bin/quality_config.py` | The loader every check reads the project's facts through: finds `quality.json` walking up, resolves its paths, fails naming a missing key |
| `bin/attach.py` | Attaches cleat to a project, or refreshes a vendored copy; writes the hooks and the instructions block |
| `bin/events.py`, `bin/runlock.py` | The hook and guard event log, and the running-registry a refresh refuses to replace underneath |
| `check-changed-coverage.py`, `check-complexity.py`, `check-conventions.py`, `check-crap.py`, `check-dead-symbols.py`, `check-doc-citations.py`, `check-doc-size.py`, `check-duplication.py`, `check-escapes.py`, `check-guard-suites.py`, `check-inventory.py`, `check-layering.py`, `check-manifests.py`, `check-public-api.py`, `check-reachability.py`, `check-sarif.py`, `check-test-hygiene.py` | The gates, one per file; which of them run here is `quality.json`'s to say — today doc-size, doc-citations, test-hygiene, guard-suites, complexity, layering, reachability, escapes, duplication, conventions, and CRAP as the postflight |
| `bin/extractors/`: `__init__.py`, `changed.py`, `churn.py`, `complexity.py`, `coverage.py`, `duplication.py`, `patterns.py`, `references.py`, `sarif.py`, `surface.py`, `wordcount.py` | Fact-finding with no judgment in it: complexity readers (lizard, SwiftLint), coverage readers (xccov, llvm-cov, LCOV, Cobertura), escape and convention patterns per language, references, duplication, churn, public surfaces, SARIF, word counts |
| `bin/mutate.py` | On demand: mutation testing over `KiteloopCore` — one operator flip at a time, `swift test` as the oracle, survivors named by line |
| `bin/report-hotspots.py` | On demand: ranks every measured function by churn × complexity — the refactor that pays, named by file and line |
| `bin/check-complexity.sh` | **Kiteloop's, not cleat's**: the complexity gate under the name the verify map, the chat tool's default clean command and every ready item's `verify:` call; runs `check-complexity.py` |
| `bin/check-features-map.py` | **Kiteloop's, not cleat's**: the retired features-map check under its old name, running the doc-citations and reachability gates that replaced it |
| `tests/harness.py`, `tests/run.sh` | The shared fixture harness, and the one-command run of every guard suite `quality.json` names |
| `test-quality-config.py`, `test-ratchet.py`, `test-gate.py`, `test-attach.py`, `test-conformance.py`, `test-check-doc-size.py`, `test-check-doc-citations.py`, `test-check-test-hygiene.py`, `test-check-guard-suites.py`, `test-check-complexity.py`, `test-check-layering.py`, `test-layering-imports.py`, `test-check-reachability.py`, `test-references-astgrep.py`, `test-check-crap.py`, `test-check-changed-coverage.py`, `test-check-escapes.py`, `test-check-conventions.py`, `test-check-duplication.py`, `test-check-dead-symbols.py`, `test-check-public-api.py`, `test-check-manifests.py`, `test-check-inventory.py`, `test-check-sarif.py`, `test-report-hotspots.py`, `test-mutate.py` | One suite per gate and per engine piece, each driving the real script over a throwaway tree; `tests/run.sh` runs every one and is their one `PREFLIGHT` entry in `run-unit-suite.sh` |
| `tests/fixtures/`: `sample.go`, `Sample.java`, `Sample.kt`, `sample.py`, `sample.rb`, `sample.rs`, `sample.sh`, `Sample.swift`, `sample.ts` | One sample per language for the conformance suite: what an escape, a convention site and a function look like in each |

## KiteloopMobile/

The iOS companion: observe and steer the Mac app over the tailnet through the
control API. Same conventions as the Mac app — `@Observable` view models, thin
SwiftUI views, one `ControlClient` service owning transport and SSE; the token
lives in the keychain. Two tabs (`KiteloopMobileApp.swift`): Projects — one
project at a time, its state, the one lever it offers, what waits on you, the
queue and the agents — and Fleet — quiesce state and its lever, planner passes,
the daily budget, the connection. The views under `Sources/Views/`:
`ConnectView` and `ScannerView` (pairing), `ProjectView`, `ProjectChipRow`,
`StatusCard`, `QueueListView`, `GateReviewView`, `ChatView`, `FleetView`,
`RefreshStatusBar`. `project.yml`
is the XcodeGen spec; transport for the companion's current stage is HTTP inside the tailnet
(WireGuard is the encryption) until `tailscale serve` adds TLS.

## scripts/

| File | Why it's here |
|---|---|
| `run-unit-suite.sh` | The suite runner: every preflight step in order (one of them `quality/tests/run.sh`, every cleat guard suite in one go), coverage on, refuses while the app runs, runs the app-hosted suite in parallel and reads the result bundle, appends the measured row, `--last` readout |
| `check-target-membership.py` | Preflight: a test file missing from the pbxproj compiles nowhere and stays silently green — this names them, across both the Kiteloop app project and the KiteloopMobile companion |
| `check-repo-map.py` | Preflight: a file under `scripts/`, `quality/` or `.github/` named nowhere in this file stays silently untracked-in-spirit — this names them |
| `check-doc-links.py` | Preflight: a relative Markdown link in the tracked docs that resolves to nothing — two shipped pointing at records that had been removed, and 404'd on GitHub; code is masked first, so an illustration of a link inside a fence or a code span is not one, and `http`, `mailto:` and bare-anchor targets are never resolved |
| `check-control-api-docs.py` | Preflight: `docs/control-api.md`'s endpoint index and section headings against `ControlRouter.swift`'s routing table — an undocumented route, a documented one nothing answers, a duplicated row, or a section with no row, each named by method and path |
| `check-companion-api-list.py` | Preflight: `KiteloopMobile/README.md`'s endpoint table against the `/v1/…` paths called from `KiteloopMobile/Sources` and against `ControlRouter.swift`'s routing table — a call with no row, a row nothing calls, or a path neither serves, each named |
| `run-core-tests.sh` | Preflight: the host-less package's tests under `swift test` — safe while the app runs |
| `export-coverage-lcov.py` | Postflight, after a green row: one LCOV file under `.kiteloop/coverage/` from the run's bundle (xccov's per-line view, app files only) and the package's profile data (llvm-cov's export, package files only) — what cleat's changed-coverage gate reads |
| `test-export-coverage-lcov.py` | Preflight: drives that export over saved inputs in a throwaway repository — executable lines kept with their counts, the package's shadow copies and the generated runner dropped, missing inputs refused by name |
| `core-package/core-pick.py`, `core-move.py`, `core-inits.py`, `core-check.py`, `pbx-register.py`, `test-move.py` | On demand: the next files that can move into `KiteloopCore` (`--blockers` for the files holding the most others out, `--why` for what holds one file out; `--app`/`--package` for a test to drive the candidate rule over a fixture tree), the move itself (package access, tests, pbxproj, imports, both baselines, the features-map citation, dead layering exemptions), the package memberwise inits the app needs (`--package DIR` for a test to drive it over a fixture tree), the moved tests that reach into the app — reported at the move, not at `swift test` — the pbxproj registration for the test that has to come back or the app-hosted half of a split one, and the app-hosted tests of package code that reference nothing app-side, listed and moved to where `swift test` runs them |
| `core-package/test-core-check.py`, `test-core-inits.py`, `test-core-move.py`, `test-core-pick.py`, `test-pbx-register.py`, `test-test-move.py` | Preflight: each on-demand mover's own test — `core-check.py`'s app-only-name reading, `core-inits.py`'s memberwise-init splice over a fixture tree, `core-move.py`'s file-selection pass and no-paths refusal without moving anything, `core-pick.py`'s candidate rule and `--why`/`--blockers` output over a fixture app/package pair, `pbx-register.py`'s register/unregister over fixture text keyed by path rather than basename, `test-move.py`'s destination mapping and its mkdir-before-git-mv fix — none moving anything for real. `test-move.py` itself stays on demand, not a preflight step: it is the mover, not a guard suite |
| `check-test-host-hook.sh` | Preflight: reads the PreToolUse pattern out of `.claude/settings.json` and asserts which xcodebuild commands it denies — `test` and `test-without-building` yes, `build-for-testing` no |
| `test-test-host-hook.sh` | Preflight: runs that hook end to end against a stub `pgrep` — the pattern being right is not the same as the hook denying, and a command laid out across backslash continuations used to slip past |
| `kiteloop-verify.py` | Headless control harness: smoke, single-run driver, marathon with scorecard |
| `make-release.sh` | Version- and bundled-resource-drift refusals, changelog extraction, sign → notarize → staple → zip → Sparkle update feed |
| `make-mobile-release.sh` | The phone app to TestFlight: version-drift and credential refusals, archive → export → upload |
| `verify-map-replay.sh` | Replays the verify-coverage rules against recorded runs |
| `qa/run-ui-flow.sh` | Kiteloop's QA flow (`kiteloop-qa.json` `run` and `smoke`): builds the QA copy (`KITELOOP_QA_SUFFIX=.qa`, own build folder), runs one UI flow through the `KiteloopQA` scheme against a throwaway `KITELOOP_HOME`, writes its storyboard — see `docs/qa-flow.md` |
| `qa/write-storyboard.py` | Turns the screenshots a QA flow attached, exported from its result bundle, into `KiteloopUITests/QA/storyboards/<id>.md` in step order |
| `qa/harden-changed.sh` | The QA flow's harden stage: `quality/bin/mutate.py` over the core package files the branch changed, and nothing else |
| `qa/register-ui-flow.py` | Registers a new QA flow in the `KiteloopUITests` target, so it compiles and runs instead of being silently in no target |
| `control-forwarder.py` | Binds the Mac's tailnet and LAN addresses and forwards to the loopback-only control server, so a phone on the same tailnet or Wi-Fi can reach it; kept alive across reboots and DHCP lease changes by a LaunchAgent |
| `install-control-forwarder.sh` | Installs (or `--uninstall`s) that LaunchAgent for real: copies `control-forwarder.py` to `~/.kiteloop/bin`, writes `~/Library/LaunchAgents/ai.kasatkin.kiteloop-forwarder.plist`, and bootouts/bootstraps it through `launchctl`; `--dry-run` prints the plan and touches nothing |
| `test-check-target-membership.py`, `test-check-repo-map.py`, `test-check-doc-links.py`, `test-run-unit-suite.sh`, `test-kiteloop-verify.py`, `test-run-core-tests.sh`, `test-make-release.sh`, `test-make-mobile-release.sh`, `test-control-forwarder.py`, `test-install-control-forwarder.sh`, `test-verify-map-replay.sh`, `test-check-control-api-docs.py`, `test-check-companion-api-list.py` | The guard suites: each asserts its production script's readers and refusals without building; all are suite preflight steps — `test-install-control-forwarder.sh` against a temp `HOME` and a stub `launchctl` |

## .github/

No workflows: the repository runs no hosted CI, and every check runs on a Mac (`CONTRIBUTING.md`).

| File | Why it's here |
|---|---|
| `PULL_REQUEST_TEMPLATE.md`, `bug_report.md`, `feature_request.md`, `ISSUE_TEMPLATE/config.yml` | Contribution templates, including a secrets-redaction warning; the chooser config turns blank issues off and points security reports at `SECURITY.md` |

## knowledge/ · templates/ · design/ · examples

| Path | Why it's here |
|---|---|
| `knowledge/README.md` | How to define agent packages |
| `knowledge/schema/agent-schema.json` | The `agent.json` contract (`AgentPackage.swift`) |
| `knowledge/agents/.gitkeep` | agents/ starts empty by design — the bundled examples cover a fresh clone |
| `knowledge/.gitignore` | Keeps the retrieval index `KnowledgeIndex` writes beside the packages (`.index/`) out of git, along with `.DS_Store` and `*.tmp` — it is derived from the Markdown and rebuilt, so committing it would version a cache |
| `templates/release.md` | Backlog template for cutting a release; stamped via the templates endpoint, read end-to-end by its tests |
| `design/kiteloop-logo.svg`, `design/kiteloop-icon.svg` | README logo; app-icon source |
| `Kiteloop/examples/agents/*` | Two bundled example agents, loaded at runtime |

## copilot-bridge-extension/

Experimental VS Code extension exposing Copilot's models over a local socket
for `CopilotBridgeRuntime`. TypeScript sources, manifests, and its own build
README; `out/` is ignored.

## Kiteloop/Kiteloop/ — app sources

Grouped by subsystem; every file passed the reference sweep.

- **Models (15)** — value types the app persists or passes around:
  `KiteloopProject` (config, paused/goal), the agent identity types,
  `BacklogItem` and friends, `TeamConfig`, the metric types,
  `NotificationItem`, workflow graph types.
- **Services (83) — the machine.**
  *The plan:* `BacklogParser` (+ the shared-branch layer), `DefinitionOfReady`,
  `GroundingCheck`, `BacklogTemplate`, `QueueHealth`.
  *The Planner:* `CoordinatorQueueRefill`/`QueueRefill` (loop + pure policy),
  `CoordinatorAdvisor`/`CoordinatorKnowledge`, `CoordinatorBlockedTriage`,
  the panel/starts models.
  *The fleet:* `CoordinatorRunScheduler`/`RunScheduling` (starts longest-idle-
  first, holds, refusal memory; a project's paused switch is never started),
  `AutonomyArming`/`AutonomyLadder`, `FleetQuiesce*`,
  `DailyBudget`/`CostGovernor` (the money).
  *The pipeline:* `BacklogAutopilot` (worker → reviewer → gate → merge),
  `WorktreeManager`, `VerifyCoverage`, `RunQualityJudge`, `EmptyDiffHandoff`,
  `RunKnowledgeDistiller`, the item dossier/history.
  *The control server:* `Services/Control/` — router, spec, HTTP server,
  session registry, run records, fleet quiesce.
  *Infrastructure:* orchestrator, event bus, the stores (notifications,
  traces, metrics + SQLite index), atomic writes, the
  workflow engine.
- **Views (79)** — `MainWindow` (tabs, sidebar, footer, portfolio),
  `Backlog/` (editor, item page, Autopilot panel), `Portfolio/` (Planner
  panel & drawer, fleet drawer + board, the ladder), `Chat/`, `Settings/`,
  `MenuBar/`, `Components/`.
- **ViewModels (11) · Runtime (10) · Testing (2)** — chat,
  backlog and session view models; the agent runtimes (Claude CLI with the FIFO
  tool bridge, Ollama, Copilot bridge, record/replay harness);
  the mock runtime and UI-testing support the app and tests share.
- **Resources** — `Assets.xcassets` (AppIcon, accent color).

## Tests

`KiteloopTests/` mirrors the source layout, with `Services/` split by subsystem
(`Control/`, `Autopilot/`, `Backlog/`, `Coordinator/`, `Workflow/`, `Metrics/`,
`Agents/`, `Sessions/`) and the shared helpers in `Support/`; every test file's
subject exists. `KiteloopCore/` is the host-less core — a local Swift package
the app depends on, with its own tests under `swift test` (`docs/testing.md`).
The replay fixture JSONs drive the capture-replay tests. `KiteloopUITests/`
is a real registered target with live subjects, but nothing runs it headless
— unmeasured coverage, kept knowingly.

## Project plumbing

| File | Why it's here |
|---|---|
| `Kiteloop/project.yml` | XcodeGen spec, mirrored by hand from the tracked pbxproj — its header says it is not the source of truth |
| `Kiteloop/.gitignore` | Xcode's own leavings ignored beside the project it generates them next to — `DerivedData/`, `build/`, `xcuserdata/`, `*.xcuserstate`. Every pattern is also in the root file, so this one matters only to a tool reading `Kiteloop/` on its own |
| `Kiteloop/Kiteloop.xcodeproj/*` | The project Xcode reads, hand-edited, the shared scheme (`KiteloopTests` parallelizable), workspace, `Package.resolved` (pins Highlightr, the one remote package; `KiteloopCore` is local) |
| `Kiteloop/Kiteloop/Kiteloop.entitlements` | Sandbox entitlements |
| `Kiteloop/GETTING_STARTED.md` | The first-hour walkthrough |
