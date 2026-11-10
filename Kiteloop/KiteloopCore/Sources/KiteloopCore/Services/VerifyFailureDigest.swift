import Foundation

/// The failing lines of a verify log, kept from the part its tail cuts off.
///
/// A captured verify keeps the end of its log, and the end of a long test run
/// is passing tests: on 2026-11-10 a refused land returned the last 16 KB of
/// 600 KB of `cargo test` output, and the names of the five failing tests and
/// their panics were all in what was dropped. Finding them meant running the
/// gate again by hand. This reads the dropped part once, a line at a time,
/// and keeps the lines that say what failed.
package enum VerifyFailureDigest {

    /// What marks a line as a failure in the tools a verify usually runs:
    /// cargo (`FAILED`, `panicked at`, `error[E…]`, `test result:`), compilers
    /// and xcodebuild (`error:`), XCTest (`' failed (`), pytest (`FAILED`,
    /// `ERROR `) and go test (`--- FAIL`). Matched as written — `FAILED` in
    /// capitals is a verdict, `failed` in prose usually is not.
    static let markers = ["FAILED", "--- FAIL", "panicked at", "error[", "error:", "ERROR ",
                          "test result:", "' failed ("]

    package static func isFailureLine(_ line: String) -> Bool {
        markers.contains { line.contains($0) }
    }

    /// The failure lines in the first `end` bytes of the file, in order, until
    /// `maxBytes` of them are kept — the same bound the tail has, so the
    /// digest can at most double what a refusal carries.
    ///
    /// Read in chunks rather than loaded: a build log's size must not matter.
    /// A line the cut at `end` lands inside is not judged; the tail holds its
    /// rest.
    package static func failureLines(inFileAt url: URL, upTo end: UInt64, maxBytes: Int) -> [String] {
        guard end > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var kept: [String] = []
        var budget = maxBytes
        var carry = Data()
        var offset: UInt64 = 0
        while offset < end, budget > 0 {
            let want = Int(min(UInt64(chunkBytes), end - offset))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            carry.append(chunk)
            let lines = completeLines(in: &carry)
            budget = keep(lines.filter(isFailureLine), into: &kept, budget: budget)
        }
        return kept
    }

    /// One read's worth — a pipe buffer, the unit the log was written in.
    static let chunkBytes = 65_536

    /// Splits off every whole line in `buffer`, leaving the unfinished last
    /// one behind for the next chunk to complete.
    static func completeLines(in buffer: inout Data) -> [String] {
        guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let whole = buffer[buffer.startIndex..<lastNewline]
        buffer = Data(buffer[buffer.index(after: lastNewline)...])
        // Lossy: a byte that is not UTF-8 costs itself, not the line.
        return String(decoding: whole, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Appends lines while they fit; the remaining budget, zero once one did
    /// not, so the reader stops instead of skipping ahead to shorter lines.
    static func keep(_ lines: [String], into kept: inout [String], budget: Int) -> Int {
        var remaining = budget
        for line in lines {
            let cost = line.utf8.count + 1
            guard cost <= remaining else { return 0 }
            kept.append(line)
            remaining -= cost
        }
        return remaining
    }

    /// `tail` with the failure lines of what it omitted set under its "earlier
    /// output omitted" line. Unchanged when the tail is the whole log or the
    /// omitted part held no failure line.
    package static func annotating(tail: String, ofFileAt url: URL, tailBytes: Int) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size]
                    as? NSNumber)?.uint64Value ?? 0
        guard size > UInt64(max(0, tailBytes)) else { return tail }
        let lines = failureLines(inFileAt: url, upTo: size - UInt64(tailBytes), maxBytes: tailBytes)
        guard !lines.isEmpty else { return tail }
        let block = "Failure lines in the omitted output (\(lines.count)):\n" + lines.joined(separator: "\n")
            + "\n… (the end of the output follows)\n"
        guard let newline = tail.firstIndex(of: "\n") else { return block + tail }
        let afterMarker = tail.index(after: newline)
        return String(tail[..<afterMarker]) + block + String(tail[afterMarker...])
    }
}
