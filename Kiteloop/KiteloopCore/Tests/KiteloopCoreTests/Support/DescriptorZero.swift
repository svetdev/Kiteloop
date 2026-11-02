import Foundation

/// Runs `body` with descriptor 0 closed, so the next `open()` anywhere in the
/// process returns 0 — a perfectly valid descriptor, and the one a `fd > 0`
/// check written for `fd >= 0` mistakes for failure.
///
/// Stdin is put back afterwards. Whatever took 0 inside `body` may close it
/// from a queue of its own (a dispatch source's cancel handler), so the restore
/// waits until nothing in the process still holds 0 rather than putting stdin
/// underneath a close that has not run yet. A `body` that leaked 0 — which is
/// what the mutant under test does — costs that wait its whole timeout and is
/// then closed by the restore itself.
///
/// If 0 is already free when this is called there is nothing to do and
/// nothing to put back.
func withDescriptorZeroFree(_ body: () async throws -> Void) async throws {
    let stdin = dup(0)
    guard stdin >= 0 else {
        try await body()
        return
    }
    close(0)

    func restore() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while fcntl(0, F_GETFD) != -1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        dup2(stdin, 0)
        close(stdin)
    }

    do {
        try await body()
    } catch {
        await restore()
        throw error
    }
    await restore()
}
