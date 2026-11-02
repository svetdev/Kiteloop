import Foundation

/// How a surface names the project a mentioned item belongs to.
///
/// Two spellings, because the app's surfaces hold two. Most know a project's
/// root path — the autopilot, the backlog, a run record. The Coordinator's own
/// records address a project by folder name, the way the control API does, and
/// converting one into the other needs the list of open projects that resolution
/// is already walking. Accepting either here keeps that conversion in one place
/// instead of at every mention.
package enum ItemLinkProject: Hashable, Sendable {
    /// The project's root directory.
    case path(String)
    /// The project's folder name.
    case name(String)

    /// How the project reads in a refusal — the only place this is needed, since
    /// a project that *was* found is named from the project itself.
    package var displayName: String {
        switch self {
        case .path(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .name(let name): return name
        }
    }
}

/// Where "open item `<id>` in `<project>`" lands.
package enum ItemLinkDestination: Equatable, Sendable {
    /// Switch to this open project, land on its backlog surface, push the item's
    /// page. The project is named by id — what `MainWindow` keys its open
    /// projects and sessions on.
    case open(projectID: String, itemID: String)
    /// The project is known but not open. Open it at this path first, then land
    /// on the item. The start screen is the whole reason this case exists: it is
    /// only on screen with *nothing* open, so every mention it carries names a
    /// project that has to be opened before there is a backlog to land on.
    case openProject(path: String, itemID: String)
    /// There is no page to open, and why. The text names the id: a mention that
    /// has gone stale has to say *which* one went stale, which is the whole
    /// difference between a refusal and a click that appears to do nothing.
    case refused(String)
}

/// Resolves an item mention — an id plus the project that named it — to a
/// destination.
///
/// A value, deliberately: every surface in the app that names an item asks the
/// same question, and the answer depends only on which projects are open and
/// what their backlogs hold. Keeping it out of the window means the routing can
/// be asserted without one.
package enum ItemLinkResolver {

    /// One open project, reduced to what resolution needs.
    package struct OpenProject: Equatable, Sendable {
        /// `KiteloopProject.id` — the canonicalized root path.
        package let id: String
        /// The project's root directory, as the surfaces spell it.
        package let path: String
        /// The ids this project's backlog holds right now, or nil when the
        /// backlog has not been read yet. Nil is not "no items": a project whose
        /// backlog is still loading must not have its items declared missing, so
        /// an unread backlog routes and lets the page itself answer.
        package var itemIDs: Set<String>?

        package var name: String { URL(fileURLWithPath: path).lastPathComponent }

        fileprivate func matches(_ project: ItemLinkProject) -> Bool {
            switch project {
            case .path(let path): return id == KiteloopProject.canonicalPath(path)
            case .name(let name): return self.name == name
            }
        }

        fileprivate func holds(_ itemID: String) -> Bool {
            itemIDs?.contains(itemID) ?? false
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, path: String, itemIDs: Set<String>? = nil) {
            self.id = id
            self.path = path
            self.itemIDs = itemIDs
        }
    }

    /// A project the window knows of but does not have open — a recent. Enough
    /// of one to open it and land on the item.
    package struct ClosedProject: Equatable, Sendable {
        package let path: String

        package var name: String { URL(fileURLWithPath: path).lastPathComponent }

        fileprivate func matches(_ project: ItemLinkProject) -> Bool {
            switch project {
            case .path(let path):
                return KiteloopProject.canonicalPath(self.path)
                    == KiteloopProject.canonicalPath(path)
            case .name(let name):
                return self.name == name
            }
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(path: String) {
            self.path = path
        }
    }

    /// - Parameters:
    ///   - itemID: the id the mention carries.
    ///   - project: the project that named it, however that surface spells it.
    ///   - openProjects: every project open in the window right now.
    ///   - closedProjects: projects the window knows of but hasn't opened — the
    ///     recents. Searched only when nothing open matches, so an open project
    ///     is never re-opened over itself.
    package static func resolve(itemID: String,
                        in project: ItemLinkProject,
                        openProjects: [OpenProject],
                        closedProjects: [ClosedProject] = []) -> ItemLinkDestination {
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return .refused("That mention carries no item id, so there is nothing to open.")
        }
        let candidates = openProjects.filter { $0.matches(project) }
        guard !candidates.isEmpty else {
            if let closed = closedProjects.first(where: { $0.matches(project) }) {
                return .openProject(path: closed.path, itemID: id)
            }
            return .refused("\(id) is in \(project.displayName), which isn't open and "
                            + "isn't a project this window knows. Open that project "
                            + "and the item is on its backlog.")
        }
        // A folder name addresses two open checkouts of the same repo just as
        // happily as one. The candidate whose backlog actually holds the item is
        // the one that was meant; failing that, the first is as good an answer as
        // there is, and it is the one whose backlog the refusal below names.
        let match = candidates.first { $0.holds(id) } ?? candidates[0]
        guard match.itemIDs == nil || match.holds(id) else {
            return .refused("\(id) is no longer in \(match.name)'s backlog, "
                            + "so there is no item to open.")
        }
        return .open(projectID: match.id, itemID: id)
    }
}
