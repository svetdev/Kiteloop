import Foundation
import KiteloopCore
import os.log

private let aiEditorLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog-ai")

/// A single proposed change to a project's backlog, decoded from the model's
/// JSON response. Kept deliberately small and explicit so the preview UI can
/// describe exactly what will happen before anything is written.
enum BacklogEditOp {
    case addEpic(name: String, description: String?)
    /// Everything after `title` is for a caller that already knows the line it
    /// wants — the coordinator's `fileItem`, which picks its own id and grooms
    /// the size, verify and stage. Left nil (the natural-language path) the op
    /// behaves exactly as before: generated id, inherited verify, no size, the
    /// project's new-item stage.
    case addItem(epic: String, title: String, id: String? = nil, verify: String? = nil,
                 size: ItemSize? = nil, status: BacklogItemStatus? = nil)
    /// A whole groomed item — line, `backlog/<id>.md` and its `needs:` edges —
    /// filed in one op. `addItem` writes the empty line a human then grooms; this
    /// carries a draft that is already written and already gated, which is what a
    /// `BacklogTemplate` stamp and the coordinator's refill loop both arrive with.
    case stampItem(epic: String, draft: QueueRefill.Draft,
                   status: BacklogItemStatus, notes: [String])
    case updateItem(id: String, title: String)
    case setStatus(id: String, status: BacklogItemStatus)
    case moveItem(id: String, toEpic: String)
    /// Reorder without changing anything else: in front of `before`, or to the
    /// top of its epic when `before` is nil. Position is the queue's priority.
    case moveItemBefore(id: String, before: String?)
    case removeItem(id: String)
    case removeEpic(name: String)

    /// Human-readable one-liner shown in the confirmation list.
    var summary: String {
        switch self {
        case .addEpic(let name, _): "Add epic “\(name)”"
        case .addItem(let epic, let title, _, _, _, _): "Add item “\(title)” to “\(epic)”"
        case .stampItem(let epic, let draft, let status, _):
            "File \(draft.id) “\(draft.title)” into “\(epic)” as \(status.displayName)"
        case .updateItem(let id, let title): "Rename \(id) → “\(title)”"
        case .setStatus(let id, let status): "Set \(id) to \(status.displayName)"
        case .moveItem(let id, let toEpic): "Move \(id) to “\(toEpic)”"
        case .moveItemBefore(let id, let before):
            before.map { "Move \(id) in front of \($0)" } ?? "Move \(id) to the top of its epic"
        case .removeItem(let id): "Remove item \(id)"
        case .removeEpic(let name): "Remove epic “\(name)”"
        }
    }

    /// Destructive ops get a warning affordance in the preview.
    var isDestructive: Bool {
        switch self {
        case .removeItem, .removeEpic: true
        default: false
        }
    }

    /// Ops that only add to the backlog — the preview gives them the plus icon,
    /// so a rename, move or status change doesn't read as new work.
    var isAddition: Bool {
        switch self {
        case .addEpic, .addItem, .stampItem: true
        default: false
        }
    }

    /// The line the preview shows, read against the backlog as it stands: an
    /// epic removal says how many items go with it, and an op on one existing
    /// item names its title beside the id. Anything `file` doesn't hold keeps
    /// the plain `summary` — apply refuses that op and says so.
    func previewLine(in file: BacklogFile?) -> String {
        if case .removeEpic(let name) = self,
           let count = file?.sections.first(where: { $0.name == name })?.items.count, count > 0 {
            return "\(summary) and its \(count) \(count == 1 ? "item" : "items")"
        }
        guard let id = existingItemID,
              let title = file?.sections.lazy.flatMap(\.items).first(where: { $0.id == id })?.title,
              let range = summary.range(of: id) else { return summary }
        return summary.replacingCharacters(in: range, with: "\(id) “\(title)”")
    }

    /// The id of the existing item this op addresses, if it addresses one.
    private var existingItemID: String? {
        switch self {
        case .updateItem(let id, _), .setStatus(let id, _), .moveItem(let id, _),
             .moveItemBefore(let id, _), .removeItem(let id): id
        default: nil
        }
    }
}

