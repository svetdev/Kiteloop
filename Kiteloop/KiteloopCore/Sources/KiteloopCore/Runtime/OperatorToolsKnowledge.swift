import Foundation

/// The note appended to a spawned CLI's system prompt when its agent has the
/// "Operator tools" grant on (`Agent.operatorToolsEnabled`) — how to use the
/// `KITELOOP_OPERATOR_TOKEN` / `KITELOOP_CONTROL_URL` environment it was handed
/// alongside it. Bundled in the binary rather than a knowledge-package file, so
/// it ships with every install and cannot be left out of an agent that has no
/// package at all.
package enum OperatorToolsKnowledge {
    package static let note = """
    ## Operator tools

    Your environment carries `KITELOOP_OPERATOR_TOKEN` and `KITELOOP_CONTROL_URL` \
    — credentials for Kiteloop's local control API, the same surface the \
    operator's own terminal session drives to tweak configs, start runs, and \
    check on projects. When the operator asks you to do one of those things in \
    conversation, do it through the API rather than describing how they could.

    Every request needs the header `Authorization: Bearer $KITELOOP_OPERATOR_TOKEN`.

    Read first — before changing anything, and before answering "what's wrong \
    with `<project>`":
    - `GET $KITELOOP_CONTROL_URL/projects` — every open project: autopilot \
      readiness, what's running, queue depth
    - `GET $KITELOOP_CONTROL_URL/report` — the portfolio report: merged vs \
      filed, rejection causes, spend, per project
    - `GET $KITELOOP_CONTROL_URL/fleet/quiesce` — is anything on hold, and why
    - `GET $KITELOOP_CONTROL_URL/backlog?project=<p>` and \
      `GET $KITELOOP_CONTROL_URL/runs?project=<p>` — a project's queue and \
      recent runs, before touching either

    This token is authorized for the whole API except two endpoints: \
    `POST $KITELOOP_CONTROL_URL/backlog/approve` and \
    `POST $KITELOOP_CONTROL_URL/runs/{id}/approve`. Both answer **403** for \
    this token — resolving a human gate stays the operator's own call. If the \
    work is ready for sign-off, say so and let the operator approve it \
    themselves; do not look for another way to mark it done.

    Everything else works the same as it does for the operator's terminal \
    session: `PUT /autopilot` (worker/reviewer, budgets, consent flags), \
    `PUT /coordinator/refill` and `/coordinator/scheduling`, `POST /runs` \
    (start an item), `POST /runs/{id}/note` (steer a run in flight), \
    `POST /runs/{id}/cancel`, `POST /autopilot/pause` and `/resume`, \
    `POST /backlog/release`, `POST /agents` (hire a teammate), and every `GET`.

    Full reference: `docs/control-api.md`.
    """
}
