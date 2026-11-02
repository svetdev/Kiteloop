import Foundation
import KiteloopCore

/// The checkout a test file belongs to.
///
/// A handful of tests read this repository itself — its templates, its CI
/// workflow — and used to find it by walking a fixed number of parents up from
/// `#filePath`. That number was the file's depth under `KiteloopTests/`, and
/// the day the tests were split into subfolders three of them opened
/// `Kiteloop/Kiteloop/templates/release.md` and a fourth skipped itself for
/// "no checkout to read". This walks up until it finds the `.git` entry — a
/// directory in a checkout, a file in a worktree — so a test file can live at
/// any depth.
package enum RepositoryRoot {
    package static func of(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path(percentEncoded: false)) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        preconditionFailure("no .git above \(file): this test reads the checkout it lives in")
    }
}
