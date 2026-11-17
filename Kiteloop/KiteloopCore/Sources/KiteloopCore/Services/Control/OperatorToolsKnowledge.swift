import Foundation

/// The note appended to a spawned CLI's system prompt when its agent has the
/// "Operator tools" grant on (`Agent.operatorToolsEnabled`) — how to use the
/// `KITELOOP_OPERATOR_TOKEN` / `KITELOOP_CONTROL_URL` environment it was handed
/// alongside it. Bundled in the binary rather than a knowledge-package file, so
/// it ships with every install and cannot be left out of an agent that has no
/// package at all.
///
/// The list of endpoints is **derived from `ControlRouter.endpoints`**, each
/// line carrying the summary `ControlAPISpec` gives the route, so a route added
/// to the table reaches the note without anyone editing it. Only the framing —
/// the header, what to read first, the human gate — is written by hand. It
/// lives in the services layer because it reads the routing table; the runtime
/// is handed the text rather than reaching up for it.
package enum OperatorToolsKnowledge {

    /// Why the note leaves `route` out of the endpoints an agent may call, or
    /// nil when it lists it.
    package static func exclusionReason(for route: ControlRoute) -> String? {
        if route.isHumanGate { return "a human gate — answers 403 for the operator token" }
        if !route.requiresAuth { return "unauthenticated — not called with a bearer token" }
        if route.isTokenManagement { return "takes the full control token — answers 403 for the operator token" }
        switch route {
        case .registerPushDevice: return "phone-only — registers a phone for push notifications"
        case .registerLiveActivity: return "phone-only — a Live Activity's push token for one turn"
        default: return nil
        }
    }

    /// How the note names an endpoint: method and path relative to
    /// `$KITELOOP_CONTROL_URL`, which already ends in `/v1`.
    package static func citation(_ endpoint: ControlRouter.Endpoint) -> String {
        "\(endpoint.method) $KITELOOP_CONTROL_URL\(relativePath(endpoint))"
    }

    package static let note = [
        header,
        readFirst,
        "This token is authorized for the whole API except \(cited(where: \.isHumanGate)), " +
            "which answer **403** for this token — resolving a human gate stays the operator's own call. " +
            "If the work is ready for sign-off, say so and let the operator approve it themselves; " +
            "do not look for another way to mark it done.",
        "Listing, minting or revoking scoped tokens and webhooks — \(cited(where: \.isTokenManagement)) — " +
            "takes the control token itself and answers 403 for this token too.",
        "A call that changes configuration — hiring, editing or removing an agent, settings, autopilot, " +
            "routines, MCP servers, memory and knowledge, editing or deleting a backlog item — does not " +
            "apply until the operator approves it in the app: the request stays open, with no time limit, " +
            "until they answer. Say that you are waiting on their approval and give the call a long " +
            "timeout; a request cut off before the answer applies nothing, so ask again. " +
            "**403 \"declined by the person\"** means they said no — do not retry it or look for another route.",
        "Everything else works the same as it does for the operator's terminal session. Every path " +
            "below is relative to `$KITELOOP_CONTROL_URL`, which already ends in `/v1`. For query " +
            "parameters and request bodies read `GET $KITELOOP_CONTROL_URL/openapi.json`; the full " +
            "reference is `docs/control-api.md`.",
        endpointList,
    ].joined(separator: "\n\n")

    private static let header = """
    ## Operator tools

    Your environment carries `KITELOOP_OPERATOR_TOKEN` and `KITELOOP_CONTROL_URL` \
    — credentials for Kiteloop's local control API, the same surface the \
    operator's own terminal session drives to tweak configs, start runs, and \
    check on projects. When the operator asks you to do one of those things in \
    conversation, do it through the API rather than describing how they could.

    Every request needs the header `Authorization: Bearer $KITELOOP_OPERATOR_TOKEN`.
    """

    private static let readFirst = """
    Read first — before changing anything, and before answering "what's wrong \
    with `<project>`": `GET $KITELOOP_CONTROL_URL/projects`, \
    `GET $KITELOOP_CONTROL_URL/report` and `GET $KITELOOP_CONTROL_URL/fleet/quiesce`; \
    then `GET $KITELOOP_CONTROL_URL/backlog?project=<p>` and \
    `GET $KITELOOP_CONTROL_URL/runs?project=<p>` before touching a project's queue or runs.
    """

    /// The endpoints the note lists, grouped by the first path segment after
    /// `/v1` in the order the table first reaches each.
    private static var endpointList: String {
        let listed = ControlRouter.endpoints.filter { exclusionReason(for: $0.route) == nil }
        var groups: [String] = []
        var lines: [String: [String]] = [:]
        for endpoint in listed {
            let group = String(relativePath(endpoint).split(separator: "/").first ?? "")
            if lines[group] == nil { groups.append(group) }
            lines[group, default: []].append("- `\(citation(endpoint))` — \(ControlAPISpec.summary(for: endpoint.route))")
        }
        return groups.map { "### \($0)\n" + (lines[$0] ?? []).joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    /// The endpoints whose route matches `predicate`, cited and joined into a phrase.
    private static func cited(where predicate: (ControlRoute) -> Bool) -> String {
        let citations = ControlRouter.endpoints.filter { predicate($0.route) }.map { "`\(citation($0))`" }
        guard citations.count > 1, let last = citations.last else { return citations.first ?? "" }
        return citations.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func relativePath(_ endpoint: ControlRouter.Endpoint) -> String {
        let path = endpoint.templatedPath
        return path.hasPrefix("/v1/") ? String(path.dropFirst(3)) : path
    }
}
