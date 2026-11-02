import Foundation

/// The home folder Kiteloop keeps its state under: `~/.kiteloop`, and the
/// Claude Code settings, skills and plans it reads and writes in `~/.claude`.
///
/// The user's real home, unless `KITELOOP_HOME` names another folder. That is
/// what a QA copy of the app runs with: a UI test launches it pointed at a
/// throwaway home, so it never reads the user's projects and settings nor
/// writes over them. `HOME` cannot do this — Foundation answers
/// `homeDirectoryForCurrentUser` from the account record, not the environment.
///
/// What the user's own toolchain is looked up in — `claude`, `npm`, `cargo` on
/// the search path — and paths shown to the user as `~/…` stay on the real home.
package enum KiteloopHome {
    package static let variable = "KITELOOP_HOME"

    /// Where Kiteloop's state lives for this process.
    package static var url: URL { url(environment: ProcessInfo.processInfo.environment) }

    /// `KITELOOP_HOME` when it names an absolute path, else `fallback`.
    package static func url(environment: [String: String],
                            fallback: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let path = environment[variable]?.trimmingCharacters(in: .whitespaces),
              path.hasPrefix("/") else { return fallback }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
