import Foundation

/// Turns a stream of arbitrarily-chunked reads into whole newline-delimited
/// lines.
///
/// Every pipe Kiteloop reads — the CLI's stream-json stdout, the permission
/// bridge's stderr, the tool bridge's request FIFO — carries newline-delimited
/// JSON, but a `read()` returns whatever bytes happen to be available. A single
/// read can end mid-line, and it can end mid-character: the boundary may land
/// between the bytes of a multi-byte UTF-8 sequence (any emoji or non-ASCII text
/// in an agent's output). Decoding such a chunk on its own fails, so buffering
/// has to happen at the byte level — decoding first and buffering the `String`
/// loses the whole chunk, complete lines included, whenever the split falls in
/// the wrong place.
package struct LineBuffer {
    package init() {}

    private static let newline = UInt8(ascii: "\n")

    private var buffer = Data()

    /// True when no bytes of an incomplete line are held.
    package var isEmpty: Bool { buffer.isEmpty }

    /// Appends a chunk and returns the lines it completes, in order. Empty lines
    /// and lines that are not valid UTF-8 are dropped; bytes after the last
    /// newline are held for the next call.
    package mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)

        var lines: [String] = []
        var lineStart = buffer.startIndex
        while let newlineIdx = buffer[lineStart...].firstIndex(of: Self.newline) {
            if let line = Self.decode(buffer[lineStart..<newlineIdx]) {
                lines.append(line)
            }
            lineStart = buffer.index(after: newlineIdx)
        }
        if lineStart != buffer.startIndex {
            buffer = Data(buffer[lineStart...])
        }
        return lines
    }

    /// Returns the unterminated trailing line, if any, and empties the buffer.
    /// Call this at EOF so a final line the writer never newline-terminated is
    /// still delivered.
    package mutating func flush() -> String? {
        defer { buffer = Data() }
        return Self.decode(buffer)
    }

    /// Decodes one line's bytes, tolerating a stray CR from a `\r\n` writer.
    private static func decode(_ bytes: Data) -> String? {
        var bytes = bytes
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
        guard !bytes.isEmpty else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
