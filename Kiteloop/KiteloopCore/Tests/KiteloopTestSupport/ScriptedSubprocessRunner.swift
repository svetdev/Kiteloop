import Foundation
import KiteloopCore
import XCTest

package final class ScriptedSubprocessRunner: SubprocessRunning, @unchecked Sendable {

    /// One call the app made. `timeout` is nil for `run`, set for
    /// `runWithDeadline`.
    package struct Call: Equatable {
        package let executable: String
        package let arguments: [String]
        package let directory: URL?
        package let environment: [String: String]?
        package let timeout: TimeInterval?
    }

    /// What the script answers a call with. The default is a child that exited 0
    /// and printed nothing.
    package struct Answer {
        package var status: Int32 = 0
        package var output: String = ""
        package var timedOut = false
        /// `run` throws as `Process.run()` does for a missing executable;
        /// `runWithDeadline` reports `(-1, "", false)` as the live runner does.
        package var spawnFails = false
        package init(status: Int32 = 0, output: String = "", timedOut: Bool = false, spawnFails: Bool = false) {
            self.status = status; self.output = output; self.timedOut = timedOut; self.spawnFails = spawnFails
        }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let script: @Sendable (Call) -> Answer

    package init(_ script: @escaping @Sendable (Call) -> Answer = { _ in Answer() }) {
        self.script = script
    }

    /// Every call so far, in order.
    package var calls: [Call] {
        lock.withLock { recorded }
    }

    package func run(
        executable: String,
        arguments: [String],
        directory: URL?,
        environment: [String: String]?,
        mergeStandardError: Bool
    ) throws -> SubprocessOutput.Result {
        let call = Call(executable: executable, arguments: arguments, directory: directory,
                        environment: environment, timeout: nil)
        lock.withLock { recorded.append(call) }
        let answer = script(call)
        if answer.spawnFails { throw CocoaError(.fileNoSuchFile) }
        return SubprocessOutput.Result(status: answer.status, standardOutput: Data(answer.output.utf8))
    }

    package func runWithDeadline(
        executable: String,
        arguments: [String],
        directory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval,
        discardStandardError: Bool
    ) -> (status: Int32, output: String, timedOut: Bool) {
        let call = Call(executable: executable, arguments: arguments, directory: directory,
                        environment: environment, timeout: timeout)
        lock.withLock { recorded.append(call) }
        let answer = script(call)
        if answer.spawnFails { return (-1, "", false) }
        if answer.timedOut { return (-1, answer.output + "\ntimed out after \(Int(timeout))s", true) }
        return (answer.status, answer.output, false)
    }
}

package extension XCTestCase {
    /// Runs `body` with `runner` installed as the app's subprocess runner, and
    /// puts the live one back whatever `body` did. `isolation` inherits the
    /// caller's actor, so a `@MainActor` test's closure stays on the main actor
    /// rather than being sent across an isolation boundary.
    func withScriptedSubprocesses<T>(
        _ runner: ScriptedSubprocessRunner,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        SubprocessOutput.runner = runner
        defer { SubprocessOutput.runner = LiveSubprocessRunner() }
        return try await body()
    }
}
