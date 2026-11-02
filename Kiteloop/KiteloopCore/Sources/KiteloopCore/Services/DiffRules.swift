import Foundation

/// Three Definition-of-Done rules a reviewer used to be asked to hold in
/// mind and a diff can answer by itself.
///
/// `docs/suite-status.md` is an instrument: only `scripts/run-unit-suite.sh`
/// writes it, and a row arriving in any other item's diff is a measurement
/// nobody took, however plausible its numbers. That rule shipped past a
/// reviewer once (2026-08-11, a 3,077-test green row typed by a worker) and
/// sat in `CLAUDE.md` as prose afterwards. Here it is a finding: the diff
/// touches the file and the item is not about that mechanism, so the run is
/// blocked with the reason.
///
/// A change in behaviour is described in `CHANGELOG.md`. Whether behaviour
/// changed is a judgement — a refactor, a comment, an ADR need no line, and a
/// line invented for them is itself a defect — so this rule is advisory: the
/// diff changed Swift under `Kiteloop/` and left the changelog alone, and the
/// item's notes say so for the person who decides.
///
/// A secret-shaped string is the one thing a diff must never carry past this
/// point: an API key, a token, a private key block. Unlike the two rules
/// above this one reads the *content* of the added lines, not just the
/// changed paths — a small, explicit pattern set, no entropy heuristics — and
/// is blocking rather than advisory: the matched value itself is never
/// repeated in the finding, only the file, the line and which pattern it was.
/// A line that only *removes* such a string raises nothing.
///
/// Pure: given the changed paths, the item's id and title, and the diff's
/// text, the findings. The autopilot reads the paths off git
/// (`RunWorkEvidence.changedFiles`) and routes a blocking finding the way it
/// routes a verify-coverage gap.
package enum DiffRules {

    package enum Severity: String, Equatable, Sendable {
        case blocking
        case advisory
    }

    package struct Finding: Equatable, Sendable {
        package let severity: Severity
        package let text: String

        package init(severity: Severity, text: String) {
            self.severity = severity
            self.text = text
        }
    }

    /// The instrument file, repo-relative.
    package static let suiteStatusPath = "docs/suite-status.md"
    /// The changelog, repo-relative.
    package static let changelogPath = "CHANGELOG.md"

    /// The quality ratchets' baselines, repo-relative. Widening one gets a
    /// gate past green; CLAUDE.md asks for the reason in the commit when
    /// that is done on purpose, and this rule is what notices it happened.
    package static let ratchetBaselinePaths = [
        "Kiteloop/.swiftlint-baseline.json",
        "Kiteloop/.crap-baseline.json",
        "quality/complexity-lizard-baseline.json",
    ]

    /// Words in an item's id or title that say the item *is* about the suite
    /// record, which is the one case a diff may carry it.
    package static let suiteRecordWords = ["suite-status", "suite status", "run-unit-suite", "suite record"]

    /// Name and regex for each secret shape `secretFindings` scans an added
    /// line against. Explicit prefixes and shapes only — no entropy scoring —
    /// so a match is a fact about the string's shape, not a guess about its
    /// randomness.
    package static let secretPatterns: [(name: String, pattern: String)] = [
        ("an Anthropic API key", #"sk-ant-[A-Za-z0-9_-]{10,}"#),
        ("an AWS access key id", #"AKIA[0-9A-Z]{16}"#),
        ("a GitHub token", #"(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#),
        ("a Slack token", #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
        ("a private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ]

    /// `diffText` defaults to empty — a caller with only paths in hand (every
    /// existing call site until this rule was added) still gets the same two
    /// findings as before, since an empty diff has no added line to scan.
    package static func evaluate(
        changedFiles: [String], itemID: String, itemTitle: String, diffText: String = ""
    ) -> [Finding] {
        suiteRecordFinding(changedFiles: changedFiles, itemID: itemID, itemTitle: itemTitle)
            + changelogFinding(changedFiles: changedFiles)
            + ratchetBaselineFinding(changedFiles: changedFiles)
            + secretFindings(diffText: diffText)
    }

    private static func suiteRecordFinding(changedFiles: [String], itemID: String, itemTitle: String) -> [Finding] {
        let about = (itemID + " " + itemTitle).lowercased()
        guard changedFiles.contains(suiteStatusPath),
              !suiteRecordWords.contains(where: { about.contains($0) }) else { return [] }
        return [Finding(
            severity: .blocking,
            text: "the diff touches \(suiteStatusPath), which only scripts/run-unit-suite.sh may write — "
                + "a row from any other item is a measurement nobody took; drop it from the branch")]
    }

    private static func changelogFinding(changedFiles: [String]) -> [Finding] {
        let swiftChanged = changedFiles.filter { path in
            path.hasSuffix(".swift")
                && (path.hasPrefix("Kiteloop/Kiteloop/") || path.hasPrefix("Kiteloop/KiteloopCore/Sources/")
                    || path.hasPrefix("KiteloopMobile/Sources/"))
        }
        guard !swiftChanged.isEmpty, !changedFiles.contains(changelogPath) else { return [] }
        return [Finding(
            severity: .advisory,
            text: "the diff changes \(count(swiftChanged.count, "Swift file")) and not \(changelogPath) — "
                + "if behaviour changed, add one line under the unreleased heading; if not, this is nothing")]
    }

    private static func ratchetBaselineFinding(changedFiles: [String]) -> [Finding] {
        let touched = ratchetBaselinePaths.filter(changedFiles.contains)
        guard !touched.isEmpty else { return [] }
        return [Finding(
            severity: .advisory,
            text: "the diff touches \(touched.joined(separator: ", ")) — "
                + "if this widens the ratchet on purpose, say why in the commit")]
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// A line an added-lines walk found, paired with the file it lands in and
    /// its line number in the *new* file — what `git diff` itself would report
    /// for a `blame`, so a finding can point straight at it.
    private struct AddedLine {
        let path: String
        let lineNumber: Int
        let text: String
    }

    private static func secretFindings(diffText: String) -> [Finding] {
        guard !diffText.isEmpty else { return [] }
        return addedLines(in: diffText).compactMap { line in
            guard let name = secretPatterns.first(where: {
                line.text.range(of: $0.pattern, options: .regularExpression) != nil
            })?.name else { return nil }
            return Finding(
                severity: .blocking,
                text: "the diff adds \(name) in \(line.path):\(line.lineNumber) — "
                    + "a credential must not leave this machine; drop it from the branch "
                    + "before this reaches review")
        }
    }

    /// Walks a unified diff's added lines only — a line a hunk only removes
    /// never appears here, so a diff that deletes a secret-shaped line raises
    /// nothing — pairing each with the file it lands in and its line number in
    /// the new file, read off the hunk header the same way `git diff` numbers
    /// it.
    private static func addedLines(in diffText: String) -> [AddedLine] {
        var results: [AddedLine] = []
        var currentPath: String?
        var newLineNumber = 0
        for line in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                currentPath = filePath(fromDiffHeader: line)
                continue
            }
            if line.hasPrefix("@@") {
                newLineNumber = newFileStartLine(fromHunkHeader: line) ?? newLineNumber
                continue
            }
            guard let path = currentPath else { continue }
            if line.hasPrefix("+") {
                results.append(AddedLine(path: path, lineNumber: newLineNumber, text: String(line.dropFirst())))
                newLineNumber += 1
            } else if line.hasPrefix("-") || line.hasPrefix("\\") {
                continue
            } else {
                newLineNumber += 1
            }
        }
        return results
    }

    /// The path off a `+++ b/<path>` header — nil for `+++ /dev/null`, a
    /// file the diff deletes and so has no new-file lines to number.
    private static func filePath(fromDiffHeader line: Substring) -> String? {
        let path = line.dropFirst(4)
        guard path != "/dev/null" else { return nil }
        return path.hasPrefix("b/") ? String(path.dropFirst(2)) : String(path)
    }

    /// The new-file range's start from a `@@ -a,b +c,d @@` header.
    private static func newFileStartLine(fromHunkHeader line: Substring) -> Int? {
        guard let plusIndex = line.firstIndex(of: "+") else { return nil }
        let digits = line[line.index(after: plusIndex)...].prefix(while: \.isNumber)
        return Int(digits)
    }
}
