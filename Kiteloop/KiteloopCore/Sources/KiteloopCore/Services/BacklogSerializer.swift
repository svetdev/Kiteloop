import Foundation
import os.log

private let backlogSerializerLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog")

/// Where a write that kept an item's existing line is reported.
///
/// Keeping the line is right — the new one would read back as a different
/// item — but it also means the item's status change never lands: a run picked
/// up stays `ready`, a finished one never reads done. Said only in the system
/// log, nothing in the app explained it. This files it through
/// ``StoreProblemReporter`` as a backlog write problem naming the item, once per
/// item: every save rewrites every line, so the same kept line would otherwise
/// be reported on every status flip anywhere in the file.
package final class BacklogKeptLineReport: Sendable {

    /// The store name a kept line reports under — read in a notification
    /// title, and half the reporter's dedup key.
    package static let storeName = "backlog"

    /// What the reporter is handed as the error: the item, and why its line
    /// was kept.
    package struct KeptLine: Error, CustomStringConvertible {
        package let itemID: String
        package var description: String {
            "item \(itemID): its line was kept because the new one would not read back the same"
        }
    }

    private let reporter: StoreProblemReporter
    private let url: URL
    private let reported = OSAllocatedUnfairLock(initialState: Set<String>())

    package init(reporter: StoreProblemReporter, url: URL) {
        self.reporter = reporter
        self.url = url
    }

    /// Reports that `itemID`'s existing line was kept — the first time only.
    package func keptLine(for itemID: String) {
        let isNew = reported.withLock { $0.insert(itemID).inserted }
        guard isNew else { return }
        reporter.report(store: Self.storeName, operation: .write, url: url,
                        error: KeptLine(itemID: itemID))
    }
}

