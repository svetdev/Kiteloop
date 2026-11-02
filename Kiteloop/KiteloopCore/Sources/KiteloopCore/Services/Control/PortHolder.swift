import Foundation

/// Who is listening on a TCP port — what Settings names beside "Not currently
/// listening", so a refused bind says which process to stop instead of
/// leaving the person to find it with `lsof`.
package enum PortHolder {

    /// One process with a listening socket on the port, and the addresses it
    /// holds it on (`127.0.0.1:4517`, `*:4517`).
    package struct Listener: Equatable, Sendable {
        package let pid: Int32
        package let command: String
        package let addresses: [String]

        package init(pid: Int32, command: String, addresses: [String]) {
            self.pid = pid
            self.command = command
            self.addresses = addresses
        }
    }

    /// Asks `lsof` for the listeners on `port`. Synchronous — call it off the
    /// main actor. Empty when nothing listens, when `lsof` cannot see the
    /// holder (another user's process) or cannot run at all: the caller then
    /// has nothing to add, not an error to report.
    package static func listeners(onPort port: UInt16) -> [Listener] {
        let result = try? SubprocessOutput.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"])
        guard let result, result.status == 0 else { return [] }
        return parse(fields: String(decoding: result.standardOutput, as: UTF8.self))
    }

    /// Reads `lsof -F pcn` output: a `p<pid>` line starts each process, `c`
    /// names it, and every `n` after it is one socket's address. Other field
    /// lines (`f<fd>`, which lsof always adds) are skipped.
    package static func parse(fields: String) -> [Listener] {
        var listeners: [Listener] = []
        var pid: Int32?
        var command = ""
        var addresses: [String] = []
        func flush() {
            if let pid { listeners.append(Listener(pid: pid, command: command, addresses: addresses)) }
        }
        for line in fields.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                flush()
                pid = Int32(value)
                command = ""
                addresses = []
            case "c": command = value
            case "n": addresses.append(value)
            default: break
            }
        }
        flush()
        return listeners
    }

    /// One line for a person: `Python (pid 1237) on 192.168.1.5:4517`, the
    /// processes joined with "; ". Nil when there is no one to name.
    package static func describe(_ listeners: [Listener]) -> String? {
        guard !listeners.isEmpty else { return nil }
        return listeners.map { listener in
            let name = listener.command.isEmpty ? "pid \(listener.pid)" : "\(listener.command) (pid \(listener.pid))"
            guard !listener.addresses.isEmpty else { return name }
            return "\(name) on \(listener.addresses.joined(separator: ", "))"
        }.joined(separator: "; ")
    }
}
