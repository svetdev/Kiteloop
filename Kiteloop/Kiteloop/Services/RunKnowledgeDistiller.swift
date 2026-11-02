import Foundation
import KiteloopCore
import os.log

private let distillerLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "run-knowledge")

/// The WRITE loop: at the end of an autopilot run, distil what happened into the
/// repo's `.kiteloop/coordinator-knowledge.md`, so the next pass starts knowing
/// what the last one learned.
///
/// This used to hang off the per-project run supervisor's `finish()`, which only
/// fired when that seam was switched on. The seam is gone; the write is not,
/// because it is the one thing the seam produced that anything downstream reads
/// — `CoordinatorQueueRefill` and `CoordinatorAdvisor` both
/// prime their prompts from that file. Its owner is now the run itself, which is
/// where the events exist and needs no flag to be true.
///
/// Two properties are deliberate. It is **fed by outcomes, not by advice**: the
/// old feed was one line per LLM recommendation, so a run nobody consulted an
/// advisor on wrote nothing at all. And it is **quiet on an uneventful run** —
/// `notableLines` is empty unless something actually went wrong, so a marathon of
/// clean items costs no LLM call and adds no noise to a file that is read into
/// every grooming prompt.
@MainActor
struct RunKnowledgeDistiller {

    /// What one finished item leaves behind, reduced to what a distiller can
    /// learn from. The same facts the run's `itemEnd` log line carries.
    struct Event: Sendable, Equatable {
        var itemID: String
        var outcome: String
        var merged: Bool
        var mergeAttempted: Bool
        var costUSD: Double
        var predictedCostUSD: Double?
        var reviewerRetries: Int
        var qualityScore: Double?
        var stalled: Bool
    }

    /// How far past its forecast an item's cost has to land before it is worth
    /// remembering. The old supervisor's `costAnomalyFactor`, kept at its value
    /// so the same runs read as surprising.
    static let costAnomalyFactor = 2.5

    /// Below this a judge score is a quality problem rather than a bad day. The
    /// old supervisor's `qualityFloor`.
    static let qualityFloor = 0.35

    // MARK: - Pure

    /// This item's cost is well above what was predicted for it.
    static func costAnomaly(actual: Double, predicted: Double?) -> Bool {
        guard let predicted, predicted > 0 else { return false }
        return actual > predicted * costAnomalyFactor
    }

    /// Whether an item is worth telling the distiller about.
    ///
    /// A clean, cheap, merged item teaches nothing that isn't already the
    /// expectation — what compounds is the item that blocked, stalled, cost
    /// several times its forecast, scored badly, needed the reviewer more than
    /// once, or passed review and still didn't land.
    static func isNotable(_ event: Event) -> Bool {
        if event.outcome.localizedCaseInsensitiveContains("blocked") { return true }
        if event.outcome.localizedCaseInsensitiveContains("cancelled") { return true }
        if event.outcome.localizedCaseInsensitiveContains("stall") || event.stalled { return true }
        if event.mergeAttempted && !event.merged { return true }
        if costAnomaly(actual: event.costUSD, predicted: event.predictedCostUSD) { return true }
        if let quality = event.qualityScore, quality < qualityFloor { return true }
        if event.reviewerRetries > 0 { return true }
        return false
    }

    /// One line per item, in the shape the distiller prompt reads.
    static func line(for event: Event) -> String {
        var out = "item=\(event.itemID) outcome=\(event.outcome)"
        out += " cost=\(String(format: "%.2f", event.costUSD))"
        if let predicted = event.predictedCostUSD {
            out += " predicted=\(String(format: "%.2f", predicted))"
        }
        if event.mergeAttempted { out += " merged=\(event.merged)" }
        if event.reviewerRetries > 0 { out += " reviewerRetries=\(event.reviewerRetries)" }
        if let quality = event.qualityScore {
            out += " quality=\(String(format: "%.2f", quality))"
        }
        if event.stalled { out += " stalled=true" }
        return out
    }

    /// The run's events, as lines, **only if any of them was notable**.
    ///
    /// All of them, not just the notable ones: a blocked item is explained by
    /// what the run was doing around it, and the distiller is asked for durable
    /// learnings rather than a list of failures. Empty when nothing happened
    /// worth a call.
    static func notableLines(_ events: [Event]) -> [String] {
        guard events.contains(where: isNotable) else { return [] }
        return events.map(line(for:))
    }

    /// How many times a class has to be overridden before it is worth a line —
    /// below this a handful of approvals could be one impatient night rather
    /// than a pattern.
    static let overrideCountThreshold = 5

    /// How much of the ledger's overrides a class has to account for, once it
    /// clears the count above — a class overridden 5 times in a ledger of 200
    /// is unremarkable; 5 of 6 is the reviewer being wrong about the same thing
    /// almost every time it is raised.
    static let overrideRateThreshold = 0.6