/// Turns a natural-language request plus the current backlog into a reviewed set
/// of `BacklogEditOp`s, then applies them through `BacklogViewModel`.
///
/// The model call is a short, headless one-shot through the app's existing
/// `AgentRuntime` (Claude Code CLI) in the project directory — no persistent
/// agent, no chat session. The model is asked for JSON only; nothing is written
/// until the user approves the previewed ops.
@Observable
@MainActor
final class BacklogAIEditor {
    enum Phase {
        case idle
        case thinking
        /// The ops that will be applied, plus one phrase per op the mapper could
        /// not read. The unreadable ones travel with the preview so the list the
        /// operator approves is visibly the whole proposal, not the part of it
        /// that happened to decode.
        case review([BacklogEditOp], unreadable: [String])
        case error(String)
    }

    private(set) var phase: Phase = .idle

    private let runtimeFactory: () -> any AgentRuntime
    private let globalConfigStore: GlobalConfigStore

    init(runtimeFactory: @escaping () -> any AgentRuntime, globalConfigStore: GlobalConfigStore) {
        self.runtimeFactory = runtimeFactory
        self.globalConfigStore = globalConfigStore
    }

    /// The request `submit` started, kept so Stop can end it.
    private var proposalTask: Task<Void, Never>?

    func reset() { phase = .idle }

    /// Starts a proposal the editor owns, so `cancel()` can stop it. Returned
    /// for a caller that has to wait it out.
    @discardableResult
    func submit(instruction: String, backlog: BacklogFile, projectPath: String) -> Task<Void, Never> {
        proposalTask?.cancel()
        let task = Task { await propose(instruction: instruction, backlog: backlog, projectPath: projectPath) }
        proposalTask = task
        return task
    }

    /// Stop: the pending request is cancelled — which stops its one-shot
    /// session — and the bar goes back to idle. A reply that lands afterwards
    /// is dropped rather than shown.
    func cancel() {
        proposalTask?.cancel()
        proposalTask = nil
        phase = .idle
    }

    var isBusy: Bool {
        if case .thinking = phase { return true }
        return false
    }

    // MARK: - Propose

    func propose(instruction: String, backlog: BacklogFile, projectPath: String) async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Task.isCancelled else { return }
        phase = .thinking

