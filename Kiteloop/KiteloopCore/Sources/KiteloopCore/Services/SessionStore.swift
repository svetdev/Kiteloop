import Foundation
import Observation
import os.log

/// What a chat's branch sidecar holds: its branches, the one it is on (`nil`
/// is main) and the main line's messages — enough to rebuild a
/// `ConversationTree`.
package struct ConversationBranchSnapshot: Codable {
    package var branches: [ConversationBranch]
    package var activeBranchID: UUID?
    package var mainMessages: [Message]

    package init(branches: [ConversationBranch], activeBranchID: UUID?, mainMessages: [Message]) {
        self.branches = branches
        self.activeBranchID = activeBranchID
        self.mainMessages = mainMessages
    }
}

@Observable
package final class SessionStore {
    package private(set) var sessions: [String: [ChatSession]] = [:]  // key: agentID
    /// Agent ids whose `index.json` the decoder refused at load, so the next
    /// `save` for one of them moves the file aside instead of writing over it.
    ///
    /// Without this the failure was indistinguishable from an agent that had
    /// never chatted: `loadAll` skipped the directory, nothing was logged, and
    /// the first `createSession` wrote a one-element list over the whole
    /// history. Kept the way `RunRecordStore` keeps `undecodableLines` — the
    /// bytes we could not read are still the human's chat history — and exposed
    /// so a caller, and a test, can see the failure without reading os_log.
    package private(set) var unreadableIndexAgentIDs: Set<String> = []
    private let baseURL: URL
    /// Where the failures go. A parameter only so a test can read what was
    /// reported; nothing in the app passes it.
    private let log: (String) -> Void

    /// `session-store` is the Diagnostics category these lines carry.
    package init(projectDir: URL,
         log: @escaping (String) -> Void = { kiteloopLog($0, category: "session-store", level: .error) }) {
        self.baseURL = projectDir.appending(path: ".kiteloop/sessions")
        self.log = log
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: - Public API

    package func sessions(for agentID: String) -> [ChatSession] {
        sessions[agentID] ?? []
    }

    package func createSession(agentID: String) -> ChatSession {
        let session = ChatSession(agentID: agentID)
        sessions[agentID, default: []].insert(session, at: 0)
        save(agentID: agentID)
        return session
    }

    /// Replaces the stored session and, when its `lastMessageAt` changed, moves
    /// it to where `loadAll`'s newest-first sort would put it — so the list in
    /// memory, and the index on disk, read the way a relaunch would. A change
    /// that leaves the time alone, a rename, leaves the session where it is.
    package func updateSession(_ session: ChatSession) {
        guard var list = sessions[session.agentID],
              let idx = list.firstIndex(where: { $0.id == session.id }) else { return }
        if list[idx].lastMessageAt == session.lastMessageAt {
            list[idx] = session
        } else {
            list.remove(at: idx)
            let target = list.firstIndex { $0.lastMessageAt <= session.lastMessageAt } ?? list.endIndex
            list.insert(session, at: target)
        }
        sessions[session.agentID] = list
        save(agentID: session.agentID)
    }

    package func deleteSession(_ session: ChatSession) {
        sessions[session.agentID]?.removeAll { $0.id == session.id }
        save(agentID: session.agentID)
        let messagesURL = baseURL.appending(path: "\(session.agentID)/\(session.id.uuidString).json")
        try? FileManager.default.removeItem(at: messagesURL)
        try? FileManager.default.removeItem(at: branchesURL(for: session))
    }

    // MARK: - Auto-Title Generation

    package func generateTitle(from messages: [Message]) -> String {
        let userMessages = messages
            .filter { $0.sender == .human }
            .prefix(3)
            .compactMap { msg -> String? in
                if case .text(let t) = msg.content { return t }
                return nil
            }
            // One line: runs of whitespace, newlines included, become one space.
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

        guard let first = userMessages.first(where: { !$0.isEmpty }) else { return "New Chat" }

        if first.count <= 50 { return first }
        return String(first.prefix(47)) + "..."
    }

    // MARK: - Message Persistence (per-session, JSONL)

    package func messagesURL(for session: ChatSession) -> URL {
        let dir = baseURL.appending(path: session.agentID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(session.id.uuidString).json")
    }

    package func loadMessages(for session: ChatSession, limit: Int = 500) -> [Message] {
        loadMessageTail(for: session, limit: limit).messages
    }

    /// The newest `limit` messages, and how many leading records the limit
    /// left out — JSONL lines, or elements of a legacy array. A caller that
    /// saves what it loaded passes `leftOut` to ``writeMessages(_:to:keepingLeading:)``
    /// so the save does not drop them.
    package func loadMessageTail(for session: ChatSession, limit: Int) -> (messages: [Message], leftOut: Int) {
        let url = messagesURL(for: session)
        // Decoded lossily: one byte that is not UTF-8 becomes U+FFFD in the
        // message that held it, rather than emptying the whole history — which
        // the next save would then write over the file.
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let content = String(decoding: data, as: UTF8.self)
        guard !content.isEmpty else { return ([], 0) }
        // JSONL: first char is '{'; legacy JSON array: first char is '['
        if content.first == "[" {
            guard let decoded = try? JSONDecoder().decode([Message].self, from: data) else { return ([], 0) }
            return (Array(decoded.suffix(limit)), max(0, decoded.count - limit))
        }
        return loadMessagesFromJSONL(content: content, limit: limit)
    }

    package func loadAllMessages(for session: ChatSession) -> [Message] {
        loadMessages(for: session, limit: .max)
    }

    private func loadMessagesFromJSONL(content: String, limit: Int) -> (messages: [Message], leftOut: Int) {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(limit)
        let decoder = JSONDecoder()
        let messages: [Message] = tail.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Message.self, from: data)
        }
        return (messages, lines.count - tail.count)
    }

    /// Writes `messages` as JSONL over the file at `url`, behind the first
    /// `leftOut` records already there — the ones a limited load never put in
    /// memory. JSONL records are re-emitted byte for byte; a legacy JSON array
    /// is converted, its head messages re-encoded. Without them a save after
    /// loading a 500-message tail would truncate the history to that tail.
    ///
    /// Static, and taking the URL, so a detached task can run it off the main
    /// actor without holding the store.
    package static func writeMessages(_ messages: [Message], to url: URL, keepingLeading leftOut: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = leftOut > 0 ? leadingRecords(at: url, count: leftOut) : Data()
        let encoder = JSONEncoder()
        for message in messages {
            guard let lineData = try? encoder.encode(message) else { continue }
            lines.append(lineData)
            lines.append(Data("\n".utf8))
        }
        try lines.write(to: url, options: .atomic)
    }

    /// The first `count` records of the messages file at `url`, as JSONL.
    private static func leadingRecords(at url: URL, count: Int) -> Data {
        guard let data = try? Data(contentsOf: url), let first = data.first else { return Data() }
        if first == UInt8(ascii: "[") {
            guard let decoded = try? JSONDecoder().decode([Message].self, from: data) else { return Data() }
            let encoder = JSONEncoder()
            return decoded.prefix(count).reduce(into: Data()) { out, message in
                guard let lineData = try? encoder.encode(message) else { return }
                out.append(lineData)
                out.append(Data("\n".utf8))
            }
        }
        let newline = UInt8(ascii: "\n")
        return data.split(separator: newline, omittingEmptySubsequences: true)
            .prefix(count)
            .reduce(into: Data()) { out, line in
                out.append(line)
                out.append(newline)
            }
    }

    // MARK: - Branch Persistence (per-session sidecar)

    /// Beside the transcript: the same agent directory and session uuid, with
    /// a suffix of its own.
    package func branchesURL(for session: ChatSession) -> URL {
        baseURL.appending(path: "\(session.agentID)/\(session.id.uuidString).branches.json")
    }

    /// Writes the chat's branches beside its transcript. A snapshot with no
    /// branches removes the sidecar instead — a chat with nothing to restore
    /// leaves nothing behind.
    package func saveBranches(_ snapshot: ConversationBranchSnapshot, for session: ChatSession) throws {
        let url = branchesURL(for: session)
        guard !snapshot.branches.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFileWriter.write(try JSONEncoder().encode(snapshot), to: url)
    }

    /// The chat's saved branches, or `nil` when it never saved any. A file the
    /// decoder refuses is reported and left exactly as it is: it may be the
    /// only copy of those branches.
    package func loadBranches(for session: ChatSession) -> ConversationBranchSnapshot? {
        let url = branchesURL(for: session)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(ConversationBranchSnapshot.self, from: data)
        } catch {
            log("""
                \(session.agentID): \(url.path(percentEncoded: false)) could not be decoded \
                (\(String(describing: error))), so that chat's branches are not restored. \
                The file is kept.
                """)
            return nil
        }
    }

    // MARK: - Private

    /// Reads every agent's index, once, at init.
    ///
    /// An index the decoder refuses is remembered rather than skipped — see
    /// ``unreadableIndexAgentIDs`` — and reported here, so the failure is stated
    /// once per load naming the agent and the file rather than once per session
    /// nobody can see any more. An agent directory with no `index.json` is the
    /// ordinary state of an agent that has never chatted and stays silent; a
    /// file that cannot be *read* at all — a permission tightened, a directory
    /// in its place — is a different failure and is left as it was, since
    /// nothing here could tell what a move would be rescuing.
    private func loadAll() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: nil
        ) else { return }

        var didPrune = false
        for dir in contents where dir.hasDirectoryPath {
            let agentID = dir.lastPathComponent
            let indexURL = dir.appending(path: "index.json")
            guard let data = try? Data(contentsOf: indexURL) else { continue }
            guard var list = try? JSONDecoder().decode([ChatSession].self, from: data) else {
                unreadableIndexAgentIDs.insert(agentID)
                log("""
                    \(agentID): \(indexURL.path(percentEncoded: false)) could not be decoded, \
                    so that agent's chat history is not loaded. The file is kept — the next save \
                    for this agent moves it aside to \(Self.unreadableSuffix) rather than \
                    writing over it.
                    """)
                continue
            }
            list.sort { $0.lastMessageAt > $1.lastMessageAt }
            let empties = list.dropFirst().filter(Self.isPrunable)
            if !empties.isEmpty {
                let emptyIDs = Set(empties.map(\.id))
                list.removeAll { emptyIDs.contains($0.id) }
                for s in empties {
                    [dir.appending(path: "\(s.id.uuidString).json"), branchesURL(for: s)]
                        .forEach { try? FileManager.default.removeItem(at: $0) }
                }
                didPrune = true
            }
            sessions[agentID] = list
        }

        if didPrune {
            for agentID in sessions.keys { save(agentID: agentID) }
        }
    }

    /// A session the load drops when it is not the newest: no messages, and
    /// no unsent draft — a draft of only whitespace counts as none, as it
    /// does for the sidebar's "Draft:" subtitle.
    private static func isPrunable(_ session: ChatSession) -> Bool {
        session.messageCount == 0
            && (session.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(agentID: String) {
        let dir = baseURL.appending(path: agentID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = dir.appending(path: "index.json")
        // An index the decoder refused is somebody's chat history, and this
        // write is the one step that cannot be undone — so it goes aside first,
        // and the write is abandoned if it could not, the same choice
        // `TokenStore` makes for a file it cannot read. Moving it here rather
        // than at load keeps a launch that only *read* the sessions from
        // scattering salvage files.
        if unreadableIndexAgentIDs.contains(agentID) {
            guard moveAsideUnreadableIndex(at: indexURL, agentID: agentID) else { return }
            unreadableIndexAgentIDs.remove(agentID)
        }
        // No list in memory means a delete of a session this store never held:
        // there is nothing to record, and encoding the `nil` would only put a
        // `null` where an index belongs.
        guard let list = sessions[agentID], let data = try? JSONEncoder().encode(list) else { return }
        // Durably, rather than the plain write this used to be. That one
        // truncated the index in place, so a read racing it saw a prefix, and it
        // never flushed — an unclean shutdown could leave a zero-length or
        // truncated file behind, which `loadAll` then refuses, costing the agent
        // every chat it had. And a write that fails outright is said out loud:
        // dropping it left the sessions on screen while nothing on disk had
        // changed, which is indistinguishable from a save that worked until the
        // next launch.
        do {
            try AtomicFileWriter.write(data, to: indexURL)
        } catch {
            log("""
                \(agentID): \(indexURL.path(percentEncoded: false)) could not be written \
                (\(String(describing: error))) — the sessions listed in the app are not saved. \
                The index already on disk is untouched.
                """)
        }
    }

    /// What an index the decoder refused is renamed to, beside itself.
    private static let unreadableSuffix = "index.json.unreadable"

    /// Renames the unreadable index to an `index.json.unreadable` sibling and
    /// answers whether it worked. A caller that gets `false` must not write.
    private func moveAsideUnreadableIndex(at indexURL: URL, agentID: String) -> Bool {
        let destination = Self.unusedSibling(of: indexURL, named: Self.unreadableSuffix)
        do {
            try FileManager.default.moveItem(at: indexURL, to: destination)
        } catch {
            log("""
                \(agentID): \(indexURL.path(percentEncoded: false)) could not be moved aside to \
                \(destination.lastPathComponent) (\(error.localizedDescription)) — leaving it in \
                place rather than overwriting it, so this save is skipped.
                """)
            return false
        }
        log("""
            \(agentID): moved the unreadable index aside to \
            \(destination.path(percentEncoded: false)); the sessions it held are still \
            recoverable from that file.
            """)
        return true
    }

    /// The first of `name`, `name-2`, `name-3`… that nothing occupies.
    ///
    /// `moveItem` refuses to replace an existing file, so without this a second
    /// unreadable index for the same agent would leave the move failing and its
    /// save skipped forever.
    private static func unusedSibling(of url: URL, named name: String) -> URL {
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appending(path: name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(name)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
