import Foundation

/// Stages an item moves through. The flow is:
///
///   draft → ready → active → inReview → awaitingApproval → done
///
/// Agents advance active → inReview → awaitingApproval — `inReview` for as long
/// as the reviewer holds the item, and back to `active` when a rejection sends
/// the work round again, in the projects whose flow enables that stage
/// (`BacklogWorkflowConfig.useReviewStage`; with it off a run stays on `active`
/// across both). Only a human moves an item to `done` (when approval is enabled)
/// — an agent passing its own review is not the same as the work being accepted.
/// `blocked` is orthogonal: an item can land there from any stage.
package enum BacklogItemStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case ready
    case active
    case inReview = "in-review"
    case awaitingApproval = "awaiting-approval"
    case blocked
    case done

    package var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .ready: return "Ready"
        case .active: return "Active"
        case .inReview: return "In Review"
        case .awaitingApproval: return "Awaiting Approval"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }

    /// Stages an agent may not move an item into — these are human decisions.
    package var isHumanOnly: Bool {
        self == .done || self == .draft
    }
}

package enum BacklogItemType: String, Codable, Sendable {
    case local
    case jira
}

package enum ItemSize: String, Codable, Sendable, CaseIterable {
    case xs = "XS"
    case s = "S"
    case m = "M"
    case l = "L"
    case xl = "XL"

    package var isTooLargeForAutopilot: Bool { self == .l || self == .xl }
}

/// Which stages a run takes an item through — the standard worker and review,
/// or the QA flow for a UI feature: a specifier writes acceptance scenarios and
/// a QA procedure first, the project's clean and harden commands run after the
/// worker, and a QA agent drives the app and judges its screenshots at the end.
///
/// Written on the line as `flow:qa`; `standard` is the default and never
/// written, so a line without it reads and writes back as it always did.
package enum BacklogFlow: String, Codable, Sendable, CaseIterable {
    case standard
    case qa
}


/// Which half of the queue an item runs in — the ordering axis, kept apart
/// from the epic it belongs to.
///
/// An epic says *where* an item belongs; this says *when* it runs. They used to
/// be the same thing: a project that wanted something run next moved the item
/// into a `Now` epic, and the item lost the only record of which area it was
/// about. With a lane on the line the item stays in its own epic and still runs
/// ahead of everything else.
///
/// `later` is the default and is never written, so a line that carries no lane
/// reads and writes back exactly as it did before lanes existed.
package enum BacklogLane: String, Codable, Sendable, CaseIterable {
    case now
    case later

    /// `items` in the order a run walks them: every `now` item, then every
    /// `later` one, each lane keeping the order it was written in.
    ///
    /// Stable on purpose — within a lane the file still decides, epics top to
    /// bottom and items within them, so adding a lane to one item reorders
    /// nothing else.
    package static func ordered(_ items: [BacklogItem]) -> [BacklogItem] {
        items.filter { $0.lane == .now } + items.filter { $0.lane == .later }
    }
}

