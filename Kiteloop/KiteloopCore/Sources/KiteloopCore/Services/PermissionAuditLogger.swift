import Foundation
import os.log

package final class PermissionAuditLogger: Sendable {
    package static let shared = PermissionAuditLogger()

    private let logger = Logger(subsystem: "ai.kasatkin.kiteloop", category: "permission-audit")

    package enum PermissionType: String, Sendable {
        case filePanel
        case notification
        case bookmark
        case subprocess
    }

    package func log(_ type: PermissionType, purpose: String, caller: String = #function, file: String = #file) {
        let filename = (file as NSString).lastPathComponent
        let entry = "[\(type.rawValue)] \(purpose) — \(filename):\(caller)"
        logger.info("\(entry, privacy: .public)")
        kiteloopLog(entry, category: "permission-audit")
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init() {
    
    }
}
