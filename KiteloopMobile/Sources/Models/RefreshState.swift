import Foundation

/// What a screen says about its own freshness, so a person never has to guess
/// whether to pull, wait, or fix something: it is refreshing right now, it was
/// updated so many seconds ago and will refresh itself again, or the last
/// refresh failed — and then what failed and what to do about it. Pure, so the
/// wording is pinned by tests.
struct RefreshState: Equatable {
    enum Phase: Equatable {
        case idle
        case refreshing
        case failed(ConnectionProblem)
    }

    var phase: Phase = .idle
    var lastSuccess: Date?
    /// How often the screen refreshes itself while it is up.
    let interval: TimeInterval

    init(interval: TimeInterval, phase: Phase = .idle, lastSuccess: Date? = nil) {
        self.interval = interval
        self.phase = phase
        self.lastSuccess = lastSuccess
    }

    var problem: ConnectionProblem? {
        if case .failed(let problem) = phase { return problem }
        return nil
    }

    /// The one line under the title: what is happening and whether waiting
    /// is enough. A failure's line is its title; the advice is shown beside it.
    func line(now: Date) -> String {
        switch phase {
        case .refreshing:
            return "Refreshing…"
        case .failed(let problem):
            return problem.title
        case .idle:
            guard let lastSuccess else { return "Not loaded yet — pull to refresh" }
            let age = Int(now.timeIntervalSince(lastSuccess).rounded(.down))
            let every = Int(interval)
            if age < 2 { return "Updated just now · refreshes every \(every)s" }
            if age > Int(interval * 3) { return "Updated \(age)s ago — later than it should be, pull to refresh" }
            return "Updated \(age)s ago · refreshes every \(every)s"
        }
    }

    /// True when the screen is behind and a pull is the right move — the
    /// auto-refresh has missed more than two of its own beats.
    func isStale(now: Date) -> Bool {
        guard phase == .idle, let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) > interval * 3
    }

    mutating func begin() { phase = .refreshing }

    mutating func succeed(at now: Date) {
        phase = .idle
        lastSuccess = now
    }

    mutating func fail(_ error: Error, host: String) {
        phase = .failed(ConnectionProblem.classify(error, host: host))
    }
}

/// A failed refresh, said in terms of what a person can do: the Mac cannot be
/// reached, the token was rejected, the Mac's app is older than this one, the
/// Mac answered with an error. `title` names it; `advice` says what to do.
struct ConnectionProblem: Equatable {
    enum Kind: Equatable {
        case unreachable
        case unauthorized
        case outdatedMac
        case serverError(Int)
        case unreadable
        case other
    }

    let kind: Kind
    let title: String
    let advice: String

    static func classify(_ error: Error, host: String) -> ConnectionProblem {
        if let urlError = error as? URLError, let problem = network(urlError, host: host) { return problem }
        if let status = (error as? HTTPStatusCarrying)?.httpStatus, let problem = http(status) { return problem }
        if error is DecodingError {
            return ConnectionProblem(
                kind: .unreadable,
                title: "The Mac answered something this app can't read",
                advice: "The two are probably different versions; update whichever is older.")
        }
        return ConnectionProblem(kind: .other, title: "Refresh failed", advice: error.localizedDescription)
    }

    /// The transport failures that all mean one thing to a person: the Mac
    /// is not reachable from here right now.
    private static func network(_ error: URLError, host: String) -> ConnectionProblem? {
        let unreachable: Set<URLError.Code> = [
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
            .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff, .secureConnectionFailed
        ]
        guard unreachable.contains(error.code) else { return nil }
        return ConnectionProblem(
            kind: .unreachable,
            title: "Can't reach the Mac at \(host)",
            advice: "Check Tailscale is connected on both ends and Kiteloop is running on the Mac, then pull to refresh.")
    }

    /// The Mac answered, and the status says what kind of answer it was.
    private static func http(_ code: Int) -> ConnectionProblem? {
        switch code {
        case 401, 403:
            return ConnectionProblem(
                kind: .unauthorized,
                title: "The Mac rejected this phone's token",
                advice: "Pair again: open the pairing sheet on the Mac and scan it from the Fleet tab.")
        case 404:
            return ConnectionProblem(
                kind: .outdatedMac,
                title: "The Mac's Kiteloop is older than this app",
                advice: "Update Kiteloop on the Mac; this screen asks for something it does not answer yet.")
        case 500...599:
            return ConnectionProblem(
                kind: .serverError(code),
                title: "The Mac answered with an error (\(code))",
                advice: "It retries on its own; pull to refresh to try now. If it keeps failing, look at the Mac.")
        default:
            return nil
        }
    }
}

/// An error that carries an HTTP status — the client's own error conforms,
/// so the classifier reads the status without knowing the client.
protocol HTTPStatusCarrying {
    var httpStatus: Int? { get }
}