package struct BacklogSerializer {

    /// Where a kept line is reported, for the write the caller scopes it to
    /// with `$keptLines.withValue(_:operation:)`. Nil — the default — reports
    /// nothing: a line built only to be compared, never written, is no write
    /// that failed to land.
    @TaskLocal package static var keptLines: BacklogKeptLineReport?

    package static func serialize(_ file: BacklogFile) -> String {
        var lines: [String] = []

        lines.append("---")
        lines.append("project: \(file.project)")
        if let repo = file.repo {
            lines.append("repo: \(repo)")
        }
        if let verify = file.verifyDefault {
            lines.append("verify_default: \(verify)")
        }
        // Frontmatter keys the parser had no use for, written back as they came
        // in. Closing the block on the three keys above deleted everything else
        // the user had put there on the first status flip — silently, and with
        // no parse issue to say so, since a key the app does not act on is
        // legitimate metadata rather than a mistake. Not repaired and not put
        // back where they were: written after the known keys, in the order they
        // were read.
        lines.append(contentsOf: file.unrecognisedFrontmatterLines.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })
        lines.append("---")
        lines.append("")
        // The lines above the first epic heading, as they came in — usually
        // starting with the file's own H1. Only when there were none of these
        // to keep is a heading generated from the project name: a preamble that
        // already carries an H1 must not also get a second, generated one.
        if file.preambleLines.isEmpty {
            lines.append("# \(file.project.capitalized) Backlog")
        } else {
            lines.append(contentsOf: file.preambleLines)
        }

        for section in file.sections {
            lines.append("")
            let sectionHeader = section.name == "Bugs" ? "## Bugs" : "## Epic: \(section.name)"
            lines.append(sectionHeader)
            if let description = section.description,
               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
                lines.append(contentsOf: description.components(separatedBy: "\n"))
            }
            for item in section.items {
                lines.append(line(for: item))
            }
            // Lines the parser refused, written back as they came in. They are
            // the user's work too: a typo'd checkbox already hides the line from
            // the panel, and dropping it here would delete it from the file on
            // the first status flip after that. Not repaired and not reordered —
            // preserved, and still reported as a parse issue.
            lines.append(contentsOf: section.unparsedLines)
            // Prose the section carried after its first item — a note between
            // two items, a caveat at the end. It is written back for the same
            // reason as the lines above it: only the prose above the first item
            // becomes the description, so everything below it was deleted on the
            // first status flip after it was typed, silently and with no parse
            // issue to say so. Re-emitted after the items rather than where it
            // was written.
            lines.append(contentsOf: section.trailingLines)
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The line `item` is written back as.
    ///
    /// An item nothing changed is written back exactly as it was read: its
    /// `sourceLine`, re-read, still says everything the item says, so the
    /// bytes on disk stay the bytes the user wrote. Re-rendering every line
    /// from its fields instead made one status flip rewrite the whole file.
    /// A changed item is rendered from its fields. `verify_default` plays no
    /// part: no item inherits it, so none has it written onto its line.
    package static func line(for item: BacklogItem) -> String {
        guard let source = item.sourceLine else { return serializeItem(item) }
        if let reread = BacklogParser.parseItemLine(source, verifyDefault: nil),
           roundTripsCleanly(reread, item) {
            return source
        }
        return serializeItem(item)
    }

    package static func serializeItem(_ item: BacklogItem) -> String {
        let checkbox = item.status == .done ? "[x]" : "[ ]"
        var parts: [String] = []

        if item.type == .jira, let key = item.jiraKey {
            parts.append("JIRA:\(key)")
        } else {
            parts.append(item.id)
        }

        parts.append(item.title)

        if let verify = item.verify {
            parts.append("verify: \(verify)")
        }

        if let size = item.size {
            parts.append("size:\(size.rawValue)")
        }

        // The lane, beside the size it reads like: one word, taken from a fixed
        // set, saying something about the item rather than about where it
        // stands. Only `now` is ever written — `later` is the default, so
        // leaving it off is what says it, and a line that never asked for a lane
        // comes back byte-for-byte as it was written.
        parts.append(contentsOf: runFields(item))

        parts.append(contentsOf: relationFields(item))

        if item.status == .done {
            if let q = item.queries { parts.append("\(q)q") }
            if let c = item.cost { parts.append("$\(String(format: "%.2f", c))") }
            if let d = item.completedDate { parts.append(d) }
        } else if item.type == .jira, let team = item.team {
            parts.append(team)
            parts.append(item.status.rawValue)
        } else {
            switch item.status {
            case .blocked:
                if let reason = item.blockedReason {
                    parts.append("blocked:\(reason)")
                } else {
                    parts.append("blocked")
                }
            case .done:
                break
            case .draft, .ready, .active, .inReview, .awaitingApproval:
                parts.append(item.status.rawValue)
            }
        }

        var line = "- \(checkbox) \(parts.joined(separator: " | "))"
        // Preserve the detail link — dropping it here would silently orphan
        // every item's detail file on the next write-back.
        if let detailPath = item.detailPath {
            line += " → [detail](\(detailPath))"
        }
        return reconciled(line, for: item)
    }

    /// The tokens that say what this item relates to — what it waits for, what
    /// it came from, what it is allowed to touch — followed by the fields the
    /// parser could not read.
    ///
    /// Sequencing, then provenance, then permissions: written before the stage
    /// tokens so the line reads "what it is", "what it relates to", "where it
    /// stands".
    ///
    /// The unreadable fields are the user's text too: the parse issue tells
    /// whoever typed the line to fix it, and dropping them here deleted the
    /// thing it was about on the first status flip after that — the tail of a
    /// spaced-pipe `verify:` most of all. Not repaired and not put back where
    /// they were — preserved, ahead of the stage tokens so the line still reads
    /// the same way, and still reported as a parse issue on the next read.

    /// The lane and the flow, each written only when it is not the default —
    /// `lane:now`, `flow:qa` — so a line that never asked for either comes back
    /// byte-for-byte as it was written.
    static func runFields(_ item: BacklogItem) -> [String] {
        var fields: [String] = []
        if item.lane == .now { fields.append("lane:\(BacklogLane.now.rawValue)") }
        if item.flow == .qa { fields.append("flow:\(BacklogFlow.qa.rawValue)") }
        return fields
    }

    private static func relationFields(_ item: BacklogItem) -> [String] {
        var parts: [String] = []

        let needs = item.needs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !needs.isEmpty {
            parts.append("needs:\(needs.joined(separator: ","))")
        }

        if let from = item.from, !from.isEmpty {
            parts.append("from:\(from)")
        }

        let touches = item.touches.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !touches.isEmpty {
            parts.append("touches:\(touches.joined(separator: ","))")
        }

        parts.append(contentsOf: item.unrecognisedFields.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })
        return parts
    }

    /// Refuses a line the parser would not read back as this item.
    ///
    /// The fields above are split on `" | "` by `BacklogParser`, so a value
    /// that itself contains that sequence — a `verify:` whose pipe was written
    /// with spaces being the case this exists for — breaks apart on the next
    /// read: the tail becomes a field nothing claims, and the item that runs is
    /// not the one that was written. Written straight to disk, that is silent;
    /// nothing about a truncated command *looks* wrong until whatever it was
    /// supposed to check fails to run.
    ///
    /// The check is the round trip itself — parse the line just built and
    /// compare what comes back against `item` — so there is no second
    /// definition of "reads back correctly" to drift from the parser's own.
    /// On a mismatch the freshly built line is not written: `item.sourceLine`,
    /// the line this item last read back correctly from, stands in for it. An
    /// item with no such line — never on disk, or already truncated there
    /// before this item ever loaded it — has nothing to fall back to; the line
    /// is written anyway; only the log line marks that it happened, since
    /// reconstructing a command this app never saw whole is authoring, not
    /// serialising, and repairing an already-truncated line is deliberately
    /// not this function's job. A kept line is also told to ``keptLines``,
    /// since the item it belongs to will not change on disk.
    private static func reconciled(_ line: String, for item: BacklogItem) -> String {
        guard let reparsed = BacklogParser.parseItemLineWithUnrecognisedFields(line, verifyDefault: nil)?.item,
              roundTripsCleanly(reparsed, item)
        else {
            backlogSerializerLog.error(
                "backlog: lossy write for item \(item.id, privacy: .public) — the line the parser would read back differs from the item; \(item.sourceLine == nil ? "no prior line to fall back to, writing anyway" : "kept the existing line", privacy: .public)"
            )
            guard let kept = item.sourceLine else { return line }
            keptLines?.keptLine(for: item.id)
            return kept
        }
        return line
    }

    /// Whether `reparsed` — the item the line just built would read back as —
    /// carries the same fields as `item`.
    ///
    /// Every field is compared, `sourceLine` excepted: it names where a line
    /// came from, not what the line says, so comparing it would fail this check
    /// on every single write. Comparing the whole value rather than a list of
    /// fields written out by hand is what keeps this honest as the format
    /// grows — a field added to `BacklogItem` and forgotten here would let a
    /// line that loses it pass as a clean round trip.
    private static func roundTripsCleanly(_ reparsed: BacklogItem, _ item: BacklogItem) -> Bool {
        var comparable = reparsed
        comparable.sourceLine = item.sourceLine
        return comparable == item
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init() {
    
    }
}