package struct BacklogItem: Identifiable, Codable, Sendable, Equatable {
    package var id: String
    package var title: String
    package var verify: String?
    package var status: BacklogItemStatus
    package var type: BacklogItemType
    package var size: ItemSize?
    /// Which half of the queue this item runs in — written on the line as
    /// `lane:now`, and not written at all for `later`.
    ///
    /// **Read**: it is the first key the run order sorts on, ahead of the
    /// document order epics and items are written in, so a `now` item in the
    /// last epic runs before a `later` one in the first. It decides nothing
    /// else — readiness, dependencies and every pickup gate are exactly as they
    /// were, and an item never leaves its epic to change lane.
    package var lane: BacklogLane = .later
    /// Which stages a run takes this item through — written `flow:qa`, and not
    /// at all for `standard`. Decides the run's graph and nothing about order.
    package var flow: BacklogFlow = .standard
    package var queries: Int?
    package var cost: Double?
    package var completedDate: String?
    package var blockedReason: String?
    package var jiraKey: String?
    package var team: String?
    package var detailPath: String?
    /// The item this one was discovered from — a broken-down parent, the failed
    /// item a regroom turned into new work, the merged item an escaped defect
    /// traces back to. Written on the line as `from:<id>`.
    ///
    /// Purely descriptive: it is a record of where the work came from, and never
    /// affects readiness, pickup or the Definition-of-Ready verdict — that is
    /// what separates it from a dependency. A `from:` naming an id no longer in
    /// the file is fine; parents get done and eventually archived.
    package var from: String?
    /// The items this one has to wait for — written on the line as `needs:<id>`,
    /// comma-separated for several.
    ///
    /// The opposite of `from:` in the way that matters: this one is *read*. An
    /// item whose dependency is not `done` is not ready however well groomed, and
    /// an id that names nothing counts as unmet rather than as no dependency at
    /// all — see `DefinitionOfReady.Dependencies`. Ordering used to live in epic
    /// preambles ("run in listed order") that only a human could honour, so an
    /// item promoted ahead of what it builds on reached a worker with nothing to
    /// build against.
    package var needs: [String] = []
    /// The protected paths this item is allowed to change — written on the line
    /// as `touches:<path>`, comma-separated for several.
    ///
    /// Kept on the line, but no run is gated on it: the protected-paths
    /// setting it once exempted an item from is retired.
    ///
    /// Granting it is a grooming decision, made before any work exists. The
    /// Planner may *propose* one, but a draft carrying it is never filed `ready`
    /// (`CoordinatorQueueRefill.gate`), so a human promotes it or nobody does.
    package var touches: [String] = []
    /// Fields on this item's line that the parser could not read as any field it
    /// knows, as written. They are carried so the next write-back puts them back
    /// instead of deleting them — see `BacklogParseIssue`, which reports the same
    /// fields to the user. Re-emitted after the descriptive tokens and before the
    /// stage ones, not in their original position.
    ///
    /// The field-level counterpart of `BacklogSection.unparsedLines`, and carried
    /// for the same reason: the report tells whoever typed the line to fix it, and
    /// the first status flip used to delete the text it was about — including the
    /// tail of a `verify:` truncated by a spaced pipe, which is the case the
    /// report was built for. Preserved, never repaired: nothing here is stitched
    /// back onto the field it fell off.
    package var unrecognisedFields: [String] = []
    /// The exact line this item was last read from, if it was read from one at
    /// all. `BacklogSerializer.serializeItem` falls back to it when the line it
    /// would otherwise write does not read back to this item unchanged — a
    /// `verify:` containing `" | "` being the case that matters, since that
    /// sequence is the field separator and splits the command on the next
    /// parse. Not itself a field of the format — never read for its content,
    /// only replayed verbatim — so it is not written by `serializeItem` and is
    /// left out of the line the parser recovers from a written file.
    package var sourceLine: String?

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, title: String, verify: String? = nil, status: BacklogItemStatus, type: BacklogItemType, size: ItemSize? = nil, lane: BacklogLane = .later, flow: BacklogFlow = .standard, queries: Int? = nil, cost: Double? = nil, completedDate: String? = nil, blockedReason: String? = nil, jiraKey: String? = nil, team: String? = nil, detailPath: String? = nil, from: String? = nil, needs: [String] = [], touches: [String] = [], unrecognisedFields: [String] = [], sourceLine: String? = nil) {
        self.id = id
        self.title = title
        self.verify = verify
        self.status = status
        self.type = type
        self.size = size
        self.lane = lane
        self.flow = flow
        self.queries = queries
        self.cost = cost
        self.completedDate = completedDate
        self.blockedReason = blockedReason
        self.jiraKey = jiraKey
        self.team = team
        self.detailPath = detailPath
        self.from = from
        self.needs = needs
        self.touches = touches
        self.unrecognisedFields = unrecognisedFields
        self.sourceLine = sourceLine
    }
}

