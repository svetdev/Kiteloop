import Foundation
import Security

package enum OTelIDs {
    package static func newTraceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        if bytes.allSatisfy({ $0 == 0 }) { bytes[15] = 1 }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    package static func newSpanID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
        if bytes.allSatisfy({ $0 == 0 }) { bytes[7] = 1 }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
