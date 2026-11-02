import Foundation

package protocol NotificationStoring: Sendable {
    /// Files a notice. One carrying a ``NotificationItem/rollUpKey`` resolves
    /// whatever pending notice already holds that key — it is a newer reading of
    /// the same live state, not a second thing to look at.
    func add(_ item: NotificationItem) async
    func markResolved(id: String) async
    /// Resolves every pending approval notice about `itemID`, recording how the
    /// gate closed. Returns how many it resolved.
    ///
    /// This is what makes an approval row a *view* of the gate rather than a
    /// record that the gate once opened: whoever closed it — a person in the
    /// app, a caller on the control API, the project's own auto-approve — the
    /// row closes with it.
    @discardableResult
    func resolveApprovals(itemID: String, closure: GateClosure) async -> Int
    /// Resolves the pending question notice `agentID` raised, recording how it
    /// closed. Returns how many it resolved.
    ///
    /// The same idea as `resolveApprovals`, for the other gate a person can be
    /// standing at: answering an agent's `ask_human` in the chat closes the
    /// notice that question filed, rather than leaving an actionable row about
    /// work already done. An agent holds at most one `ask_human` at a time, so
    /// the agent is the whole of the match.
    @discardableResult
    func resolveQuestions(agentID: String, closure: GateClosure) async -> Int
    /// The backfill a project runs as it loads: resolves the pending notices
    /// whose state has already passed. Returns how many it resolved.
    ///
    /// Two kinds have passed. An **approval** notice naming an item that is not
    /// in `itemsAtGate` — the gate closed through a surface that never touched
    /// this row, or in a launch that ended before this one. And a **rolled-up**
    /// notice, which reports a run in flight: no run survives a launch, so every
    /// one of them is about a run that has ended.
    ///
    /// An approval notice naming no item is left alone — nothing here can judge
    /// it. So is every other pending row: a question an agent is still blocked
    /// on outlives a launch, and this must not clear it.
    @discardableResult
    func backfillPassedNotices(itemsAtGate: Set<String>) async -> Int
    func dismiss(id: String) async
    /// Dismisses every pending item on one side of the actionable/ambient split
    /// — the bulk clear behind the activity feed's "Clear All".
    func dismissAllPending(actionable: Bool) async
    func pending() async -> [NotificationItem]
    func resolved() async -> [NotificationItem]
    func pendingCount() async -> Int
    /// Pending items a human must act on. This — not `pendingCount` — is what
    /// the toolbar badge counts, so a run producing hundreds of completions
    /// leaves it silent.
    func actionablePendingCount() async -> Int
}

