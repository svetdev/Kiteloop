import Foundation

/// Namespace for the coordinator's filing-related value types. The
/// recommend-and-parse path this once carried a whitelist of actions for was
/// retired along with the per-project run supervisor; `FiledItemDraft` outlived
/// it because `BacklogTemplate` files new work through it directly.
package enum CoordinatorAction {
    /// A backlog item drafted in the shape the Definition-of-Ready judges: a
    /// line's worth of fields (id, title, epic, size, verify) plus the groomed
    /// body that becomes `backlog/<id>.md`.
    ///
    /// Everything but the id and title is optional because an under-specified
    /// draft is not an error — it fails `DefinitionOfReady` and is filed as
    /// `draft` for a human, which is the point of the gate.
    package struct FiledItemDraft: Equatable, Sendable {
        package var id: String
        package var title: String
        package var epic: String = ""
        package var size: ItemSize?
        package var verify: String?
        package var what: String = ""
        package var how: String = ""
        package var validation: [String] = []
        package var outOfScope: [String] = []
        /// The `## Premise` bullets, when the draft states any — see
        /// `BacklogItemDetail.premise`. Written after `## What`, and only when
        /// non-empty: an item with no premise has no empty heading to carry.
        package var premise: [String] = []

        /// The drafted backlog line, for judging and for writing.
        package func item(status: BacklogItemStatus) -> BacklogItem {
            BacklogItem(id: Self.oneLine(id), title: Self.oneLine(title),
                        verify: verify.map(Self.oneLine), status: status, type: .local, size: size)
        }

        /// The drafted detail, as `DefinitionOfReady` will read it back off disk.
        package var detail: BacklogItemDetail {
            BacklogItemDetail(
                id: Self.oneLine(id), title: Self.oneLine(title), status: nil,
                epic: epic.isEmpty ? nil : Self.oneLine(epic), priority: nil,
                size: size?.rawValue, owner: nil, jira: nil, repo: nil,
                verifyCommands: verify.map { [.init(name: "verify", cmd: Self.oneLine($0), expect: nil)] } ?? [],
                why: nil,
                acceptanceCriteria: validation.map(Self.oneLine).filter { !$0.isEmpty },
                outOfScope: outOfScope.map(Self.oneLine).filter { !$0.isEmpty },
                context: nil, notes: nil,
                what: what.isEmpty ? nil : what, approach: how.isEmpty ? nil : how,
                premise: premise.map(Self.oneLine).filter { !$0.isEmpty }
            )
        }

        /// `backlog/<id>.md`, in the layout `BacklogViewModel.createDetail`
        /// scaffolds and `BacklogParser.parseDetail` reads.
        package var detailMarkdown: String {
            var out = "---\nid: \(Self.oneLine(id))\ntitle: \(Self.oneLine(title))\n"
            if !epic.isEmpty { out += "epic: \(Self.oneLine(epic))\n" }
            if let size { out += "size: \(size.rawValue)\n" }
            if let verify, !Self.oneLine(verify).isEmpty {
                out += "verify:\n  - name: verify\n    cmd: "
                    + BacklogParser.doubleQuotedScalarLiteral(Self.oneLine(verify)) + "\n"
            }
            out += "---\n\n## What\n\n\(what)\n\n"
            let premiseLines = premise.map(Self.oneLine).filter { !$0.isEmpty }
            if !premiseLines.isEmpty {
                out += "## Premise\n\n" + premiseLines.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            out += "## How\n\n\(how)\n\n## Validation\n\n"
            out += validation.map(Self.oneLine).filter { !$0.isEmpty }
                .map { "- [ ] \($0)" }.joined(separator: "\n")
            out += "\n\n## Out of Scope\n\n"
            out += outOfScope.map(Self.oneLine).filter { !$0.isEmpty }
                .map { "- \($0)" }.joined(separator: "\n")
            return out + "\n"
        }

        /// Frontmatter and item lines are line-oriented; a stray newline in a
        /// model-authored field would silently split the file into nonsense.
        package static func oneLine(_ text: String) -> String {
            text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        /// `ready` only if the draft would clear the same gate that picks items
        /// up; otherwise `draft`. A half-groomed item in `ready` costs a whole
        /// run before failing on its own vagueness — in `draft` it costs a glance.
        package static func filingStatus(for draft: Self, verifyDefault: String? = nil) -> BacklogItemStatus {
            filingVerdict(for: draft, verifyDefault: verifyDefault).isReady ? .ready : .draft
        }

        /// *Why* it would file as `draft` — one phrase per unmet clause, empty
        /// when it would file as `ready`. What a reviewer needs in order to judge
        /// a proposal without opening the item and re-deriving the gate.
        package static func filingNotes(for draft: Self, verifyDefault: String? = nil) -> [String] {
            let verdict = filingVerdict(for: draft, verifyDefault: verifyDefault)
            return verdict.isReady ? [] : ["self-check failed: \(verdict.summary)"]
        }

        /// `verifyDefault` is applied because the written line inherits it, so
        /// judging without it would predict a verdict the pickup gate won't reach.
        private static func filingVerdict(for draft: Self,
                                          verifyDefault: String?) -> DefinitionOfReady.Verdict {
            var item = draft.item(status: .draft)
            if (item.verify ?? "").isEmpty { item.verify = verifyDefault }
            return DefinitionOfReady.evaluate(item: item, detail: draft.detail)
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, title: String, epic: String = "", size: ItemSize? = nil, verify: String? = nil, what: String = "", how: String = "", validation: [String] = [], outOfScope: [String] = [], premise: [String] = []) {
            self.id = id
            self.title = title
            self.epic = epic
            self.size = size
            self.verify = verify
            self.what = what
            self.how = how
            self.validation = validation
            self.outOfScope = outOfScope
            self.premise = premise
        }
    }
}

/// Pure bound checks for filing new work, unit-testable without a live app.
package enum CoordinatorBounds {
    /// Filing new work is bounded by three things, all checkable without the
    /// app: the id has to be a usable file name (it becomes `backlog/<id>.md`),
    /// it has to be *new* — filing may never reach an item that exists — and
    /// the draft has to say what it is. Returns the rejection, or nil to allow.
    package static func filedItemRejection(draft: CoordinatorAction.FiledItemDraft,
                                   existingIDs: Set<String>) -> String? {
        let id = CoordinatorAction.FiledItemDraft.oneLine(draft.id)
        guard !id.isEmpty else { return "filed item has no id" }
        guard id.unicodeScalars.allSatisfy(safeIDScalars.contains),
              !id.hasPrefix("."), !id.contains("..") else {
            return "id \"\(id)\" isn't a safe backlog/<id>.md file name"
        }
        guard !existingIDs.contains(id) else {
            return "\(id) already exists — fileItem files new work only; use regroom"
        }
        guard !CoordinatorAction.FiledItemDraft.oneLine(draft.title).isEmpty else {
            return "filed item \(id) has no title"
        }
        return nil
    }

    private static let safeIDScalars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
}
