import Foundation
import os

/// Does an item's `verify:` actually cover what its run changed?
///
/// `DefinitionOfReady` checks that an item *has* a verify command, and the
/// reviewer checks that it passed. Nothing checked that the command exercises
/// the code the diff touched, so a run whose changes reach past its command
/// merges having verified only the half the command happens to build.
///
/// That shipped. On 2026-08-08 the travel item `test-expert-profile` asked for
/// component tests against a mocked api; what merged also carried a new write
/// endpoint, a query rewrite to compile-checked macros and a ratchet change —
/// all Rust, behind a `verify:` of `npm --prefix apps/web test`, which never
/// compiles Rust. The backend half merged with nothing having checked it. It
/// happened to compile; nothing in the loop knew that.
///
/// The check is a file-path comparison and nothing more: a repo-level map of
/// path glob → the command that covers it, the run's changed files, and the
/// commands the item declared. No model, no score, no threshold to tune — which
/// is the whole appeal, because a deterministic gate can be blocking.
///
/// Three deliberate limits, each of which keeps this from becoming a gate that
/// costs more than it catches:
///   * a repo with no map configured is not gated at all. The mechanism ships
///     empty; a project opts in by writing `kiteloop-verify.json` at its root;
///   * a changed file matching no glob is not a gap. An unmapped path is an
///     unmade statement, not a claim that nothing covers it;
///   * a gap is **run, not waved through**: the autopilot runs the missing
///     command on the run's branch and blocks only when it fails or times out,
///     noting on the item which command it ran. This type only names the gap.
///
/// Pure — the map is loaded and the diff is read by the caller — so the rules
/// can be exercised without a repo on disk.
package enum VerifyCoverage {

    // MARK: - The map

    /// One repo-level claim: files matching `glob` are covered by `command`.
    package struct Rule: Equatable, Sendable, Codable {
        /// A repo-relative path glob. `*` matches within one path segment, `?`
        /// one character, `**` any number of segments.
        package let glob: String
        /// The command that covers those files. Matched against what the item
        /// declared, not run (see `evaluate`).
        package let command: String
        /// How the command is *added* to a `verify:` that lacks it — the
        /// runnable spelling, when `command` is only the prefix a match needs.
        /// `xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop` matches
        /// every build of that scheme but runs nothing on its own; its `run` is
        /// `cd Kiteloop && xcodebuild … build-for-testing`. Absent, `command`
        /// is run as written, from the repo root.
        package let run: String?

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(glob: String, command: String, run: String? = nil) {
            self.glob = glob
            self.command = command
            self.run = run
        }

        /// What a widened `verify:` gains for this rule.
        package var runnable: String {
            let spelled = (run ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return spelled.isEmpty ? command : spelled
        }
    }

    /// The project's map, in the order it was written — which is the order gaps
    /// are reported in, so the same diff always reads the same way.
    package struct Map: Equatable, Sendable, Codable {
        package let rules: [Rule]

        package init(rules: [Rule]) { self.rules = rules }

        package var isEmpty: Bool { rules.isEmpty }

        /// No map: the state every project is in until someone writes one, and
        /// the state in which this check does nothing at all.
        package static let none = Map(rules: [])

        /// Reads the map at `url`. A missing file is the normal case
        /// and reads as `none`; so does a file that is there but unreadable or
        /// malformed, because a typo in a config file must not block an
        /// otherwise finished run — `loadReporting` is there for a caller that
        /// wants to say so.
        package static func load(from url: URL?) -> Map {
            loadReporting(from: url).map
        }

        /// `load`, plus a phrase naming what a file that *is* there failed to
        /// contribute — it could not be parsed, it parsed to no usable rules at
        /// all, or some of its rules were dropped and the rest still stand.
        ///
        /// Only a file's absence is silent. A file someone wrote that checks
        /// nothing is the case this type's own doc warns about: it lets every run
        /// through exactly as no map does, and afterwards reads as coverage. So
        /// an empty `rules` list, and rules whose glob or command is blank, are
        /// said out loud in the same shape a malformed file is — naming the file,
        /// ending `— coverage not checked` — with how many of the rules the file
        /// held were dropped, which is what someone has to go and fix.
        package static func loadReporting(from url: URL?) -> (map: Map, problem: String?) {
            guard let url else { return (.none, nil) }
            let file = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                guard FileManager.default.fileExists(atPath: url.path) else { return (.none, nil) }
                return (.none, "verify map at \(file) could not be read — coverage not checked")
            }
            guard let decoded = try? JSONDecoder().decode(Map.self, from: data) else {
                return (.none, "verify map at \(file) could not be read — coverage not checked")
            }
            let rules = decoded.rules.filter {
                !normalize($0.glob).isEmpty && !normalize($0.command).isEmpty
            }
            let held = decoded.rules.count
            let dropped = held - rules.count
            guard !rules.isEmpty else {
                let why = held == 0
                    ? "holds no rules"
                    : "holds \(held) \(held == 1 ? "rule" : "rules"), "
                        + "all of them naming a blank glob or command"
                return (.none, "verify map at \(file) \(why) — coverage not checked")
            }
            guard dropped == 0 else {
                // The map still checks something, so this is not the silent case
                // — but the dropped rules cover nothing and nobody would know.
                return (Map(rules: rules),
                        "verify map at \(file) dropped \(dropped) of its \(held) rules "
                            + "for a blank glob or command — the remaining "
                            + "\(rules.count) \(rules.count == 1 ? "is" : "are") checked")
            }
            return (Map(rules: rules), nil)
        }
    }

    /// The other way this check ends up checking nothing: the map parsed, but git
    /// could not say what the run changed — a branch teardown dropped, a
    /// repository git can't open.
    ///
    /// Said out loud in the same shape as a malformed map's `problem`, and for
    /// the same reason. `evaluate` reads an empty path list as `.covered`, so an
    /// unreadable diff passes the gate; the gate fails open by design, but a run
    /// that passed it having compared nothing must not read in the log like one
    /// that was genuinely covered.
    package static func unreadableDiff(branch: String) -> String {
        "diff of branch \(branch) could not be read from git — coverage not checked"
    }

    // MARK: - Widening a verify the gap named

    /// The commands a gap summary says the verify never ran — the backticked
    /// text after `verify never runs`, in order, each once. Read back off a run
    /// record, which carries the summary as prose and nothing more structured.
    package static func commands(inGap summary: String) -> [String] {
        var out: [String] = []
        var rest = Substring(summary)
        while let start = rest.range(of: "verify never runs `") {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "`") else { break }
            let command = normalize(String(rest[..<end]))
            if !command.isEmpty, !out.contains(command) { out.append(command) }
            rest = rest[rest.index(after: end)...]
        }
        return out
    }

    /// `verify` with every command it lacks appended, each re-rooted at the
    /// repo top so a line that ended in `cd Kiteloop && …` does not run the
    /// next command from there. Nil when it already runs them all — the caller
    /// then has nothing to write. `map` supplies the runnable spelling.
    package static func widen(verify: String?, adding commands: [String], map: Map) -> String? {
        let declared = [verify ?? ""]
        let missing = commands.filter { !wasRun($0, in: declared.map(normalize)) }
        guard !missing.isEmpty else { return nil }
        let tail = missing.map { command in
            let rule = map.rules.first { normalize($0.command) == normalize(command) }
            return "cd \"$(git rev-parse --show-toplevel)\" && " + (rule?.runnable ?? command)
        }.joined(separator: " && ")
        let base = (verify ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? tail : base + " && " + tail
    }

    // MARK: - The verdict

    /// One mapped glob the diff touched whose command the item never declared.
    package struct Gap: Equatable, Sendable {
        package let glob: String
        /// The command that was missing — what someone has to add to the item's
        /// `verify:` (or explain the absence of).
        package let command: String
        /// The changed files that matched, in diff order. Every one of them:
        /// truncation is the reporting layer's job, not the verdict's.
        package let paths: [String]
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(glob: String, command: String, paths: [String]) {
            self.glob = glob
            self.command = command
            self.paths = paths
        }
    }

    /// What the check found. Carries the covered rules too, so "nothing was
    /// flagged" and "nothing was checked" can be told apart afterwards.
    package struct Verdict: Equatable, Sendable {
        package let gaps: [Gap]
        /// Rules whose glob the diff touched and whose command the item ran.
        package let covered: [Rule]

        package var isCovered: Bool { gaps.isEmpty }

        /// The failure, phrased for whoever has to act on it: which files, which
        /// glob, which command. A bare "coverage failed" sends someone reading
        /// code to find out why. Empty when there is no gap.
        package var summary: String {
            gaps.map { gap in
                let shown = gap.paths.prefix(maxPathsInSummary)
                var files = shown.joined(separator: ", ")
                let hidden = gap.paths.count - shown.count
                if hidden > 0 { files += ", +\(hidden) more" }
                let count = gap.paths.count == 1 ? "1 file" : "\(gap.paths.count) files"
                return "diff touches \(gap.glob) (\(count): \(files)) "
                    + "but verify never runs `\(gap.command)`"
            }.joined(separator: "; ")
        }

        package static let covered = Verdict(gaps: [], covered: [])

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(gaps: [Gap], covered: [Rule]) {
            self.gaps = gaps
            self.covered = covered
        }
    }

    /// How many paths a gap names before it says "+N more". Enough to identify
    /// what was changed, short enough for a log line and an item note.
    package static let maxPathsInSummary = 5

    // MARK: - The rules

    /// Judges one run's diff against the project's map.
    ///
    /// - Parameters:
    ///   - changedFiles: repo-relative paths the run changed, as git listed them.
    ///   - ranCommands: the commands the item declared as its `verify:` — the
    ///     groomed detail's, else the item line's. A rule counts as run when its
    ///     command appears in one of them (whitespace-normalized substring):
    ///     verify commands are routinely chained (`a && b`) or prefixed with a
    ///     `cd`, and a rule naming `cargo check` should be satisfied by both.
    ///   - map: the project's rules. Empty → `.covered`, always.
    package static func evaluate(changedFiles: [String], ranCommands: [String], map: Map) -> Verdict {
        guard !map.isEmpty else { return .covered }
        let paths = changedFiles.map(normalizePath).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return .covered }
        let ran = ranCommands.map(normalize).filter { !$0.isEmpty }

        var gaps: [Gap] = []
        var covered: [Rule] = []
        for rule in map.rules {
            let matched = paths.filter { matches(glob: rule.glob, path: $0) }
            guard !matched.isEmpty else { continue }
            if wasRun(rule.command, in: ran) {
                covered.append(rule)
            } else {
                gaps.append(Gap(glob: rule.glob, command: rule.command, paths: matched))
            }
        }
        return Verdict(gaps: gaps, covered: covered)
    }

    /// Whether `command` is part of what the item declared it would run.
    package static func wasRun(_ command: String, in ranCommands: [String]) -> Bool {
        let needle = normalize(command)
        guard !needle.isEmpty else { return true }
        return ranCommands.contains { $0.contains(needle) }
    }

    /// Glob matching over repo-relative paths. `**` spans path separators, `*`
    /// and `?` do not; everything else is literal. Anchored at both ends — a
    /// rule for `apps/api/**` must not silently match `vendor/apps/api/x`.
    package static func matches(glob: String, path: String) -> Bool {
        let pattern = "^" + regexBody(forGlob: normalize(glob)) + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    /// Whether `rule`'s glob matches every path, wherever a file lives —
    /// proven by matching it against a path built from nothing this repo
    /// actually contains: no real directory, no real literal filename. The
    /// probe keeps the glob's own trailing literal (the text after its last
    /// `*`, e.g. `.swift`) so an extension-scoped rule like `**/*.swift` is
    /// still recognised as unconditional; a directory-scoped rule such as
    /// `Kiteloop/KiteloopTests/**` never matches a path that does not start
    /// with its literal prefix, however the probe is built.
    ///
    /// What a grooming pass may widen a drafted `verify:` with: a draft names
    /// no files yet, so nothing says a directory-scoped rule's directory is
    /// where its work will land — only a rule that applies everywhere can be
    /// added before the diff exists.
    package static func isUnconditional(_ rule: Rule) -> Bool {
        let suffix = rule.glob.lastIndex(of: "*").map { String(rule.glob[rule.glob.index(after: $0)...]) } ?? ""
        let probe = "zz-arbitrary-probe-3f1c9a2e/nested/zz-arbitrary-probe-3f1c9a2e" + suffix
        return matches(glob: rule.glob, path: probe)
    }

    // MARK: - Internals

    /// Translates a glob to a regex body.
    ///
    /// `**/` swallows the separator as well (`apps/**/x.swift` matches
    /// `apps/x.swift`), and a trailing `**` matches the rest of the path
    /// including none of it — so `apps/api/**` covers `apps/api/Cargo.toml` and
    /// `apps/api/src/lib.rs` alike, which is how everyone writes such a rule.
    private static func regexBody(forGlob glob: String) -> String {
        var out = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // A trailing `/**` is the whole token: the subtree *and* the
            // directory itself, so the separator can't be emitted on its own.
            if c == "/", i + 3 == chars.count, chars[i + 1] == "*", chars[i + 2] == "*" {
                out += "(?:/.*)?"
                break
            }
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                if i + 2 < chars.count, chars[i + 2] == "/" {
                    out += "(?:.*/)?"      // `**/` — any number of segments, or none
                    i += 3
                } else {
                    out += ".*"
                    i += 2
                }
                continue
            }
            switch c {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return out
    }

    /// Repo-relative, separator-normalized. Git prints `apps/api/src/lib.rs`;
    /// a hand-written path may carry a `./` or a leading slash, and neither
    /// changes which file is meant.
    private static func normalizePath(_ path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("./") { text.removeFirst(2) }
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }

    /// Collapses whitespace runs so a command written across two lines and the
    /// same command on one line compare equal.
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
