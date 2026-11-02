import Foundation
import KiteloopCore
import XCTest

/// One spelling for "this test logs, and its lines are not the human's".
///
/// `KiteloopFileLogger.shared` is a singleton pointed at `~/.kiteloop` until a
/// project is opened, and a test process opens none — so every line a service
/// logs from a fixture (a store reporting a write it could not make, a token
/// file moved aside) used to be appended to the day's real log, the one a human
/// reads to debug the running app. A single `swift test` run added tens of
/// thousands of lines to it.
///
/// Two things keep those lines out of the human's log, and they answer
/// different questions. `KiteloopTestLogRedirect` — the C target this one
/// depends on — points the whole process at a temporary directory from a
/// load-time constructor, before any test runs, so a test that logs without
/// knowing it does still writes somewhere harmless. This helper is the other
/// half: a test that knowingly provokes log lines gives them a directory of its
/// own, which goes away with the test rather than outliving it.
package extension XCTestCase {
    /// Points `KiteloopFileLogger.shared` at a fresh temporary directory for the
    /// rest of this test, and back at `KiteloopFileLogger.defaultBaseURL()` when
    /// it ends — never at the home directory, which is what leaked the lines.
    ///
    /// Returns the base directory; the file itself lands under
    /// `<base>/.kiteloop/logs`, as it does for a project.
    @discardableResult
    func redirectSharedLoggerToTemporaryDirectory(prefix: String = "kiteloop-log") throws -> URL {
        let base = try makeTemporaryDirectory(prefix: prefix)
        addTeardownBlock {
            KiteloopFileLogger.shared.configure(projectURL: KiteloopFileLogger.defaultBaseURL())
        }
        KiteloopFileLogger.shared.configure(projectURL: base)
        return base
    }
}
