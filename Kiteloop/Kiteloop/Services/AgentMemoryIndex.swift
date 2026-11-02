import Foundation

/// The shape of an agent's per-agent memory, and the rules that keep it bounded.
///
/// Memory used to be one append-only `memory.md` that rode into every system
/// prompt whole. That is the failure mode every always-injected memory has: it
/// only grows, and adherence to a long instruction file collapses long before
/// the context window does. So memory is two tiers, the same two the knowledge
/// packages already use (`KnowledgeRecallService`):
///
/// - an **index** — one line per fact, hard-capped at ``maxFacts``, always
///   injected;
/// - **topic bodies** — the full text of each fact, one file per topic, read on
///   demand through the `recall_knowledge` path.
///
/// The cap is enforced on write. Past it a write is either **rejected with a
/// reason** the proposer sees or **displaces** an existing fact by one of the
/// explicit rules in ``apply(fact:to:)``. Silently dropping or truncating a fact
/// is the one outcome that must never happen: the index is what the agent is
/// told it knows, so a fact that vanished without a word is worse than one that
/// was never written.
///
/// Pure and unit-testable — no file I/O here; ``MemoryManager`` owns the files.
enum AgentMemoryIndex {

    /// How many facts the always-injected index may carry.
    ///
    /// Roughly a screenful, and — at a headline apiece — a few hundred tokens
    /// rather than the unbounded transcript the old file became.
    static let maxFacts = 50

    /// First line of an index file. Its presence is how a file already in index
    /// form is told apart from a legacy `memory.md` that still needs migrating.
    static let header = "# Memory Index"

    static let preamble =
        "One line per fact. The full text of each lives in `memory/<topic>.md` — "
        + "call `recall_knowledge` with a topic name or a phrase to read one."

    // MARK: - A fact

    /// One line of the index. The headline is a summary; the whole of what was
    /// approved is kept in the topic body, so nothing here is the only copy.
    struct Fact: Equatable, Sendable {
        /// `yyyy-MM-dd`, or empty when the fact predates the index (a migrated
        /// `memory.md` records no date — guessing one would be inventing it).
        var date: String
        var headline: String
        /// Slug naming this fact's body file, `memory/<topic>.md`.
        var topic: String
        /// Topic this fact was written to replace, when the proposer said so.
        var supersedes: String?

        func rendered() -> String {
            var line = "- "
            if !date.isEmpty { line += "\(date) — " }
            line += headline
            if !topic.isEmpty { line += " [\(topic)]" }
            if let superseded = supersedes, !superseded.isEmpty {
                line += " (supersedes: \(superseded))"
            }
            return line
        }
    }

    /// What a write did. `rejected` carries the sentence the proposer is shown —
    /// it has to say what to do next, not only that the door was shut.
    enum WriteOutcome: Equatable, Sendable {
        case appended(facts: [Fact])
        /// The new fact took an existing one's place; `displaced` names the
        /// topic whose line is gone (its body file stays on disk).
        case replaced(facts: [Fact], displaced: String)
        case rejected(reason: String)
    }

    // MARK: - Text helpers