/// Read-merges several stores into one view for the notification list.
/// Mutations are forwarded to every underlying store; item IDs are UUIDs,
/// so a resolve/dismiss only matches in the store that owns the item.
package struct CompositeNotificationStore: NotificationStoring {
    package let stores: [NotificationStoring]

    package func add(_ item: NotificationItem) async {
        await stores.first?.add(item)
    }

    package func markResolved(id: String) async {
        for store in stores { await store.markResolved(id: id) }
    }

    @discardableResult
    package func resolveApprovals(itemID: String, closure: GateClosure) async -> Int {
        var resolved = 0
        for store in stores {
            resolved += await store.resolveApprovals(itemID: itemID, closure: closure)
        }
        return resolved
    }

    @discardableResult
    package func resolveQuestions(agentID: String, closure: GateClosure) async -> Int {
        var resolved = 0
        for store in stores {
            resolved += await store.resolveQuestions(agentID: agentID, closure: closure)
        }
        return resolved
    }

    @discardableResult
    package func backfillPassedNotices(itemsAtGate: Set<String>) async -> Int {
        var resolved = 0
        for store in stores {
            resolved += await store.backfillPassedNotices(itemsAtGate: itemsAtGate)
        }
        return resolved
    }

    package func dismiss(id: String) async {
        for store in stores { await store.dismiss(id: id) }
    }

    package func dismissAllPending(actionable: Bool) async {
        for store in stores { await store.dismissAllPending(actionable: actionable) }
    }

    package func pending() async -> [NotificationItem] {
        var all: [NotificationItem] = []
        for store in stores { all += await store.pending() }
        return all.sorted { $0.timestamp > $1.timestamp }
    }

    package func resolved() async -> [NotificationItem] {
        var all: [NotificationItem] = []
        for store in stores { all += await store.resolved() }
        return all.sorted { $0.timestamp > $1.timestamp }
    }

    package func pendingCount() async -> Int {
        var count = 0
        for store in stores { count += await store.pendingCount() }
        return count
    }

    package func actionablePendingCount() async -> Int {
        var count = 0
        for store in stores { count += await store.actionablePendingCount() }
        return count
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(stores: [NotificationStoring]) {
        self.stores = stores
    }
}

package actor NotificationStore: NotificationStoring {
    private let notificationsURL: URL
    private var items: [NotificationItem] = []
    /// Lines the decoder refused, held verbatim so `rewriteAll()` can put them
    /// back. `persistItem` appends without atomicity, so a kill mid-append leaves
    /// a truncated last line — and that line may be the approval a human still
    /// has to answer. Compaction is what would otherwise erase it, on the first
    /// dismissal after the crash.
    private var undecodableLines: [String] = []
    /// How many lines could not be read at load, exposed so a caller — and a test
    /// — can see it, as `RunRecordStore.undecodableLineCount` is.
    package private(set) var undecodableLineCount = 0
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(notificationsURL: URL) {
        self.notificationsURL = notificationsURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let loaded = Self.loadItems(from: notificationsURL, decoder: decoder)
        self.items = Self.pruned(loaded.items)
        self.undecodableLines = loaded.undecodable
        self.undecodableLineCount = loaded.undecodable.count
    }

    package func add(_ item: NotificationItem) {
        // A notice with a roll-up key is a reading of a live state, so the
        // reading before it is stale the moment this one exists. Resolved rather
        // than deleted: the Resolved section is where somebody goes to find out
        // what happened while they were away, and a run that finished twice is
        // two things that happened.
        if let key = item.rollUpKey {
            resolve(closure: .superseded) { $0.rollUpKey == key }
        }
        items.append(item)
        persistItem(item)
    }

    @discardableResult
    package func resolveApprovals(itemID: String, closure: GateClosure) -> Int {
        resolve(closure: closure) { $0.type == .approval && $0.itemID == itemID }
    }

    @discardableResult
    package func resolveQuestions(agentID: String, closure: GateClosure) -> Int {
        resolve(closure: closure) { $0.type == .question && $0.agentID == agentID }
    }

    @discardableResult
    package func backfillPassedNotices(itemsAtGate: Set<String>) -> Int {
        // An approval notice with no item id names nothing this can check, so it
        // is left for a person — the `== true` is what keeps it out.
        let gone = resolve(closure: .noLongerAtTheGate) { notice in
            notice.type == .approval && notice.itemID.map { !itemsAtGate.contains($0) } == true
        }
        return gone + resolve(closure: .superseded) { $0.rollUpKey != nil }
    }

    /// Resolves every pending notice the predicate picks, stamping `closure`'s
    /// reason on each, and returns how many. One rewrite for the whole batch —
    /// the backfill on load can match thousands of rows.
    @discardableResult
    private func resolve(closure: GateClosure,
                         where matches: (NotificationItem) -> Bool) -> Int {
        let indices = items.indices.filter { items[$0].status == .pending && matches(items[$0]) }
        guard !indices.isEmpty else { return 0 }
        let now = Date()
        for index in indices {
            items[index].status = .resolved
            items[index].resolvedAt = now
            items[index].resolution = closure.reason
        }
        rewriteAll()
        return indices.count
    }

    package func markResolved(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .resolved
        items[index].resolvedAt = Date()
        rewriteAll()
    }

    package func dismiss(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .dismissed
        items[index].resolvedAt = Date()
        rewriteAll()
    }

    package func dismissAllPending(actionable: Bool) {
        let matches = items.indices.filter {
            items[$0].status == .pending && items[$0].isActionable == actionable
        }
        guard !matches.isEmpty else { return }
        let now = Date()
        for index in matches {
            items[index].status = .dismissed
            items[index].resolvedAt = now
        }
        rewriteAll()
    }

    package func pending() -> [NotificationItem] {
        items.filter { $0.status == .pending }.sorted { $0.timestamp > $1.timestamp }
    }

    package func resolved() -> [NotificationItem] {
        items.filter { $0.status == .resolved }.sorted { $0.timestamp > $1.timestamp }
    }

    package func pendingCount() -> Int {
        items.count(where: { $0.status == .pending })
    }

    package func actionablePendingCount() -> Int {
        items.count(where: { $0.status == .pending && $0.isActionable })
    }

    /// Drops resolved/dismissed items a week after they settled. Pending items
    /// are kept regardless of age — they still need a human.
    ///
    /// The week runs from `resolvedAt`, not from `timestamp`: the Resolved
    /// section is where somebody goes to find out what happened while they were
    /// away, and measuring from when a notice *arrived* loses first exactly the
    /// ones that waited longest for an answer — an approval gate that sat open
    /// for eight days and was answered this morning would be gone at the next
    /// launch. Every path out of pending stamps `resolvedAt`; a line written
    /// before that field was recorded has none, and is still judged by its
    /// `timestamp`.
    private static func pruned(_ items: [NotificationItem]) -> [NotificationItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return items.filter { !(($0.resolvedAt ?? $0.timestamp) < cutoff && $0.status != .pending) }
    }

    private func persistItem(_ item: NotificationItem) {
        guard let data = try? encoder.encode(item),
              let line = String(data: data, encoding: .utf8) else { return }
        // Through `AtomicFileWriter.append`, which starts a new line first when the
        // file doesn't end in one. A plain seek-to-end writes this item onto the
        // remnant of one a kill cut short, and the pair decodes as neither — so a
        // pending actionable notification would be lost, and it is the whole
        // mechanism by which a human learns a run is waiting on them.
        try? AtomicFileWriter.append(Data((line + "\n").utf8), to: notificationsURL)
    }

    /// Rewrites the file from `items` — after a resolve, a dismiss or a bulk clear.
    ///
    /// The lines nobody could decode go back at the end, verbatim, the way
    /// `RunRecordStore.rewrite()` puts its own back: a truncated line is still a
    /// notification somebody may owe an answer to, and this rewrite is the only
    /// thing that could delete it.
    ///
    /// Through `AtomicFileWriter` rather than `String.write(atomically:)`, which
    /// renames a temp file into place without ever flushing it — on a panic the
    /// rename can reach disk while the contents are still in the page cache, and
    /// what survives is an empty file where the pending approvals were. A write
    /// that fails outright leaves the previous file alone for the same reason.
    private func rewriteAll() {
        let body = items.compactMap { item -> String? in
            guard let data = try? encoder.encode(item),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            return line + "\n"
        }.joined() + undecodableLines.map { $0 + "\n" }.joined()
        try? AtomicFileWriter.write(Data(body.utf8), to: notificationsURL)
    }

    /// What one line of the log turned out to be.
    private enum DecodedLine {
        case item(NotificationItem)
        /// A line no notice could be made of, as text it can be held as.
        case unreadable(String)
    }

    /// Reads one line's bytes on their own.
    ///
    /// On their own is the point: the file used to be decoded as one string of the
    /// whole thing, so a single truncated multi-byte character — a kill part-way
    /// through appending a title carrying an em dash — made that read fail and the
    /// inbox came up empty, every notice behind the bad byte gone and a pending
    /// approval among them. Worse, `undecodableLines` came back empty too, so the
    /// next `rewriteAll()` wrote out only what this launch had added and deleted
    /// the rest from disk. Bytes that are not valid UTF-8 now join the lines the
    /// JSON decoder refuses, and are held lossily — the bad bytes come back as
    /// replacement characters, which is honest about a line that was never a
    /// notice and is the only way to hold it as the text `rewriteAll()` puts back.
    private static func decodeLine(_ line: Data, using decoder: JSONDecoder) -> DecodedLine {
        guard let text = String(data: line, encoding: .utf8) else {
            return .unreadable(String(decoding: line, as: UTF8.self))
        }
        guard let item = try? decoder.decode(NotificationItem.self, from: line) else {
            return .unreadable(text)
        }
        return .item(item)
    }

    /// Reads the log. A line that doesn't decode costs neither the items around it
    /// nor itself: it is set aside and handed back so `rewriteAll()` can write it
    /// out again.
    ///
    /// Split on the newline byte rather than on a string of the whole file, the
    /// way `RunRecordStore.collapse` does, because a string of the whole file is
    /// all-or-nothing. A file that is simply absent is an empty inbox — a fresh
    /// install has nothing to say.
    private static func loadItems(from url: URL, decoder: JSONDecoder)
        -> (items: [NotificationItem], undecodable: [String]) {
        guard let data = try? Data(contentsOf: url) else { return ([], []) }
        var items: [NotificationItem] = []
        var undecodable: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            switch decodeLine(line, using: decoder) {
            case .item(let item): items.append(item)
            case .unreadable(let text): undecodable.append(text)
            }
        }
        return (items, undecodable)
    }
}
