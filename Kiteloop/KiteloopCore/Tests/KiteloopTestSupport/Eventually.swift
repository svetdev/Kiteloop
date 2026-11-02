import Foundation
import KiteloopCore
import XCTest

/// Waits for a condition instead of sleeping a fixed time and hoping.
///
@MainActor
package func eventually(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(5),
    _ what: @autoclosure () -> String = "condition",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
        if try await condition() { return }
        if clock.now >= deadline {
            XCTFail("timed out after \(timeout) waiting for \(what())", file: file, line: line)
            return
        }
        try await Task.sleep(for: interval)
    }
}

/// The same wait, returning the value a producer eventually yields.
@MainActor
package func eventuallyValue<T>(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(5),
    _ what: @autoclosure () -> String = "value",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ produce: @MainActor () async throws -> T?
) async throws -> T {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
        if let value = try await produce() { return value }
        if clock.now >= deadline {
            XCTFail("timed out after \(timeout) waiting for \(what())", file: file, line: line)
            throw EventuallyTimeout(what: what(), timeout: timeout)
        }
        try await Task.sleep(for: interval)
    }
}

package struct EventuallyTimeout: Error, CustomStringConvertible {
    package let what: String
    package let timeout: Duration
    package var description: String { "timed out after \(timeout) waiting for \(what)" }
}