package struct BacklogItemDetail: Codable, Sendable {
    package var id: String
    package var title: String
    package var status: String?
    package var epic: String?
    package var priority: String?
    package var size: String?
    package var owner: String?
    package var jira: String?
    package var repo: String?
    package var verifyCommands: [VerifyCommand]
    package var why: String?
    package var acceptanceCriteria: [String]
    package var outOfScope: [String]
    package var context: String?
    package var notes: String?
    /// What the item is — the Jira-style description of the outcome.
    package var what: String?
    /// How it could be done — suggested approach, not a mandate.
    package var approach: String?
    /// The claims the item rests on — one per `## Premise` bullet — for the
    /// worker to check against the tree before it builds anything. Empty for
    /// an item that states none, which is most of them.
    ///
    /// Exists because of 2026-09-03: an item asserted four functions needed
    /// work, one of them did, and the first run built confident justifications
    /// for all four. The run that measured first and refused the other three
    /// was the better run, and nothing in the item had asked either worker to
    /// check. A premise written down is a premise a worker can refute.
    package var premise: [String]

    package struct VerifyCommand: Codable, Sendable {
        package var name: String
        package var cmd: String
        package var expect: String?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(name: String, cmd: String, expect: String? = nil) {
            self.name = name
            self.cmd = cmd
            self.expect = expect
        }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, title: String, status: String? = nil, epic: String? = nil, priority: String? = nil, size: String? = nil, owner: String? = nil, jira: String? = nil, repo: String? = nil, verifyCommands: [VerifyCommand], why: String? = nil, acceptanceCriteria: [String], outOfScope: [String], context: String? = nil, notes: String? = nil, what: String? = nil, approach: String? = nil, premise: [String] = []) {
        self.id = id
        self.title = title
        self.status = status
        self.epic = epic
        self.priority = priority
        self.size = size
        self.owner = owner
        self.jira = jira
        self.repo = repo
        self.verifyCommands = verifyCommands
        self.why = why
        self.acceptanceCriteria = acceptanceCriteria
        self.outOfScope = outOfScope
        self.context = context
        self.notes = notes
        self.what = what
        self.approach = approach
        self.premise = premise
    }
}

package struct BacklogSection: Identifiable, Codable, Sendable {
    package var id: String { name }
    package var name: String
    /// Optional epic-level prose shown under the heading, before its items.
    /// Round-trips through the parser/serializer.
    package var description: String?
    package var items: [BacklogItem]
    /// Lines under this heading that `BacklogParser` could not turn into items,
    /// as written. They are carried so the next write-back puts them back
    /// instead of deleting them — see `BacklogParseIssue`, which reports the
    /// same lines to the user. Re-emitted after the section's items, not in
    /// their original position.
    package var unparsedLines: [String]
    /// Prose written under this heading *after* one of its items — a note
    /// between two items, a trailing caveat at the end of the section. Only the
    /// prose above the first item becomes `description`, so these are carried so
    /// the next write-back puts them back instead of deleting them. Unlike
    /// `unparsedLines` they are not a parse issue: nothing was refused, they are
    /// simply text no item is made of. Re-emitted after the section's items, not
    /// in their original position.
    package var trailingLines: [String]

    package init(name: String, description: String? = nil, items: [BacklogItem],
         unparsedLines: [String] = [], trailingLines: [String] = []) {
        self.name = name
        self.description = description
        self.items = items
        self.unparsedLines = unparsedLines
        self.trailingLines = trailingLines
    }
}

