# Setup Interview

## Before asking anything

Read what the repository already answers, so the person is not asked for it:

- the README and any contributor or agent instructions at the root
- the language, the build command and the test command
- whether there is a backlog, an issue list or a roadmap in the repository

## Questions

Ask one or two at a time. Skip any the repository or an earlier answer already settled.

**The project**
- What is this project for, and who uses what it produces?
- What does "done" look like for a piece of work here — tests pass, a review, a deploy?
- What is in progress or coming next?

**How you want to work**
- Which work do you want agents to do on their own, and which do you want to see first?
- Should anything run without you — overnight, daily, weekly?
- Is there anything agents must never touch: files, branches, services, accounts?

**The team**
- Which roles do you need: writing code, reviewing it, planning, research, writing, operations?
- Do you want one agent per role, or a small team to start and more later?
- Does any role need a stronger model, or is a faster, cheaper one enough?

**Routines**
- What should happen on a schedule, and when? A morning summary, a dependency check, a triage pass?
- For each one: which days, what time, and which agent runs it?

**Budgets**
- Do you pay per token or run on a subscription?
- Is there a limit a single session should stop at, and a limit for a day?

**Connectors**
- Which outside systems do the agents need to reach: an issue tracker, a code host, a database, documentation, a browser?
- Which of those are already set up in Kiteloop, and which need credentials you would enter yourself?

## The proposal

Write it once, in full, after the interview and after reading the project's current state. Keep it short enough to read in a minute.

```
## Proposal for <project>

What I understood: <two or three sentences>

### Team
| Agent | Role | Model | Tools | Status |
|---|---|---|---|---|
| <name> | <one line> | <model> | <read-only / can edit / operator tools> | keep / add / change: <what> |

### Routines
| Routine | Agent | When | What it does | Status |
|---|---|---|---|---|

### Budgets
- Session limit: <value, or "none"> — <why>
- Daily limit: <value, or "none"> — <why>

### Connectors
| Connector | Used by | Status | You need to |
|---|---|---|---|
| <name> | <agents> | exists / add | <nothing / enter a key in Settings> |

### Left as it is
- <anything that exists and the proposal does not touch>

### Not doing
- <anything asked about and deliberately left out, with the reason>
```

## Proposing well

- Start small. Two or three agents with clear roles beat a large team nobody watches.
- Give each agent the least it needs. An agent that only reads does not get edit tools; Operator tools go to an agent only when the person asks for it.
- A routine needs an agent, a schedule and a prompt that says what to produce. Do not propose one whose output nobody will read.
- When the person gives no budget, propose a modest one and say it is a starting point, rather than proposing none.
- Mark every row `keep`, `add` or `change`, so approving the proposal approves a known set of changes.

## Asking for approval

Ask with `ask_human`, and name the changes in the question itself: how many agents added or changed, which routines, which limits, which connectors. Apply only what that question named.
