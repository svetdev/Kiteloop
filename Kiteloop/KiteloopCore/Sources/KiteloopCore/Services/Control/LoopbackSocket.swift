import Darwin
import Foundation
import os

/// A TCP listener bound to 127.0.0.1 and nothing else, on a plain BSD socket.
///
/// `NWListener` cannot do this. Asked for `requiredLocalEndpoint` 127.0.0.1 it
/// still collides with any socket on the same port — the pairing forwarder's on
/// the LAN and tailnet addresses — and fails with `EADDRINUSE`, so the control
/// API never came up while the forwarder was running. `bind(2)` on the loopback
/// address coexists with binds on the machine's other addresses.
package final class LoopbackListener {

    /// Why a listener did not come up, in one line: the call that failed and
    /// what the system said, e.g. `bind: Address already in use (errno 48)`.
    package struct Failure: Error, CustomStringConvertible {
        package let call: String
        package let code: Int32

        package var description: String {
            "\(call): \(String(cString: strerror(code))) (errno \(code))"
        }
    }

    private let acceptSource: DispatchSourceRead

    /// Opens the listening socket and binds it — synchronously, so a port
    /// someone else holds is a thrown `Failure`, not a later callback.
    /// `onConnection` runs on `queue` for every accepted client; `onCancel`
    /// once, after `cancel()` has closed the socket.
    package init(port: UInt16, queue: DispatchQueue,
                 onConnection: @escaping (SocketConnection) -> Void,
                 onCancel: @escaping () -> Void) throws {
        let fd = try Self.bindLoopback(port: port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { Self.acceptPending(on: fd, onConnection) }
        source.setCancelHandler {
            close(fd)
            onCancel()
        }
        acceptSource = source
        source.resume()
    }

    /// Closes the listening socket; clients already accepted are left to
    /// finish. Idempotent — a dispatch source cancels once.
    package func cancel() {
        acceptSource.cancel()
    }

    private static func bindLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        // SO_REUSEADDR lets a restart rebind past connections still in
        // TIME_WAIT. It does not let two listeners share 127.0.0.1:port — that
        // still fails with EADDRINUSE, which is how a second Kiteloop is refused.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw closing(fd, Failure(call: "bind", code: errno)) }
        guard listen(fd, SOMAXCONN) == 0 else { throw closing(fd, Failure(call: "listen", code: errno)) }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            throw closing(fd, Failure(call: "fcntl", code: errno))
        }
        return fd
    }

    private static func closing(_ fd: Int32, _ failure: Failure) -> Failure {
        close(fd)
        return failure
    }

    /// Accepts every client waiting on the socket. One readable event can stand
    /// for several, and the socket is non-blocking, so this stops at EAGAIN.
    private static func acceptPending(on fd: Int32, _ onConnection: (SocketConnection) -> Void) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            onConnection(SocketConnection(fileDescriptor: client))
        }
    }
}

/// One accepted TCP connection: bytes in as they arrive, bytes out in order,
/// and a single close. The `NWConnection` surface `HTTPServer` used, over a
/// file descriptor `DispatchIO` owns.
package final class SocketConnection: Sendable {

    private struct State {
        var cancelled = false
        var readEnded = false
        var readEndHandlers: [@Sendable () -> Void] = []
    }

    private let queue = DispatchQueue(label: "ai.kasatkin.kiteloop.control-connection")
    private let channel: DispatchIO
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Takes ownership of `fd`: it is closed when the connection is cancelled.
    package init(fileDescriptor fd: Int32) {
        // A write to a client that hung up must fail the write, not raise
        // SIGPIPE and take the app down.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        channel.setLimit(lowWater: 1)
    }

    /// Delivers every chunk the client sends, on the connection's queue, until
    /// the client hangs up or the connection is cancelled — then `onEnd` once,
    /// with the read error if there was one.
    package func startReading(onChunk: @escaping @Sendable (Data) -> Void,
                              onEnd: @escaping @Sendable (Error?) -> Void) {
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            if let data, !data.isEmpty { onChunk(Data(data)) }
            guard done else { return }
            self?.markReadEnded()
            // ECANCELED is our own cancel(), not something the client did.
            onEnd(error == 0 || error == ECANCELED ? nil : POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
        }
    }

    /// Runs `body` once the client has stopped sending — right away if it
    /// already has. How a stream learns its client is gone when nothing is
    /// being written to it.
    package func whenReadEnds(_ body: @escaping @Sendable () -> Void) {
        let alreadyEnded = state.withLock { state in
            if !state.readEnded { state.readEndHandlers.append(body) }
            return state.readEnded
        }
        if alreadyEnded { body() }
    }

    /// Writes `data` after everything sent before it; `completion` gets the
    /// error if the client is gone or the connection was cancelled.
    package func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: queue) { done, _, error in
            guard done else { return }
            completion(error == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
        }
    }

    /// Stops reading and writing and closes the socket. Idempotent.
    package func cancel() {
        let wasCancelled = state.withLock { state in
            defer { state.cancelled = true }
            return state.cancelled
        }
        guard !wasCancelled else { return }
        channel.close(flags: .stop)
    }

    private func markReadEnded() {
        let handlers = state.withLock { state in
            state.readEnded = true
            defer { state.readEndHandlers = [] }
            return state.readEndHandlers
        }
        for handler in handlers { handler() }
    }
}