package struct BacklogFile: Codable, Sendable {
    package var project: String
    package var repo: String?
    package var verifyDefault: String?
    package var sections: [BacklogSection]
    /// Frontmatter lines whose key is none of `project`, `repo` or
    /// `verify_default`, as written and in the order they were written.
    ///
    /// Carried for the same reason as `BacklogSection.unparsedLines` and
    /// `BacklogItem.unrecognisedFields`: the parser reads the three keys it acts
    /// on and the serializer rebuilds the block from them, so anything else in
    /// the frontmatter was deleted from the user's own file on the first status
    /// flip after it was typed — silently, and with nothing to say so. Unlike
    /// `unparsedLines` these are not a parse issue: a key the app does not use is
    /// legitimate project metadata, not a typo. Preserved, never acted on.
    ///
    /// Only lines the frontmatter reader saw as `key: value` are here; a line it
    /// could make no key out of at all never reached the point of being
    /// unrecognised.
    package var unrecognisedFrontmatterLines: [String] = []
    /// Lines between the closing frontmatter marker and the first `## ` heading,
    /// as written and in order — an introduction, house rules, a link block, and
    /// usually the file's own H1.
    ///
    /// Carried for the same reason as `unrecognisedFrontmatterLines`: the parser
    /// only ever looked at what came *after* the first epic heading, so every
    /// line above it — including a hand-written H1 that isn't the project name
    /// capitalised — was deleted on the first status flip after it was typed,
    /// silently. When this is empty the serializer falls back to generating
    /// `# <Project> Backlog`, which is what every file without a preamble already
    /// gets.
    package var preambleLines: [String] = []

    package init(project: String, repo: String? = nil, verifyDefault: String? = nil,
         sections: [BacklogSection], unrecognisedFrontmatterLines: [String] = [],
         preambleLines: [String] = []) {
        self.project = project
        self.repo = repo
        self.verifyDefault = verifyDefault
        self.sections = sections
        self.unrecognisedFrontmatterLines = unrecognisedFrontmatterLines
        self.preambleLines = preambleLines
    }

    package enum CodingKeys: String, CodingKey {
        case project, repo, verifyDefault, sections, unrecognisedFrontmatterLines, preambleLines
    }

    /// Hand-written only so a payload encoded before the frontmatter lines or
    /// the preamble were carried still decodes — a missing key is none of those,
    /// not a failure.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        verifyDefault = try container.decodeIfPresent(String.self, forKey: .verifyDefault)
        sections = try container.decode([BacklogSection].self, forKey: .sections)
        unrecognisedFrontmatterLines =
            try container.decodeIfPresent([String].self, forKey: .unrecognisedFrontmatterLines) ?? []
        preambleLines =
            try container.decodeIfPresent([String].self, forKey: .preambleLines) ?? []
    }

    /// Every item in the file by id, as the file has it *now*.
    ///
    /// The one place anything joining runs to items asks whether the work
    /// shipped — `RunEconomics` reads it so the panel's waste figure is not
    /// computed from a second, frozen answer (see the note on `RunEconomics`).
    /// An id absent from it means the backlog has nothing to say about that item,
    /// which is a different fact from the item having failed.
    package var statusByItemID: [String: BacklogItemStatus] {
        var out: [String: BacklogItemStatus] = [:]
        for section in sections {
            for item in section.items { out[item.id] = item.status }
        }
        return out
    }

    /// An id no item in the file holds, in the `<project>-NNN` shape the Add
    /// Item control and the AI editor both file new items under.
    ///
    /// Read off the ids in use, not off how many items there are: a
    /// count-derived id repeats one that is already taken the moment anything
    /// has been deleted, and the item filed under it is unreachable — every
    /// mutation resolves an id with `firstIndex(where:)`, so only the first of
    /// the two can be edited, moved or deleted.
    ///
    /// It is one past the highest number any id already carries, which is what
    /// makes the result free: an id equal to it would itself have been read as
    /// that number, and so would have raised the highest.
    ///
    /// `takenElsewhere` names ids the project has used that the file no longer
    /// holds — a removed item's detail file or run history — so a new item is
    /// never filed under one and inherits what it left behind.
    package func nextGeneratedItemID(takenElsewhere: Set<String> = []) -> String {
        let prefix = "\(project)-"
        let ids = sections.flatMap(\.items).map(\.id) + takenElsewhere
        let highest = ids.compactMap { id -> Int? in
            guard id.hasPrefix(prefix) else { return nil }
            let number = id.dropFirst(prefix.count)
            guard !number.isEmpty else { return nil }
            return Int(number)
        }.max() ?? 0
        return prefix + String(format: "%03d", highest + 1)
    }
}

/// A line of `BACKLOG.md` the parser could not turn into a usable item. The
/// panel shows these instead of the parser dropping them on the floor: a typo'd
/// checkbox otherwise makes work vanish from the UI. The line itself survives
/// the next write-back via `BacklogSection.unparsedLines`; this is what tells
/// whoever typed it that the app is not reading it as work.
package struct BacklogParseIssue: Identifiable, Codable, Sendable, Equatable {
    /// 1-based line number in the backlog file.
    package var line: Int
    /// The offending line, trimmed, as written.
    package var text: String
    /// What went wrong, phrased for whoever is editing the file.
    package var reason: String

    package var id: String { "\(line)-\(reason)" }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(line: Int, text: String, reason: String) {
        self.line = line
        self.text = text
        self.reason = reason
    }
}
