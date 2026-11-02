import Foundation

/// What the settings sheet knows about work typed but not yet saved.
///
/// The sheet draws its detail through a `switch` over the selected page, so
/// picking another sidebar row destroys the page's view and every `@State` it
/// held, and pressing Done dismisses the sheet the same way. On the two
/// pages with their own Save button — Hooks and MCP Servers —
/// a half-written hook or server row went with it, silently. Each of those
/// pages reports here whether what is on screen still matches what it loaded,
/// and clears it in its own save path; the sheet asks this type whether a
/// navigation can go ahead.
@MainActor
@Observable
final class SettingsEditGuard {
    /// The page holding unsaved edits, or nil when nothing is dirty. Only one
    /// page is on screen at a time, so at most one can be dirty.
    private(set) var dirtyPage: ProjectSettingsPage?

    /// Where a navigation out of the current page is headed.
    enum Destination: Equatable {
        case page(ProjectSettingsPage)
        case done
    }

    /// What the sheet should do with a requested navigation.
    enum Decision: Equatable {
        /// Nothing is at stake: carry the navigation out.
        case proceed
        /// The named page has unsaved edits: ask before leaving it.
        case confirm(ProjectSettingsPage)
    }

    /// Whether `destination` can be navigated to without asking first.
    ///
    /// Leaving a dirty page is confirmed; leaving a clean one is not, so a
    /// sheet where nothing was typed behaves exactly as it did before. Picking
    /// the row that is already selected is not leaving anywhere, so it never
    /// asks.
    func decision(for destination: Destination) -> Decision {
        guard let dirtyPage else { return .proceed }
        if case .page(let target) = destination, target == dirtyPage { return .proceed }
        return .confirm(dirtyPage)
    }

    /// A page saying whether what it has on screen differs from what it loaded.
    func report(isDirty: Bool, for page: ProjectSettingsPage) {
        if isDirty {
            dirtyPage = page
        } else if dirtyPage == page {
            dirtyPage = nil
        }
    }

    /// Forgets the unsaved edits — what Discard does, and what a completed
    /// navigation leaves behind.
    func clear() {
        dirtyPage = nil
    }
}
