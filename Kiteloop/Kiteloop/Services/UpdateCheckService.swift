import Foundation

/// The newest release the public repository has published.
struct LatestRelease: Equatable, Sendable {
    /// The tag as published — `v0.4.9`. Shown as GitHub spells it.
    let version: String
    /// The release page, which is where the download is.
    let url: URL
    /// The release's notes as published, trimmed; empty when GitHub has none.
    var notes: String = ""
}

/// What the update check has to say. `.idle` is also what a passive check that
/// found nothing leaves behind: staying quiet is a state, not a notice.
enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case available(LatestRelease)
    /// The check got no release to judge, and why — the notice says which.
    case unreachable(UpdateCheckFailure)
}

/// Why a check came back with no release. Each is a different sentence in the
/// notice: only the first means the Mac could not reach GitHub at all.
enum UpdateCheckFailure: Error, Equatable {
    /// No network, a timeout, or a status nothing below names.
    case endpointUnreachable
    /// GitHub answered 404: the repository has published no release yet.
    case noReleasePublished
    /// GitHub answered 403 or 429: it is limiting requests from this address.
    case rateLimited
    /// GitHub answered, and the answer was not a release this check can read.
    case malformedRelease

    /// The failure an HTTP status means; nil for 200, which is an answer.
    nonisolated static func forStatus(_ status: Int) -> UpdateCheckFailure? {
        switch status {
        case 200: return nil
        case 404: return .noReleasePublished
        case 403, 429: return .rateLimited
        default: return .endpointUnreachable
        }
    }
}

/// Tells the user, and nothing more: no download, no install, no framework.
/// Three ways in — the app menu's **Check for Updates…**, which always asks and
/// always answers; a passive check at launch that asks at most once a day and
/// speaks only when there is something newer; and the notice window itself,
/// which asks when it opens with nothing to show.
///
/// The fetch, the clock and the defaults are all injected, so the whole of this
/// runs without a network.
@MainActor
@Observable
final class UpdateCheckService {
    typealias Fetch = @Sendable () async throws -> LatestRelease

    /// The public repository's latest-release endpoint. In code rather than in
    /// `GlobalConfig`: there is one Kiteloop to update from — the repository
    /// the README tells people to clone — and a per-machine setting for it
    /// would be one nobody has a reason to change.
    nonisolated static let latestReleaseEndpoint = "https://api.github.com/repos/svetdev/Kiteloop/releases/latest"

    /// How long a passive check waits before consulting GitHub again.
    nonisolated static let passiveInterval: TimeInterval = 24 * 60 * 60

    nonisolated static let lastCheckDefaultsKey = "updateCheckLastAnswered"

    private(set) var state: UpdateCheckState = .idle

    /// The version this copy of the app reports — what the notice compares
    /// against and what it shows beside the published one.
    let installedVersion: String

    private let fetch: Fetch
    private let now: () -> Date
    private let defaults: UserDefaults

    init(currentVersion: String = UpdateCheckService.bundleVersion,
         fetch: @escaping Fetch = UpdateCheckService.gitHubFetch,
         now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        self.installedVersion = currentVersion
        self.fetch = fetch
        self.now = now
        self.defaults = defaults
    }

    /// The menu item. Always consults GitHub and always says what came back,
    /// including that it could not be reached.
    func checkNow() async {
        state = .checking
        state = await answer()
    }

    /// The window opening with nothing behind it. `.idle` and `.checking` are
    /// the same picture — a spinner and "Checking for updates…" — so a window
    /// restored at launch, or opened from the Window menu, would sit on that
    /// spinner forever with no check running. Asks only when there is nothing
    /// on screen yet; an answer already showing is left alone rather than
    /// re-fetched every time the window comes forward.
    func checkIfNothingToShow() async {
        guard case .idle = state else { return }
        await checkNow()
    }

    /// Launch. Silent throughout — nothing when the copy is current, nothing
    /// when GitHub cannot be reached, and no request at all when one already
    /// got an answer inside the last day. Returns whether there is a newer
    /// release for the caller to put on screen.
    @discardableResult
    func checkPassively() async -> Bool {
        guard isDue else { return false }
        guard case .available(let release) = await answer() else { return false }
        state = .available(release)
        return true
    }

    /// One consultation: the verdict on what GitHub said, or why there was
    /// nothing to judge. Only a release read records the day's check.
    private func answer() async -> UpdateCheckState {
        let release: LatestRelease
        do {
            release = try await fetch()
        } catch {
            return .unreachable(error as? UpdateCheckFailure ?? .endpointUnreachable)
        }
        defaults.set(now(), forKey: Self.lastCheckDefaultsKey)
        guard ReleaseVersion.isNewer(release.version, than: installedVersion) else { return .upToDate }
        return .available(release)
    }

    /// The day's allowance is spent by a check that got an answer, not by one
    /// that merely tried: a laptop opened before its network is up would
    /// otherwise burn the day on a request that never reached GitHub. A launch
    /// runs one passive check either way, so a failing endpoint is not hammered.
    private var isDue: Bool {
        guard let last = defaults.object(forKey: Self.lastCheckDefaultsKey) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.passiveInterval
    }

    /// What the About panel and `/health` report; `"dev"` in an unbundled
    /// build, which `ReleaseVersion` reads as no version at all — so a build
    /// run from Xcode is never told it is out of date.
    nonisolated static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// GitHub's `releases/latest`, which already excludes drafts and
    /// pre-releases, so what it returns is what a user should be offered.
    nonisolated static let gitHubFetch: Fetch = {
        guard let url = URL(string: UpdateCheckService.latestReleaseEndpoint) else {
            throw UpdateCheckFailure.endpointUnreachable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let failure = UpdateCheckFailure.forStatus((response as? HTTPURLResponse)?.statusCode ?? 0) {
            throw failure
        }
        do {
            return try UpdateCheckService.decodeRelease(data)
        } catch {
            throw UpdateCheckFailure.malformedRelease
        }
    }

    /// The fields of a release payload this check reads. `body` is optional:
    /// GitHub sends `null` for a release published without notes.
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
        }
    }

    nonisolated static func decodeRelease(_ data: Data) throws -> LatestRelease {
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let url = URL(string: payload.htmlURL) else { throw UpdateCheckFailure.malformedRelease }
        let notes = (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return LatestRelease(version: payload.tagName, url: url, notes: notes)
    }
}
