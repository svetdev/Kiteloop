# The clean-code loop

A workflow the app runs, built on Robert C. Martin's clean-code discipline
applied to agent-written code: a specifier, a coder, a cleaner, a hardener, a
reviewer, QA, a person.
The deterministic stages are tools that exit non-zero; the judgement stages
are agents; every failure loops back to the coder carrying the tool's own
output as its brief. It is a sibling of the improvement loop
(`start_improvement_loop`, which iterates implement → test → review and stops
when the review approves), with the three stages that make the difference
between "the tests pass" and "the code is clean".

```
specify ──▶ implement ──▶ verify ──▶ clean ──▶ harden ──▶ review ──▶ qa ──▶ human-gate ──▶ done
               ▲             │ fail     │ fail     │ fail       │ reject   │ fail       │ denied
               └─────────────┘          ▼          ▼            │          │            │
               ▲                      tidy    kill-survivors    │          │            │
               │                        └──▶ verify ◀──┘        │          │            │
               └────────────────────────────────────────────────┴──────────┴────────────┘
```

| Stage | What it is | Who / what runs it |
|---|---|---|
| `specify` | The request becomes Given/When/Then acceptance scenarios and a QA procedure a person could follow — before any code | the specifier agent, read-only tools |
| `implement` | The change and its tests, within the contract's scope and frozen paths | the coder, full tools |
| `verify` | The build and the tests | shell: the contract's `test_command` |
| `clean` | Complexity, layering, CRAP — whatever the command judges | shell: `clean_command` (default here: `check-complexity.sh && check-layering.py`) |
| `tidy` | Fixes exactly what `clean` named, then back through `verify` | the coder |
| `harden` | Mutation testing; a surviving mutant is a failure | shell: `harden_command` (here `mutate.py`); omitted → stage skipped |
| `kill-survivors` | A test per survivor, or the reason it is equivalent; back through `verify` | the coder |
| `review` | Scope, acceptance met in the code, tests meaningful, conventions — what a tool cannot judge | the reviewer, read-only |
| `qa` | Runs the specifier's procedure step by step and reports each | the QA agent, Bash but no editing |
| `human-gate` | A person accepts; denial returns to the coder | `humanApproval` edge, answered in the app or over the control API |

Breakers: each agent node has `maxTurns` and a timeout, the shell nodes a
timeout wide enough for a mutation run, the graph a global timeout and
`max_iterations` — visits to any one node — so a loop that keeps failing
`clean` ends as `failed` with the reason in `state._failureReason` rather
than running forever.

## Starting one

From a chat with any agent, the `start_clean_code_loop` tool:

```json
{"goal": "the backlog parser accepts `needs:` with spaces after the commas",
 "scope": ["Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/BacklogParser*.swift",
           "Kiteloop/KiteloopCore/Tests/**"],
 "frozen_interfaces": ["Kiteloop/KiteloopCore/Sources/KiteloopCore/Models/BacklogItem.swift"],
 "test_command": "./scripts/run-core-tests.sh",
 "clean_command": "./quality/bin/check-complexity.sh && ./quality/bin/check-layering.py --quiet",
 "harden_command": "./quality/bin/mutate.py Services/BacklogParser.swift",
 "implementer": "Builder", "reviewer": "Reviewer",
 "max_iterations": 6, "timeout_minutes": 90}
```

`specifier` and `qa` default to the reviewer; `require_human_approval`
defaults to true. The execution id it returns is a run id: `GET
/v1/runs/{id}` shows the current node and any pending approval question, and
`POST /v1/runs/{id}/approve` answers the gate (`docs/control-api.md`). The
graph is `CleanCodeLoopBuilder` (`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/`), asserted by
`CleanCodeLoopBuilderTests`: the order of stages, every failure edge, the
shell commands carried, the optional stages, the scopes, and every prompt's
placeholders substituted.

## What it does not do

It does not touch the autopilot. `BacklogAutopilot` runs its own
worker → reviewer graph over backlog items; this loop is started by a person
(through an agent) for a request written in prose, and ends at a human gate.
Moving backlog items through this pipeline is a decision for later, and a
one-line one once this has run for a while: the autopilot builds its graph
in one function.
