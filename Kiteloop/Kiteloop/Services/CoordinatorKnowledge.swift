import Foundation

/// Merging of auto-distilled learnings into a repo's `coordinator-knowledge.md`.
/// The human-curated parts of the file are left untouched — both the head above the
/// auto section and any section written below it; new learnings land under a single
/// `## Learned (auto)` section, deduped and capped so it can't bloat.
///
/// Also the read side: what a run hands its worker and reviewer as background
/// knowledge (`background(projectPath:)`). Everything else here is pure and
/// unit-testable — that one function is the only thing that touches a file.
enum CoordinatorKnowledge {
    static let autoHeader = "## Learned (auto)"
    static let maxAutoEntries = 30

    /// The stable lead-in text `RunKnowledgeDistiller.overrideLines` gives every
    /// override-lesson bullet it files, shared here so `merge`'s cap can spot one
    /// without duplicating that phrasing. An override lesson is ledger-backed and
    /// durable — unlike an ordinary auto-distilled bullet it is not superseded by
    /// whatever happened more recently, so it must not compete with one for a slot
    /// in the capped section: evicting it on unrelated churn is indistinguishable,
    /// on the next run, from the file never having carried it, and it gets
    /// re-derived and re-filed with the same words it already had.
    static let overrideLessonMarker = "findings were overridden"

    /// The file's name under a project's `.kiteloop/`.
    static let fileName = "coordinator-knowledge.md"

    /// Lowercased, punctuation-stripped, space-collapsed — for near-duplicate checks.
    static func normalize(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Whether `outer` says everything `inner` does — both already ``normalize``d
    /// — matching on whole words only.
    ///
    /// A plain `contains` matches inside a word, and that is not a near-duplicate:
    /// a bullet reading `CI` normalizes to `ci`, which sits inside "specific", so
    /// an unrelated learning about a staging bucket would take the CI bullet's
    /// place. Normalized text is words joined by single spaces, so padding both
    /// sides with a space turns every word boundary into a literal space and the
    /// match is anchored to whole words.
    ///
    /// The near-duplicate rules in ``merge(existing:newLearnings:)`` and in
    /// ``AgentMemoryIndex/apply(fact:to:)`` are the same rule and share this.
    static func covers(_ outer: String, _ inner: String) -> Bool {
        " \(outer) ".contains(" \(inner) ")
    }

    /// Returns the updated file: the head and any section below the auto one preserved,
    /// `newLearnings` appended under the auto section (skipping near-duplicates), the
    /// section capped to the most recent `maxAutoEntries`. A learning that contains a
    /// bullet already present — as whole words, see ``covers(_:_:)`` — replaces that
    /// bullet in place rather than being dropped, otherwise a learning stored truncated
    /// would reject its own full-length correction for ever.
    static func merge(existing: String, newLearnings: [String]) -> String {
        let head: String
        var bullets: [String]
        // Everything from the next `## ` heading onwards, kept verbatim.
        var tail = ""
        if let range = existing.range(of: autoHeader) {
            head = String(existing[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // The auto section ends at the next `## ` heading, not at the end of the file:
            // a section a human wrote below it must not be flattened into the capped
            // bullet list, where its prose would be dropped and its bullets evicted.
            let rest = String(existing[range.upperBound...])
                .split(separator: "\n", omittingEmptySubsequences: false)
            let sectionEnd = rest.firstIndex { $0.hasPrefix("## ") } ?? rest.endIndex
            bullets = rest[..<sectionEnd].map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
            tail = rest[sectionEnd...].joined(separator: "\n")
        } else {
            head = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            bullets = []
        }

        // Kept parallel to `bullets` so a replacement lands at the right position.
        var norms = bullets.map { normalize(String($0.dropFirst(2))) }
        for learning in newLearnings {
            let clean = learning.trimmingCharacters(in: .whitespacesAndNewlines)
            let norm = normalize(clean)
            guard !norm.isEmpty else { continue }
            // An existing bullet that already covers this text wins — nothing to gain
            // from storing the shorter one again.
            guard !norms.contains(where: { covers($0, norm) }) else { continue }
            // The other direction is a correction, not a duplicate: the new text says
            // everything the old bullet did and more, so it takes the old bullet's place.
            if let i = norms.firstIndex(where: { covers(norm, $0) }) {
                bullets[i] = "- \(clean)"
                norms[i] = norm
                continue
            }
            bullets.append("- \(clean)")
            norms.append(norm)
        }
        bullets = capBullets(bullets)

        let headOut = head.isEmpty ? "# Coordinator knowledge" : head
        var out = headOut + "\n\n" + autoHeader + "\n" + bullets.joined(separator: "\n") + "\n"
        if !tail.isEmpty {
            out += "\n" + tail
            if !out.hasSuffix("\n") { out += "\n" }
        }
        return out
    }

    /// Trims `bullets` to `maxAutoEntries`, oldest first — except an override
    /// lesson (`overrideLessonMarker`), which is skipped over and dropped only
    /// once no ordinary bullet is left to drop instead, so a run of unrelated
    /// learnings can't age it out from under a pattern that is still active.
    private static func capBullets(_ bullets: [String]) -> [String] {
        guard bullets.count > maxAutoEntries else { return bullets }
        var trimmed = bullets
        var toDrop = trimmed.count - maxAutoEntries
        var i = 0
        while toDrop > 0, i < trimmed.count {
            if trimmed[i].contains(overrideLessonMarker) {
                i += 1
            } else {
                trimmed.remove(at: i)
                toDrop -= 1
            }
        }
        return trimmed
    }

    // MARK: - Read side: what a run shows the agents doing the work

    /// A repo's knowledge as an autopilot run hands it over: the text itself,
    /// and how many bullets it holds so the injection can be logged rather than
    /// inferred from a prompt nobody kept.
    struct Background: Equatable {
        let text: String
        let bullets: Int
    }

    /// What this project has learned, or nil when it has learned nothing — a
    /// missing file, or one that says nothing. Nil is what keeps an empty
    /// header, and its tokens, out of a run's prompts.
    ///
    /// The text goes over as it stands. The cap that keeps it small is
    /// `maxAutoEntries`, applied by `merge` when the distiller writes; a second
    /// truncation here would only give the two ways to disagree about what the
    /// file says. Read through the same `loadKiteloopFile` the grooming loop,
    /// the Coordinator chat and the advisor use, so every reader of this file
    /// sees the same bytes.
    static func background(projectPath: String) -> Background? {
        guard let text = CoordinatorAdvisor.loadKiteloopFile(projectPath: projectPath,
                                                             name: fileName) else { return nil }
        return Background(text: text, bullets: bulletCount(in: text))
    }

    /// Markdown bullets at any indent, in the auto section and the human ones
    /// alike — the unit the cap counts in, and what the run log reports.
    static func bulletCount(in text: String) -> Int {
        text.split(separator: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("- ") || line.hasPrefix("* ")
        }.count
    }
}
