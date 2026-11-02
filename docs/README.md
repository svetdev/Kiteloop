# docs/

One line per file, so a reader landing here has a map. Every document is
written against the code as it exists; where a claim can be checked, the
implementing file is cited.

## Start here

- [how-kiteloop-works.md](how-kiteloop-works.md) — the operating model in one read: loops you configure, instruments you read, agents you talk to; the Planner fills the plan, the fleet works it
- [architecture-controls.drawio](architecture-controls.drawio) — the picture: operator → arming gate → loops → one ledger → project pipeline

## How it works

- [architecture.md](architecture.md) — the structural read: which boundaries are load-bearing and why, not a file inventory
- [how-work-flows.md](how-work-flows.md) — who decides what gets built, who builds it, and who lets it into `main`
- [autonomy.md](autonomy.md) — what stops a bad run reaching `main`, and what stops a run reporting success it did not earn; the ODD and the Definition-of-Ready
- [worktree-isolation.md](worktree-isolation.md) — how an item runs in its own git worktree: what is created, what the agents see, what survives
- [backlog-branch.md](backlog-branch.md) — the shared backlog on an orphan branch (`kiteloop/backlog`) and its private checkout
- [clean-code-loop.md](clean-code-loop.md) — the clean-code loop workflow and how to start one
- [opening-context.md](opening-context.md) — where the opening-context cost figure comes from
- [web-preview.md](web-preview.md) — the sandboxed web preview's `web_*` tools and their trust model

## Operating

- [autopilot-runbook.md](autopilot-runbook.md) — running autopilot in the app and headless, the gates, recovery, measuring a marathon, remote access and the pairing forwarder
- [unattended-permissions.md](unattended-permissions.md) — the one-time macOS TCC setup so no privacy dialog fires mid-run
- [release-runbook.md](release-runbook.md) — the signed, notarized release and its one-time setup
- [testing.md](testing.md) — what each preflight check asserts, and the hook that keeps the test host from killing the running app
- [suite-status.md](suite-status.md) — an instrument, not prose: one row per measured suite run, written only by `scripts/run-unit-suite.sh`

## Reference

- [control-api.md](control-api.md) — every endpoint of the loopback control API
- [backlog-format.md](backlog-format.md) — the `BACKLOG.md` contract as the parser implements it
- [features.md](features.md) — the capability-to-test map, machine-checked against the tree
- [success-metrics.md](success-metrics.md) — the four SLIs, their SLO targets and the error budget; the baseline is still unmeasured
- [repo-map.md](repo-map.md) — every tracked file and why it is here

## Decisions

- [adr/0001-autonomous-run-model.md](adr/0001-autonomous-run-model.md) — sandbox → review → human gate, rather than an agent editing the live tree
- [adr/0002-embedded-localhost-control-server.md](adr/0002-embedded-localhost-control-server.md) — why headless drive is an embedded loopback HTTP server
- [adr/0003-run-sandboxing.md](adr/0003-run-sandboxing.md) — run sandboxing: what enforcement below the prompt is worth building
- [adr/0004-parallel-disjoint-runs.md](adr/0004-parallel-disjoint-runs.md) — parallel disjoint runs (proposed; no enforcement code shipped)
