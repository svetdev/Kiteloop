import Foundation

/// Where a QA run's storyboard is kept once its worktree is gone. The QA agent
/// writes the page — and one screenshot per step, in a folder named after the
/// page without `.md` — inside the item's worktree, and the run removes that
/// worktree; copied out first, the note on the item can name a page that is
/// still there for whoever approves it.
package enum QAStoryboardArchive {
    /// `<home>/.kiteloop/storyboards/<item id>/<run id>/` — one folder per run,
    /// so a second run of the same item never writes over the first.
    package static func destination(home: URL = KiteloopHome.url, itemID: String, runID: String) -> URL {
        home.appending(path: ".kiteloop/storyboards", directoryHint: .isDirectory)
            .appending(path: itemID, directoryHint: .isDirectory)
            .appending(path: runID, directoryHint: .isDirectory)
    }

    /// Copies the page at `storyboard` (relative to `worktree`) and its
    /// pictures folder into `destination`, returning the kept page's URL. Nil,
    /// copying nothing, when there is no page to copy or the copy fails.
    package static func keep(storyboard: String, worktree: URL, into destination: URL) -> URL? {
        let fm = FileManager.default
        let path = storyboard.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = URL(filePath: path, relativeTo: worktree).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, fm.fileExists(atPath: page.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let pictures = page.deletingPathExtension()
        let keptPage = destination.appending(path: page.lastPathComponent)
        let keptPictures = destination.appending(path: pictures.lastPathComponent, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.copyItem(at: page, to: keptPage)
            if fm.fileExists(atPath: pictures.path(percentEncoded: false)) {
                try fm.copyItem(at: pictures, to: keptPictures)
            }
        } catch {
            return nil
        }
        return keptPage
    }
}
