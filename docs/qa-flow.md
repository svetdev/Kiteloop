# The QA flow

An item marked `flow:qa` on its backlog line runs through more than the
autopilot's worker and reviewer. It is for UI features, where "the tests pass"
is not the same as "a person can use it":

```
specify ──▶ worker ──▶ clean ──▶ harden ──▶ reviewer ──▶ qa ──▶ done
              ▲          │ fail     │ fail      │ reject    │ fail
              └──────────┴──────────┴───────────┴───────────┘
```

| Stage | What it does | Who runs it |
|---|---|---|
| `specify` | Turns the item into Given/When/Then acceptance scenarios and a QA procedure — numbered steps a person takes in the app, each saying what the screen must show — before any code is written | an agent with read-only tools |
| `worker` | The autopilot's worker, as for any item, told also to write the flow that walks the QA procedure at the profile's `spec` path, one screenshot per step | the project's worker |
| `clean` | The profile's `clean` command — complexity, CRAP, whatever the project's quality gates are. Omitted from the profile, no stage | shell, in the item's worktree |
| `harden` | The profile's `harden` command — mutation testing over the run's changes. Omitted, no stage | shell, in the item's worktree |
| `reviewer` | The autopilot's reviewer, unchanged | the project's reviewer |
| `qa` | Runs the profile's `run` command, which brings the app up from the item's tree and runs its flow; opens the storyboard and every screenshot; judges each step of the procedure as the person using the app would | an agent with read and shell tools, no edits |

Any stage that fails sends the work back to the worker with what failed: the
command's output, the reviewer's findings, or the QA report. QA answers with a
JSON object whose `qa_result` is `pass` or `fail` — its own key, because an edge
falls back to the run's state and the checks leave `result: pass` there. An
answer with no verdict passes nothing: the run ends `blocked` and the item's
Notes say QA gave no verdict. When the run ends
the QA report and the storyboard's path are written to the item's Notes, where
whoever approves it reads them.

The stages are added around the autopilot's own graph
(`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/QAFlowStages.swift`); the
worker and reviewer are the same nodes as in a standard run.

## Onboarding a project: `kiteloop-qa.json`

A project runs `flow:qa` items only once it has a `kiteloop-qa.json` at its
repository root, tracked in git so its commands are reviewed like any other
file. Without one — or with one that cannot drive a run — the
Definition-of-Ready refuses a `flow:qa` item and says which.

```json
{
  "run": "./scripts/qa/run-flow.sh {spec}",
  "smoke": "./scripts/qa/run-flow.sh apps/web/e2e/stack/qa/smoke.spec.ts",
  "spec": "apps/web/e2e/stack/qa/{id}.spec.ts",
  "storyboard": "apps/web/e2e/stack/storyboards/{id}.md",
  "clean": "./scripts/quality-preflight.sh",
  "harden": "./scripts/qa/harden-changed.sh",
  "guide": "Write the flow with the Story helper in apps/web/e2e/stack/story.ts …"
}
```

| Field | Required | Meaning |
|---|---|---|
| `run` | yes | Runs one flow from the repository root and leaves its storyboard behind. `{spec}` is replaced with the item's spec path |
| `smoke` | yes | Proves the harness works — the app comes up, a page opens, a screenshot is taken. What onboarding checks before the first QA run |
| `spec` | yes | Where an item's flow is written; `{id}` is the item id |
| `storyboard` | yes | Where the run leaves the item's storyboard; `{id}` as above |
| `clean` | no | The cleaner's command |
| `harden` | no | The hardener's command |
| `guide` | no | How to write a flow in this project, handed to the worker beside the QA procedure |

`run` should serialise itself if the project has one app instance to test
against: concurrent runs share it.

## Kiteloop's own QA flow

Kiteloop is onboarded with its own `kiteloop-qa.json`. A macOS app needs more
than a browser does, and three things make a QA run safe beside the Kiteloop
that is running the autopilot:

- **A separate app.** `scripts/qa/run-ui-flow.sh` builds with
  `KITELOOP_QA_SUFFIX=.qa` into `~/Library/Caches/kiteloop-qa/DerivedData`
  (`KITELOOP_QA_DERIVED_DATA` overrides it), so the app under test is
  `ai.kasatkin.kiteloop.qa` — a different bundle id, executable and set of
  preferences from the app running the autopilot.
- **Nothing to consent to.** The QA copy is ad-hoc signed and rebuilt every run,
  so macOS never remembers an "Allow" for it: any read under `~/Documents` would
  raise a prompt nobody is there to answer. Its build lives outside `~/Documents`,
  and with `KITELOOP_HOME` set it never walks up into the source checkout for
  agent packages (`KnowledgePathResolver`).
- **A throwaway home.** The QA copy is launched with `KITELOOP_HOME` set to an
  empty temporary folder, so every `~/.kiteloop` and `~/.claude` path it reads
  or writes is there, not in the user's home (`KiteloopHome`). A flow's base
  class, `QAStoryboardTestCase`, makes one itself when nothing is passed in.
- **Its own scheme.** The `Kiteloop` scheme skips the UI tests and Xcode refuses
  `-only-testing` for a skipped target, so QA runs use the `KiteloopQA` scheme.

A flow is a `final class` subclassing `QAStoryboardTestCase` in
`Kiteloop/KiteloopUITests/QA/<id>.swift`, registered with
`scripts/qa/register-ui-flow.py`, each procedure step wrapped in
`step("…") { … }`. `scripts/qa/write-storyboard.py` turns the screenshots the
run attached into `Kiteloop/KiteloopUITests/QA/storyboards/<id>.md`.

UI tests drive the screen. A Mac must allow automation mode without a password
prompt once — `sudo automationmodetool enable-automationmode-without-authentication`
in a terminal — or every run stops at "Timed out while enabling automation mode".
