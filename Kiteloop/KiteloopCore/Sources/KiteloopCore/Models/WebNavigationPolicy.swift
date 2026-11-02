import Foundation

/// Which content the web preview pane is allowed to load.
package enum WebPreviewMode: String, Sendable, CaseIterable {
    /// Local content only — `file://` and `localhost`. Safe to auto-load.
    case trusted
    /// Arbitrary real sites, for inspection. Agent-driven loads are gated.
    case external
}

/// Who initiated a navigation. Human URL-bar entry and in-page clicks are
/// `user`; agent- or code-requested loads are `programmatic`.
package enum WebNavigationSource: Sendable {
    case user
    case programmatic
}

package enum WebNavigationDecision: Equatable, Sendable {
    case allow
    case deny
    /// External + agent-initiated + not allowlisted — ask the human first.
    case confirm
}

/// Pure navigation gate for the web preview pane. Kept free of WebKit so it can
/// be unit-tested without a live `WKWebView`.
package enum WebNavigationPolicy {
    package static func decide(
        mode: WebPreviewMode,
        url: URL,
        source: WebNavigationSource,
        allowlist: Set<String>
    ) -> WebNavigationDecision {
        guard let scheme = url.scheme?.lowercased() else { return .deny }

        // Local rendering primitives are always fine.
        if scheme == "file" || scheme == "about" { return .allow }
        guard scheme == "http" || scheme == "https" else { return .deny }

        let host = url.host?.lowercased()
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"

        switch mode {
        case .trusted:
            // Only local content; everything else is walled off.
            return isLocal ? .allow : .deny
        case .external:
            if isLocal { return .allow }
            if source == .user { return .allow }
            // Agent/programmatic external navigation is gated.
            if let host, allowlist.contains(host) { return .allow }
            return .confirm
        }
    }
}
