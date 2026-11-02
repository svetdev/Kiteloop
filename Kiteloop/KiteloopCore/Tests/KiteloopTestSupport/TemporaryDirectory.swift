import Foundation
import KiteloopCore
import XCTest

/// One spelling for the temp directory most of the suite starts by creating.
///
package extension XCTestCase {
    /// A fresh, empty directory under the system temp root, deleted when the
    /// current test finishes. `prefix` is for a human reading `ls /tmp` mid-run.
    @discardableResult
    func makeTemporaryDirectory(prefix: String = "kiteloop-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

package enum TemporaryDirectory {
    /// The same directory for code that is not inside an `XCTestCase` — a helper
    /// type, a `static` fixture. The caller owns removal.
    package static func make(prefix: String = "kiteloop-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
