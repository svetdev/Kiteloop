import Foundation

/// Which projects the Portfolio screen reads, as a plain list of root paths.
///
/// `~/.kiteloop/portfolio.md` — one project root per line. It is a file, and a
/// human-readable one, for the same reason every other piece of Kiteloop state
/// is: it can be read, edited and diffed without the app, and a portfolio
/// somebody types by hand is the point rather than a fallback.
///
/// Deliberately **not** the open-project registry. `ControlSessionRegistry` and
/// `ProjectStore` know what happens to be open right now, which changes every
/// time a tab is opened or closed; a portfolio is a standing statement about
/// which projects belong together, and it has to survive all of them being
/// closed. The registry can *seed* this file (`text(for:)`), but the file is
/// what is read afterwards.
///
/// It parses as markdown because it is named `.md` and someone will type
/// markdown into it: a `#` heading is a comment, and a `-`/`*` bullet in front
/// of a path is not an error. Nothing else is interpreted — a path is whatever
/// is left on the line.
package enum PortfolioList {

    /// Where the list lives. One per machine, beside the rest of `~/.kiteloop/`.
    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/portfolio.md")
    }

    /// The project roots a portfolio file names, in the order it names them.
    ///
    /// Paths come back tilde-expanded and canonicalized (`KiteloopProject.
    /// canonicalPath`), so `~/code/app`, `/Users/me/code/app` and
    /// `/Users/me/code/app/` are one project and are listed once. The first
    /// spelling wins, because a reader scanning the file expects the order they
    /// typed.
    ///
    /// Nothing here touches the filesystem: whether a path exists is a separate
    /// question, and `PortfolioBacklogs.load` is what answers it — a portfolio
    /// naming a project that is not mounted right now is still that portfolio.
    package static func parse(_ content: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for rawLine in content.components(separatedBy: .newlines) {
            guard let path = self.path(in: rawLine) else { continue }
            guard seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    /// One line's project root, or nil for a line that names none — blank, a
    /// `#` comment or heading, or a bullet with nothing after it.
    ///
    /// Only a line that *starts* with `#` is a comment. A trailing `#` is not
    /// stripped: `#` is a legal character in a directory name, and silently
    /// truncating a path at one would send the reader looking for a project
    /// under a prefix of the folder they named.
    package static func path(in rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        guard !line.isEmpty else { return nil }
        let expanded = NSString(string: line).expandingTildeInPath
        return KiteloopProject.canonicalPath(expanded)
    }

    /// The list as it stands on disk. A file that is not there yet is an empty
    /// portfolio, not an error — that is the state before anyone has written
    /// one, and the screen offers to seed it. The bytes decode lossily, so one
    /// that is not UTF-8 costs only its own line, not every project listed.
    package static func load(from url: URL = PortfolioList.defaultURL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// A starter portfolio file listing the given roots — what the empty state
    /// offers to write from the projects currently open.
    ///
    /// The preamble is the file's own documentation, so the next person to open
    /// it in an editor knows what it is and how to add to it without going
    /// looking for the app that reads it.
    package static func text(for paths: [String]) -> String {
        var out = """
        # Kiteloop portfolio
        #
        # One project root per line — the Portfolio screen reads this file and
        # shows those projects' BACKLOG.md items together. Lines starting with #
        # are ignored; `~` is expanded. Nothing here is ever written back to a
        # project's backlog.


        """
        for path in paths {
            out += path + "\n"
        }
        return out
    }
}