    /// Lowercased, punctuation-stripped, space-collapsed — for near-duplicate
    /// checks, the same normalisation `CoordinatorKnowledge` uses.
    static func normalize(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// A filename-safe topic name derived from a headline. Never empty: a
    /// headline of pure punctuation still needs somewhere to put its body.
    static func slug(for headline: String) -> String {
        let words = normalize(headline).split(separator: " ").prefix(8)
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? "fact" : String(joined.prefix(60))
    }

    /// `slug(for:)`, made unique against topics already in use by suffixing a
    /// counter — two facts must never share a body file.
    static func uniqueSlug(for headline: String, taken: Set<String>) -> String {
        let base = slug(for: headline)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Reading a proposal

    /// The longest a headline may run before the index line stops being a line.
    /// Shortening here loses nothing — the body file holds the approved text in
    /// full — and the ellipsis says on its face that there is more to read.
    static let maxHeadlineLength = 200

    /// Turns approved proposal text into an index line plus the slug its body
    /// will be filed under.
    ///
    /// The headline is the first non-empty line, with a bullet or heading marker
    /// stripped; a `supersedes: <topic>` line anywhere in the text is read as the
    /// proposer's instruction to replace that fact rather than add to the index.
    static func fact(from content: String, date: String, taken: Set<String>) -> Fact? {
        var supersedes: String?
        var headline = ""

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = supersedesValue(in: line) {
                supersedes = value
                continue
            }
            guard !line.isEmpty else { continue }
            if headline.isEmpty {
                headline = strippingMarkers(line)
            }
        }

        headline = headline.trimmingCharacters(in: .whitespaces)
        guard !headline.isEmpty else { return nil }
        if headline.count > maxHeadlineLength {
            headline = String(headline.prefix(maxHeadlineLength)).trimmingCharacters(in: .whitespaces) + "…"
        }

        return Fact(
            date: date,
            headline: headline,
            topic: uniqueSlug(for: headline, taken: taken),
            supersedes: supersedes
        )
    }

    private static func supersedesValue(in line: String) -> String? {
        let marker = "supersedes:"
        guard line.lowercased().hasPrefix(marker) else { return nil }
        let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func strippingMarkers(_ line: String) -> String {
        var s = Substring(line)
        while let first = s.first, first == "#" || first == "-" || first == "*" || first == ">" {
            s = s.dropFirst()
            while s.first == " " { s = s.dropFirst() }
        }
        return String(s)
    }

    // MARK: - The budget

    /// Applies `fact` to `facts` under the cap, in this order:
    ///
    /// 1. an explicit `supersedes:` wins — it replaces the named fact in place,
    ///    and naming nothing is rejected rather than quietly ignored;
    /// 2. a fact an existing line already covers is rejected, naming the line;
    /// 3. a fact that covers an existing line is a correction, and takes its
    ///    place — otherwise a fact stored short would reject its own fuller
    ///    rewrite for ever (`CoordinatorKnowledge.merge` has the same rule);
    ///    both directions read "covers" as whole words, through
    ///    ``CoordinatorKnowledge/covers(_:_:)``;
    /// 4. at the cap, rejected with the cap named and the way past it spelled
    ///    out. Nothing is evicted to make room: which fact is least worth
    ///    keeping is a judgement, and making it silently is how memory quietly
    ///    forgets the one thing it was told to remember.
    static func apply(fact: Fact, to facts: [Fact]) -> WriteOutcome {
        let norm = normalize(fact.headline)
        guard !norm.isEmpty else {
            return .rejected(reason: "the proposed memory has no text to record.")
        }

        if let superseded = fact.supersedes {
            guard let i = facts.firstIndex(where: { $0.topic == superseded }) else {
                return .rejected(reason: """
                    supersedes: \(superseded) names no fact in the index. \
                    Use one of the topic names in square brackets, or drop the line to add a new fact.
                    """)
            }
            var out = facts
            out[i] = fact
            return .replaced(facts: out, displaced: superseded)
        }

        if let covering = facts.first(where: { CoordinatorKnowledge.covers(normalize($0.headline), norm) }) {
            return .rejected(reason: """
                already covered by an existing fact: \(covering.headline) [\(covering.topic)]. \
                Say something the index does not, or write `supersedes: \(covering.topic)` to replace it.
                """)
        }

        if let i = facts.firstIndex(where: { CoordinatorKnowledge.covers(norm, normalize($0.headline)) }) {
            var out = facts
            let displaced = out[i].topic
            out[i] = fact
            return .replaced(facts: out, displaced: displaced)
        }

        guard facts.count < maxFacts else {
            return .rejected(reason: """
                the memory index is full (\(facts.count) of \(maxFacts) facts). \
                Add `supersedes: <topic>` naming the fact this replaces, or prune the index in the Memory tab.
                """)
        }

        return .appended(facts: facts + [fact])
    }

    // MARK: - The file

    /// Parses an index file. Lines that are not index bullets — the header, the
    /// preamble, anything a human added — are not facts and are not returned
    /// here; ``tail(of:)`` is what reads back a human's own text below the fact
    /// list, and ``render(facts:tail:)`` is what writes it back rather than
    /// dropping it.
    static func parse(_ text: String) -> [Fact] {
        text.components(separatedBy: .newlines).compactMap { parseLine($0) }
    }

    /// Whatever a human wrote below the fact list — a `## ` section, a
    /// paragraph, anything after the last bullet — read back verbatim so a
    /// write-back does not erase it.
    ///
    /// Reads by position, the same frame ``render(facts:tail:)`` writes: past
    /// the preamble and its separating blank line, the contiguous run of fact
    /// bullets is the fact list; everything after it, once the blank line
    /// separating the two is dropped, is the tail. A file with no preamble line
    /// at all (not an index, or corrupted) has no frame to read a tail out of,
    /// so it answers empty rather than guessing.
    static func tail(of text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let preambleIndex = lines.firstIndex(of: preamble) else { return "" }
        var rest = Array(lines[(preambleIndex + 1)...])

        if let first = rest.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            rest.removeFirst()
        }
        while let first = rest.first, parseLine(first) != nil {
            rest.removeFirst()
        }
        while let first = rest.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            rest.removeFirst()
        }

        guard !rest.isEmpty else { return "" }
        return rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseLine(_ rawLine: String) -> Fact? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("- ") else { return nil }
        var rest = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }

        var supersedes: String?
        if rest.hasSuffix(")"), let open = rest.range(of: " (supersedes: ", options: .backwards) {
            supersedes = String(rest[open.upperBound...].dropLast()).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<open.lowerBound])
        }

        var topic = ""
        if rest.hasSuffix("]"), let open = rest.range(of: " [", options: .backwards) {
            topic = String(rest[open.upperBound...].dropLast()).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<open.lowerBound])
        }

        var date = ""
        if let dash = rest.range(of: " — ") {
            let candidate = String(rest[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            if isDate(candidate) {
                date = candidate
                rest = String(rest[dash.upperBound...])
            }
        }

        let headline = rest.trimmingCharacters(in: .whitespaces)
        guard !headline.isEmpty else { return nil }
        return Fact(date: date, headline: headline, topic: topic, supersedes: supersedes)
    }

    private static func isDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Renders the index. `tail`, when non-empty, is a human's own text —
    /// ``tail(of:)`` read it back from the file being rewritten — and is written
    /// back verbatim below the fact list rather than being dropped.
    static func render(facts: [Fact], tail: String = "") -> String {
        var lines = [header, "", preamble, ""]
        lines.append(contentsOf: facts.map { $0.rendered() })
        var out = lines.joined(separator: "\n") + "\n"
        if !tail.isEmpty {
            out += "\n" + tail + "\n"
        }
        return out
    }

    /// True when `text` is already an index — used to tell a file that needs
    /// migrating from one that has been migrated already.
    static func isIndex(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(header)
    }

    // MARK: - The body file

    static func renderBody(fact: Fact, content: String) -> String {
        var front = ["---", "topic: \(fact.topic)"]
        if !fact.date.isEmpty { front.append("date: \(fact.date)") }
        if let superseded = fact.supersedes, !superseded.isEmpty {
            front.append("supersedes: \(superseded)")
        }
        front.append("---")
        return front.joined(separator: "\n") + "\n\n"
            + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// `yyyy-MM-dd` for a fact written now.
    ///
    /// The calendar is pinned to Gregorian and the locale to POSIX so the line is
    /// the same everywhere — a date that reads `2569-08-11` under a Buddhist
    /// calendar is unparseable by ``parseLine(_:)`` and unreadable by anyone
    /// else. The time zone is the user's: the day meant is the day they approved
    /// it.
    static func today(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