        let prompt = Self.buildPrompt(instruction: trimmed, backlog: backlog)
        let next: Phase
        do {
            let response = try await runOneShot(prompt: prompt, cwd: URL(fileURLWithPath: projectPath))
            let proposal = try Self.decodeOps(from: response)
            if !proposal.unreadable.isEmpty {
                aiEditorLog.error("Backlog AI edit: \(proposal.unreadable.count) op(s) couldn't be read — \(proposal.unreadable.joined(separator: " "))")
            }
            if proposal.ops.isEmpty {
                // A reply whose ops all failed to map is not a reply proposing
                // nothing: telling the two apart is the difference between
                // fixing the reply and re-prompting a model that answered.
                if proposal.unreadable.isEmpty {
                    next = .error("The assistant didn't propose any changes.")
                } else {
                    throw EditorError.allOpsUnreadable(proposal.unreadable)
                }
            } else {
                next = .review(proposal.ops, unreadable: proposal.unreadable)
            }
        } catch {
            aiEditorLog.error("Backlog AI edit failed: \(error.localizedDescription)")
            next = .error(error.localizedDescription)
        }
        // Stopped while it thought: the bar is already idle, and whatever the
        // runner unwound with is not a reply to show.
        guard !Task.isCancelled else { return }
        phase = next
    }

    // MARK: - Apply

    /// Applies the previewed ops to the backlog. A single load of `backlogFile`
    /// per op keeps ids consistent; each VM call persists via write-back.
    ///
    /// An op that did not land leaves the bar on an error naming it, rather than
    /// closing the preview as if the whole proposal had been written.
    func apply(_ ops: [BacklogEditOp], to viewModel: BacklogViewModel) {
        let failures = Self.apply(ops, to: viewModel)
        guard !failures.isEmpty else {
            phase = .idle
            return
        }
        let head = failures.count == 1
            ? "1 of \(ops.count) changes didn't land: "
            : "\(failures.count) of \(ops.count) changes didn't land: "
        phase = .error(head + failures.joined(separator: "; "))
    }

    /// The write itself, without the preview state — so a non-UI caller (the
    /// coordinator filing an item) lands identical bytes through identical
    /// code rather than a second writer that drifts from this one.
    ///
    /// Returns one phrase per op that did not land: a refused add or stamp, an
    /// epic name already taken, or an id or epic the backlog doesn't hold. The
    /// other ops still apply, and a caller reporting what it filed has to be
    /// able to tell a skipped op from a success.
    @discardableResult
    static func apply(_ ops: [BacklogEditOp], to viewModel: BacklogViewModel) -> [String] {
        ops.compactMap { applyOne($0, to: viewModel) }
    }

    /// One op, or the phrase saying why it did not land.
    private static func applyOne(_ op: BacklogEditOp, to viewModel: BacklogViewModel) -> String? {
        switch op {
        case .addEpic(let name, let description):
            return addEpic(name: name, description: description, to: viewModel)
        case .addItem(let epic, let title, let explicitID, let verify, let size, let status):
            // Asked of the file rather than counted off it, and asked again
            // per op: each add has already written back by the time the next
            // one generates, so an id generated here is one nothing holds.
            let id: String
            if let explicitID, !explicitID.isEmpty {
                id = explicitID
            } else {
                id = viewModel.nextGeneratedItemID()
            }
            let added = viewModel.addItem(sectionName: epic, id: id, title: title,
                                          verify: verify, size: size, status: status)
            // An explicit id the model handed us can be one the backlog
            // already holds. Refused rather than shadowing the first, and
            // said — a caller reporting what it filed cannot tell otherwise.
            return added.refusalReason.map { "couldn't add \(id) — \($0)" }
        case .stampItem(let epic, let draft, let status, let notes):
            let filed = viewModel.fileGroomedItem(
                sectionName: epic, id: draft.id, title: draft.title,
                size: ItemSize(rawValue: draft.size.uppercased()),
                verify: draft.verify, status: status, needs: draft.needs,
                detailMarkdown: draft.detailMarkdown(notes: notes))
            // The reason, not just the fact: whoever reads this phrase has
            // to know whether the id was taken — the item exists already —
            // or the detail file wouldn't write, which is a different
            // problem with a different fix.
            return filed.refusalReason.map { "couldn't file \(draft.id) — \($0)" }
        case .removeEpic(let name):
            guard viewModel.backlogFile?.sections.contains(where: { $0.name == name }) == true else {
                return "couldn't remove epic “\(name)” — no epic has that name"
            }
            viewModel.deleteEpic(name: name)
            return nil
        default:
            return applyItemEdit(op, to: viewModel)
        }
    }

    /// An epic is added, and described, only when its name is free: described
    /// regardless, a taken name would have its existing description overwritten.
    private static func addEpic(name: String, description: String?,
                                to viewModel: BacklogViewModel) -> String? {
        let outcome = viewModel.addEpic(name: name)
        guard outcome == .applied else {
            let reason = outcome == .nameTaken ? "an epic already has that name" : "the backlog refused it"
            return "couldn't add epic “\(name)” — \(reason)"
        }
        if let description, !description.isEmpty,
           viewModel.updateEpicDescription(name: name, text: description) != .applied {
            return "couldn't describe epic “\(name)” — a line of the description would be read as a heading, an item or frontmatter"
        }
        return nil
    }

    /// The ops addressed to an existing item. The view model's mutators return
    /// quietly on an id nothing holds, so the id is checked here first.
    private static func applyItemEdit(_ op: BacklogEditOp, to viewModel: BacklogViewModel) -> String? {
        switch op {
        case .updateItem(let id, let title):
            return withItem(id, verb: "rename", in: viewModel) {
                viewModel.updateItem(itemID: id, title: title, verify: nil)
            }
        case .setStatus(let id, let status):
            return withItem(id, verb: "set the status of", in: viewModel) {
                if status == .done {
                    viewModel.approve(itemID: id)
                } else {
                    viewModel.updateItemStatus(itemID: id, newStatus: status)
                }
            }
        case .moveItem(let id, let toEpic):
            return withItem(id, verb: "move", in: viewModel) {
                viewModel.moveItem(itemID: id, toEpic: toEpic)
            }
        case .moveItemBefore(let id, let before):
            return withItem(id, verb: "move", in: viewModel) {
                viewModel.moveItem(itemID: id, before: before)
            }
        case .removeItem(let id):
            return withItem(id, verb: "remove", in: viewModel) {
                viewModel.removeItem(itemID: id)
            }
        default:
            return nil
        }
    }

    private static func withItem(_ id: String, verb: String, in viewModel: BacklogViewModel,
                                 _ edit: () -> Void) -> String? {
        guard viewModel.item(withID: id) != nil else {
            return "couldn't \(verb) \(id) — no item has that id"
        }
        edit()
        return nil
    }

    // MARK: - Runtime one-shot

    private func runOneShot(prompt: String, cwd: URL) async throws -> String {
        try await HeadlessAgentRunner.run(
            prompt: prompt,
            cwd: cwd,
            systemPrompt: "You edit software project backlogs. Respond with JSON only — no prose, no code fences.",
            agentName: "Backlog Planner",
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore
        )
    }

    /// The same runtime and config, for a caller that keeps its own preview
    /// state rather than this editor's `phase` — the groomer, whose proposal
    /// lives on the item's own page. One path to the subprocess for every
    /// one-shot backlog pass, rather than a second that could drift from it.
    func runOneShot(prompt: String, cwd: URL, systemPrompt: String, agentName: String,
                    access: RepoRead.Grant? = nil) async throws -> String {
        try await HeadlessAgentRunner.run(
            prompt: prompt, cwd: cwd, systemPrompt: systemPrompt, agentName: agentName,
            access: access, runtimeFactory: runtimeFactory, globalConfigStore: globalConfigStore
        )
    }

    // MARK: - Prompt + decoding

    static func buildPrompt(instruction: String, backlog: BacklogFile) -> String {
        let current = BacklogSerializer.serialize(backlog)
        return """
        You are editing the backlog for project "\(backlog.project)".

        Current backlog (Markdown; "## Epic: X" headings are epics, "- [ ] id | title | status" lines are items):

        \(current)

        The user's request:
        \(instruction)

        Return ONLY a JSON array of edit operations that fulfill the request. No
        prose, no markdown, no code fences. Each element is an object with an "op"
        field and the fields for that op:

        - {"op":"addEpic","name":"Epic name","description":"optional text"}
        - {"op":"addItem","epic":"Epic name","title":"Item title"}
        - {"op":"updateItem","id":"item-id","title":"New title"}
        - {"op":"setStatus","id":"item-id","status":"draft|ready|active|in-review|awaiting-approval|blocked|done"}
        - {"op":"moveItem","id":"item-id","toEpic":"Epic name"}
        - {"op":"moveItemBefore","id":"item-id","before":"other-item-id"}  (omit "before" for top of its epic; position is the queue's priority)
        - {"op":"removeItem","id":"item-id"}
        - {"op":"removeEpic","name":"Epic name"}

        Use existing epic names and item ids exactly as they appear above. If the
        request needs no changes, return [].
        """
    }

    private struct RawOp: Decodable {
        let op: String
        let epic: String?
        let name: String?
        let description: String?
        let title: String?
        let id: String?
        let status: String?
        let toEpic: String?
        let before: String?
    }

    /// One element of the reply's array, decoded on its own so a neighbour can't
    /// take it down with it.
    ///
    /// `[RawOp]` decodes as a unit: one element with no `op`, or with a field of
    /// the wrong JSON type, throws and the whole proposal is lost before the
    /// per-op phrases below ever run. Here the element's own decoding failure is
    /// caught and turned into the same kind of phrase a mapping failure gets, so
    /// a malformed change costs that change and nothing else.
    private struct LenientOp: Decodable {
        let raw: RawOp?
        /// Why the element couldn't be read; nil when `raw` is non-nil.
        let reason: String?

        /// Enough of the element to name the op in the phrase — read separately,
        /// because the failure that brought us here left no `RawOp` to ask.
        private enum OpNameKey: String, CodingKey { case op }

        init(from decoder: Decoder) throws {
            do {
                raw = try RawOp(from: decoder)
                reason = nil
            } catch let error as DecodingError {
                let named = try? decoder.container(keyedBy: OpNameKey.self)
                    .decodeIfPresent(String.self, forKey: .op)
                raw = nil
                reason = BacklogAIEditor.undecodable(error, op: named)
            }
        }
    }

    /// The phrase for an element the JSON decoder refused — the same shape
    /// `missing(_:_:)` writes, so the preview's list reads as one list whether a
    /// change failed to decode or failed to map.
    /// `nonisolated`, like `fieldName` and `knownOps` below it: `Decodable`'s
    /// `init(from:)` is not an actor-isolated context, and this class is.
    private nonisolated static func undecodable(_ error: DecodingError, op: String?) -> String {
        let subject = op.map { "`\($0)`" } ?? "this change"
        switch error {
        case .keyNotFound(let key, _):
            // The only required key is `op`, and an element without one can't be
            // told what it meant to be — so it gets the vocabulary, not a nudge
            // about a field it might have wanted.
            guard key.stringValue != "op" else {
                return "this change has no `op` field — expected one of \(knownOps.joined(separator: ", "))."
            }
            return "\(subject) is missing `\(key.stringValue)`."
        case .valueNotFound(_, let context):
            guard let field = fieldName(in: context) else {
                return "\(subject) is empty."
            }
            return "\(subject) has a null `\(field)`."
        case .typeMismatch(let type, let context):
            guard let field = fieldName(in: context) else {
                return "this change isn't a JSON object."
            }
            guard type == String.self else {
                return "\(subject) has a `\(field)` of the wrong type."
            }
            return "\(subject) has a `\(field)` that isn't text."
        default:
            return "\(subject) isn't shaped like an edit operation."
        }
    }

    /// The field the decoder choked on, or nil when the failure is about the
    /// element itself — an array index, not a key, is the decoder saying the
    /// element was never an object.
    private nonisolated static func fieldName(in context: DecodingError.Context) -> String? {
        guard let key = context.codingPath.last, key.intValue == nil else { return nil }
        return key.stringValue
    }

    enum EditorError: LocalizedError {
        case noJSON
        case emptyResponse
        /// Every op in the reply failed to map. Distinct from a literal `[]`,
        /// which is the model saying — legitimately — that nothing needs doing.
        case allOpsUnreadable([String])

        var errorDescription: String? {
            switch self {
            case .noJSON: return "Couldn't find a JSON list of changes in the assistant's reply."
            case .emptyResponse: return "The assistant returned an empty reply."
            case .allOpsUnreadable(let reasons):
                let head = reasons.count == 1
                    ? "The assistant proposed 1 change and it couldn't be read: "
                    : "The assistant proposed \(reasons.count) changes and none of them could be read: "
                return head + reasons.joined(separator: " ")
            }
        }
    }

    /// A decoded reply: the ops that can be applied, plus one phrase per op that
    /// could not be mapped.
    ///
    /// The unreadable ones are carried rather than dropped. A preview silently
    /// shorter than what the model proposed is approved as if it were the whole
    /// proposal, and a reply where every op failed used to read as one proposing
    /// no changes — the opposite of what happened.
    struct Proposal {
        var ops: [BacklogEditOp]
        /// One phrase per undecodable op, naming its position, its `op` and the
        /// field that was missing or unrecognised.
        var unreadable: [String]
    }

    static func decodeOps(from response: String) throws -> Proposal {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EditorError.emptyResponse }
        guard let data = extractJSONArray(text) else { throw EditorError.noJSON }

        // Element-wise: an element the decoder refuses arrives as a nil `raw`
        // with its reason, rather than as a throw that loses its neighbours too.
        let raw = try JSONDecoder().decode([LenientOp].self, from: data)
        var ops: [BacklogEditOp] = []
        var unreadable: [String] = []
        for (index, element) in raw.enumerated() {
            let outcome = element.raw.map(map) ?? .unreadable(element.reason ?? "this change couldn't be read.")
            switch outcome {
            case .op(let op): ops.append(op)
            // Position, because two ops of the same kind in one reply are told
            // apart by nothing else — the reply itself is what has to be fixed.
            case .unreadable(let reason): unreadable.append("Change \(index + 1): \(reason)")
            }
        }
        return Proposal(ops: ops, unreadable: unreadable)
    }

    /// Pulls the first top-level `[ ... ]` out of a reply, tolerating stray prose
    /// or code fences the model may add despite instructions.
    ///
    /// The scan is `StructuredOutputExtractor.balancedSlices`, which walks the
    /// characters tracking depth, `inString` and `escaped` — so a bracket in the
    /// prose around the array, or inside an op's own string value, no longer
    /// widens the slice. It used to run from the first `[` to the last `]`, and
    /// one sentence like *"and I left [WIP] alone"* after the array made the
    /// decode fail and cost the operator the whole proposal.
    ///
    /// Balanced isn't enough on its own — `[WIP]` in the prose is balanced and
    /// isn't JSON — so the first slice that parses as a JSON *array* wins.
    static func extractJSONArray(_ text: String) -> Data? {
        for slice in StructuredOutputExtractor.balancedSlices(in: text, open: "[", close: "]") {
            guard let data = slice.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  parsed is [Any] else { continue }
            return data
        }
        return nil
    }

    /// An op the mapper read, or the phrase saying why it couldn't.
    private enum MappedOp {
        case op(BacklogEditOp)
        case unreadable(String)
    }

    /// The two reorder-shaped ops, out of `map` so the switch stays under the
    /// complexity gate: between epics, and within the order itself.
    private static func mapMove(_ raw: RawOp) -> MappedOp {
        if raw.op == "moveItemBefore" {
            guard let id = raw.id else { return missing("moveItemBefore", ["id": raw.id]) }
            return .op(.moveItemBefore(id: id, before: raw.before))
        }
        let toEpic = raw.toEpic ?? raw.epic
        guard let id = raw.id, let toEpic else {
            return missing("moveItem", ["id": raw.id, "toEpic": toEpic])
        }
        return .op(.moveItem(id: id, toEpic: toEpic))
    }

    private static func map(_ raw: RawOp) -> MappedOp {
        switch raw.op {
        case "addEpic":
            let name = raw.name ?? raw.epic
            guard let name else { return missing("addEpic", ["name": name]) }
            return .op(.addEpic(name: name, description: raw.description))
        case "addItem":
            let epic = raw.epic ?? raw.name
            guard let epic, let title = raw.title else {
                return missing("addItem", ["epic": epic, "title": raw.title])
            }
            return .op(.addItem(epic: epic, title: title))
        case "updateItem":
            guard let id = raw.id, let title = raw.title else {
                return missing("updateItem", ["id": raw.id, "title": raw.title])
            }
            return .op(.updateItem(id: id, title: title))
        case "setStatus":
            guard let id = raw.id, let statusRaw = raw.status else {
                return missing("setStatus", ["id": raw.id, "status": raw.status])
            }
            // A status the app doesn't know is a different failure from one the
            // reply left out, and it takes a different fix — the spelling, not
            // the shape — so it says which value it choked on.
            guard let status = BacklogItemStatus(rawValue: statusRaw) else {
                let known = BacklogItemStatus.allCases.map(\.rawValue).joined(separator: ", ")
                return .unreadable("`setStatus` has an unrecognised `status` “\(statusRaw)” — expected one of \(known).")
            }
            return .op(.setStatus(id: id, status: status))
        case "moveItem", "moveItemBefore":
            return mapMove(raw)
        case "removeItem":
            guard let id = raw.id else { return missing("removeItem", ["id": raw.id]) }
            return .op(.removeItem(id: id))
        case "removeEpic":
            let name = raw.name ?? raw.epic
            guard let name else { return missing("removeEpic", ["name": name]) }
            return .op(.removeEpic(name: name))
        default:
            let known = Self.knownOps.joined(separator: ", ")
            return .unreadable("unrecognised op “\(raw.op)” — expected one of \(known).")
        }
    }

    /// The ops `map` can read, in the order `buildPrompt` lists them.
    nonisolated static let knownOps = [
        "addEpic", "addItem", "updateItem", "setStatus", "moveItem", "moveItemBefore",
        "removeItem", "removeEpic"
    ]

    /// `\`addItem\` is missing \`epic\` and \`title\`.` — every absent field
    /// named, not just the first one the guard tripped over, so a single reading
    /// says what the reply has to add. `fields` is the op's required fields with
    /// the value the reply gave for each; the nil ones are what's missing.
    private static func missing(_ op: String, _ fields: KeyValuePairs<String, String?>) -> MappedOp {
        let absent = fields.filter { $0.value == nil }.map { "`\($0.key)`" }
        return .unreadable("`\(op)` is missing \(list(absent)).")
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "a required field" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