    /// One line per finding class that has crossed both override thresholds —
    /// the human overriding the reviewer often enough, on the same kind of
    /// finding, that the pattern is worth teaching rather than repeating.
    ///
    /// Quiet exactly like `notableLines`: an empty ledger, or one where every
    /// class stays under threshold, returns nothing rather than a line saying
    /// so. Also quiet about a class `existingKnowledge` already carries a line
    /// for — matched on this line's stable lead-in, the backticked class name
    /// followed by "findings were overridden", rather than the whole sentence,
    /// whose counts and date move on every run and would never match a bullet
    /// already on file. Without this a class over threshold re-files its line,
    /// worded slightly differently, on every run for as long as it stays over
    /// threshold, and the capped auto section evicts everything else it holds.
    static func overrideLines(_ overrides: [FindingOverrideLedger.Record],
                               existingKnowledge: String) -> [String] {
        guard !overrides.isEmpty else { return [] }
        let total = overrides.count
        let byClass = Dictionary(grouping: overrides, by: \.findingClass)
        return byClass.keys.sorted().compactMap { findingClass -> String? in
            let records = byClass[findingClass] ?? []
            let count = records.count
            guard count >= overrideCountThreshold,
                  Double(count) / Double(total) >= overrideRateThreshold else { return nil }
            let leadIn = "`\(findingClass)` \(CoordinatorKnowledge.overrideLessonMarker)"
            guard !existingKnowledge.contains(leadIn) else { return nil }
            let since = records.map(\.at).min() ?? Date()
            return "\(leadIn) \(count) of \(total) times "
                + "since \(Self.dayFormatter.string(from: since))"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Where a repo's distilled notes live.
    static func knowledgeURL(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appending(path: ".kiteloop")
            .appending(path: "coordinator-knowledge.md")
    }

    /// Put the merged notes at `url`, making the `.kiteloop` directory if this is
    /// the project's first run.
    ///
    /// Throws rather than swallowing, because the caller's return value is what
    /// the run announces as learned: with the failure hidden the operator was
    /// told the run learned N things while the file every later grooming pass
    /// reads had not changed at all. Static and given its destination so the
    /// failure can be driven — an unwritable path — without an advisor and the
    /// model call behind it.
    static func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Effectful

    let advisor: CoordinatorAdvisor
    let projectPath: String

    /// Distil and merge, returning the learnings that were written. Empty — and
    /// nothing written — when the run was uneventful, when the distiller found
    /// nothing the notes don't already say, or when the merged file could not be
    /// put on disk.
    ///
    /// That last case returns empty rather than the learnings it just paid for:
    /// what comes back here is what the run announces as learned, and learnings
    /// nobody can read back are not learned. The log line is the whole report —
    /// the caller's `learned` event simply doesn't fire.
    ///
    /// The override ledger is read here too, alongside the run's own events —
    /// its lines cost no model call, so a run with no notable events but a
    /// class that just crossed threshold still gets a call and a write, and a
    /// run with neither stays exactly as quiet as it always has.
    @discardableResult
    func run(events: [Event]) async -> [String] {
        let lines = Self.notableLines(events)
        // Raw and uncapped: this is read to merge new content into and write back,
        // and `CoordinatorAdvisor.loadKiteloopFile`'s prompt-sized cap drops whole
        // bullets from the oldest end. Fed straight to `merge` that drop would be
        // permanent — the next write would carry only what fit the cap — and fed to
        // the dedup check below it would blind that check to any override lesson
        // old enough to have aged out, re-filing it as if it were new.
        let existing = CoordinatorAdvisor.loadKiteloopFileRaw(projectPath: projectPath,
                                                              name: "coordinator-knowledge.md") ?? ""
        let overrideLines = Self.overrideLines(FindingOverrideLedger.read(
            from: FindingOverrideLedger.url(projectPath: projectPath)), existingKnowledge: existing)
        guard !lines.isEmpty || !overrideLines.isEmpty else { return [] }
        var learnings: [String] = []
        if !lines.isEmpty {
            // The prompt itself still wants the capped view — only the write path
            // needs the whole file.
            learnings = await advisor.distill(events: lines,
                                              existingKnowledge: CoordinatorAdvisor.capToReadBudget(existing),
                                              projectPath: projectPath)
        }
        learnings += overrideLines
        guard !learnings.isEmpty else { return [] }
        let url = Self.knowledgeURL(projectPath: projectPath)
        do {
            try Self.write(CoordinatorKnowledge.merge(existing: existing, newLearnings: learnings),
                           to: url)
        } catch {
            distillerLog.error("""
                Failed to write \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public) — \
                \(learnings.count, privacy: .public) learning(s) dropped
                """)
            return []
        }
        return learnings
    }
}
