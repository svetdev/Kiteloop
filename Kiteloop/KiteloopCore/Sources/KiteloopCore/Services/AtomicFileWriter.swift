import Foundation

/// Durable whole-file replacement for the small JSON files Kiteloop keeps its
/// settings in.
///
/// `Data.write(options: .atomic)` renames a temp file into place, so a reader
/// never observes a half-written file — but it never flushes those bytes. On a
/// power loss or panic the rename can reach disk while the contents are still in
/// the page cache, and the file that survives is zero-length or truncated. The
/// next launch decodes that as "no settings at all" and the first save writes the
/// empty config back over it, so a single unclean shutdown costs the user their
/// knowledge repo path, backend choice and control-server settings.
///
/// Writing the temp file, forcing it to the platter, renaming, and then flushing
/// the directory entry closes the gap: after `write` returns, either the old file
/// or the complete new one is on disk, never a prefix of the new one.
///
/// `append` is the other half, for the JSONL ledgers Kiteloop keeps: not a
/// replacement but an addition to the end of a file, with the one repair that
/// makes an append-only log survive an unclean shutdown — see its own comment.
package enum AtomicFileWriter {

    package enum WriteError: Error {
        /// A POSIX call failed; `errno` is captured at the point of failure
        /// because later cleanup would otherwise clobber it.
        case posix(operation: String, errno: Int32)
    }

    /// Replaces `url` with `data`, creating the containing directory if needed.
    ///
    /// The temp file is created as a sibling so the rename stays within one
    /// volume — `rename(2)` across mount points fails, and a temp directory is a
    /// separate volume often enough to matter.
    ///
    /// `mode` pins the permissions of the file that lands, for a secret that must
    /// never be readable by anyone else even for the instant between the write and
    /// a `chmod`. Left `nil`, the mode of the file being replaced is inherited.
    package static func write(_ data: Data, to url: URL, mode requestedMode: mode_t? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destinationPath = url.path(percentEncoded: false)
        let tempPath = directory
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            .path(percentEncoded: false)

        // Inherit the mode of the file being replaced so an install that
        // tightened permissions by hand keeps them across a save.
        let mode = requestedMode ?? existingMode(ofFileAt: destinationPath) ?? 0o644

        do {
            try writeAndFlush(data, toPath: tempPath, mode: mode)
            guard rename(tempPath, destinationPath) == 0 else {
                throw WriteError.posix(operation: "rename", errno: errno)
            }
        } catch {
            unlink(tempPath)
            throw error
        }

        // The rename is only durable once the directory entry itself is flushed.
        flushDirectory(directory.path(percentEncoded: false))
    }

    // MARK: - Append

    /// Adds `data` to the end of `url`, starting a new line first if the file
    /// doesn't already end in one. Creates the file carrying just `data` when it
    /// isn't there yet — through `write` above, so the containing directory is
    /// made if it is missing and the bytes are on the platter before the name is:
    /// a ledger's very first record is exactly the one an unclean shutdown would
    /// otherwise take, and an append into a directory nobody has created yet used
    /// to throw the record away instead of writing it.
    ///
    /// Every line a JSONL ledger writes is newline-terminated, so the file
    /// normally ends in one — but a kill mid-append leaves a truncated last line
    /// with no terminator, and seeking to end would then write the next record
    /// straight onto it. The two become a single line that decodes as neither, so
    /// the record written *after* the crash is the one that ends up lost: the
    /// truncated half is already accounted for as unreadable, while the record
    /// that follows it simply isn't there.
    ///
    /// This is not an atomic append — a kill can still truncate the line being
    /// written, which is what the ledgers' undecodable-line counts report. What it
    /// guarantees is that the truncation costs only its own line, and that a line
    /// this call has returned from is on the platter rather than in the page cache.
    ///
    /// That last part is why the bytes go through a descriptor rather than a
    /// `FileHandle`: the same `F_FULLFSYNC`-or-`fsync` commit the whole-file path
    /// makes runs before this returns. A run record's closing line is what turns an
    /// open record into an ending, so a panic between the append and an unforced
    /// flush leaves the opening line alone and the next launch reads work that
    /// finished as work the app died under.
    package static func append(_ data: Data, to url: URL) throws {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            try write(data, to: url)
            return
        }
        // O_RDWR rather than O_WRONLY: the last byte has to be read back before
        // anything is written after it, and a write-only descriptor cannot read —
        // the check would answer "already terminated" whatever the file says, and
        // the repair would never happen on the one path that needs it. O_APPEND
        // puts each write at the end of the file as one operation, so nothing has
        // to seek there first.
        let fd = open(path, O_RDWR | O_APPEND)
        guard fd >= 0 else { throw WriteError.posix(operation: "open", errno: errno) }
        defer { close(fd) }

        var info = stat()
        // A size that cannot be read is treated as an empty file, exactly as a
        // seek-to-end that failed used to be: nothing to be wrong about, so
        // nothing is prepended.
        let end = fstat(fd, &info) == 0 ? info.st_size : 0
        if end > 0, !endsInNewline(fd, end: end) {
            try writeAll(Data("\n".utf8), to: fd)
        }
        try writeAll(data, to: fd)
        try commit(fd)
    }

    /// Decodes `url` as one JSON value per line — the read side of `append`,
    /// for the several JSONL ledgers Kiteloop keeps (a retry count, a triage
    /// history, a pass log) that all read this same shape back. A line that
    /// fails to decode is skipped rather than failing the whole read: a
    /// half-written line from a kill mid-append must not cost every earlier
    /// record its count. A missing file reads as empty, the same "nothing
    /// there yet" a fresh ledger starts from.
    ///
    /// The file's bytes are split on the newline byte and each line is decoded
    /// on its own, the way `RunRecordStore.collapse` reads its ledger. Reading
    /// the whole file as one string was all-or-nothing: a kill part-way through
    /// a multi-byte character — the exact truncation `append` is written to
    /// survive — left one line that is not valid UTF-8, the whole-file read
    /// failed, and every record before it was lost too. Skipped lines are not
    /// counted or handed back: these ledgers are read-and-forget, and nothing
    /// rewrites them.
    ///
    /// `split` keeps no empty pieces, so a blank line — what `append`'s repair
    /// leaves when it prepends a newline nobody needed — contributes no entry
    /// and is not an error.
    package static func loadLines<T: Decodable>(from url: URL, as type: T.Type) -> [T] {
        guard let content = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(T.self, from: line)
        }
    }

    /// Whether the file's last byte is a newline.
    ///
    /// `pread` rather than a seek: the descriptor is O_APPEND, so writes land at
    /// the end of the file whatever the offset says, and there is nothing to put
    /// back afterwards.
    ///
    /// A read that fails answers `false`, so the newline goes in: the two mistakes
    /// are not the same size. A newline nobody needed leaves a blank line, which
    /// every loader here drops on the floor — they split on newlines and keep no
    /// empty pieces — while a newline that was needed and not written costs a whole
    /// record.
    private static func endsInNewline(_ fd: Int32, end: off_t) -> Bool {
        var last: UInt8 = 0
        guard pread(fd, &last, 1, end - 1) == 1 else { return false }
        return last == UInt8(ascii: "\n")
    }

    // MARK: - Pieces

    private static func writeAndFlush(_ data: Data, toPath path: String, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw WriteError.posix(operation: "open", errno: errno) }
        defer { close(fd) }

        // open(2) applies the umask to `mode`; the file is ours alone until the
        // rename, so set the mode we actually want explicitly.
        _ = fchmod(fd, mode)

        try writeAll(data, to: fd)
        try commit(fd)
    }

    /// Waits for what has been written through `fd` to reach the platter — the one
    /// step that makes either path durable, so both end here.
    ///
    /// F_FULLFSYNC is the only call on macOS that waits for the drive to commit
    /// rather than just handing the blocks to it. It is unsupported on some
    /// filesystems (network mounts) and on character devices, where fsync is the
    /// best available.
    ///
    /// Internal rather than private so a test can drive the failure: a commit that
    /// is never made and a commit that succeeds leave the same file behind on a
    /// machine that does not lose power, and only the thrown error tells them apart.
    package static func commit(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == -1, fsync(fd) == -1 {
            throw WriteError.posix(operation: "fsync", errno: errno)
        }
    }

    /// `write(2)` may commit fewer bytes than asked for, so loop until the buffer
    /// is drained — a short write here is exactly the truncation this type exists
    /// to prevent.
    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                // Qualified: the type's own `write(_:to:)` would shadow write(2).
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw WriteError.posix(operation: "write", errno: errno)
            }
            if written == 0 { throw WriteError.posix(operation: "write", errno: EIO) }
            offset += written
        }
    }

    /// Best-effort: the bytes are already durable at this point, so a directory
    /// that cannot be flushed only risks losing the *replacement*, which leaves
    /// the previous complete file in place.
    private static func flushDirectory(_ path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
    }

    private static func existingMode(ofFileAt path: String) -> mode_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }
}
