import Foundation
import os.log

private let backlogLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog")

package struct RegistryEntry {
    package let name: String
    package let backlogPath: String
    package let repo: String?
    package let aliases: [String]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(name: String, backlogPath: String, repo: String?, aliases: [String]) {
        self.name = name
        self.backlogPath = backlogPath
        self.repo = repo
        self.aliases = aliases
    }
}

package struct BacklogParser {

    package static func findBacklogPath(vaultURL: URL, repoPath: String) -> URL? {
        let projectsURL = vaultURL.appending(path: "Projects")
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            backlogLog.error("Cannot read Projects/ in vault at \(projectsURL.path())")
            return nil
        }

        let normalized = (repoPath as NSString).standardizingPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Strategy 0: Check registry.yaml for repo → project mapping
        let registryURL = vaultURL.appending(path: "Logs/registry.yaml")
        if let registryData = try? Data(contentsOf: registryURL) {
            let entries = parseRegistry(String(decoding: registryData, as: UTF8.self))
            for entry in entries {
                if let repo = entry.repo {
                    let repoNorm = (repo as NSString).standardizingPath
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if repoNorm == normalized || normalized.hasSuffix(URL(fileURLWithPath: repoNorm).lastPathComponent) {
                        if !entry.backlogPath.isEmpty {
                            let backlogURL = vaultURL.appending(path: entry.backlogPath)
                            if fm.fileExists(atPath: backlogURL.path()) {
                                return backlogURL
                            }
                        }
                    }
                }
                // Also check aliases
                for alias in entry.aliases {
                    let aliasNorm = alias.lowercased()
                    let repoLast = URL(fileURLWithPath: repoPath).lastPathComponent.lowercased()
                    if aliasNorm == repoLast {
                        if !entry.backlogPath.isEmpty {
                            let backlogURL = vaultURL.appending(path: entry.backlogPath)
                            if fm.fileExists(atPath: backlogURL.path()) {
                                return backlogURL
                            }
                        }
                    }
                }
            }
        }

        // Check each Projects/<name>/Backlog.md for a repo: frontmatter match, decoded lossily: one bad byte must not hide it
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let backlogURL = folder.appending(path: "Backlog.md")
            guard fm.fileExists(atPath: backlogURL.path()),
                  let content = (try? Data(contentsOf: backlogURL)).map({ String(decoding: $0, as: UTF8.self) }) else { continue }

            if let repo = extractFrontmatterField(content, field: "repo") {
                let repoNorm = (repo as NSString).standardizingPath
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if repoNorm == normalized || normalized.hasPrefix(repoNorm) || repoNorm.hasPrefix(normalized) {
                    return backlogURL
                }
            }
        }

        // Fallback: fuzzy match folder name against repo path
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent.lowercased()
        let repoSlug = repoName.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = folder.lastPathComponent.lowercased()
            let folderSlug = folderName.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
            if folderName == repoName || repoSlug.contains(folderSlug) || folderSlug.contains(repoSlug) {
                let backlogURL = folder.appending(path: "Backlog.md")
                if fm.fileExists(atPath: backlogURL.path()) {
                    return backlogURL
                }
            }
        }

        backlogLog.info("No backlog found for repo: \(repoPath) in vault Projects/")
        return nil
    }

    private static func extractFrontmatterField(_ content: String, field: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        var inFrontmatter = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inFrontmatter { return nil }
                inFrontmatter = true
                continue
            }
            guard inFrontmatter else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces) == field {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    package static func parseRegistry(_ yaml: String) -> [RegistryEntry] {
        var entries: [RegistryEntry] = []
        let lines = yaml.components(separatedBy: .newlines)

        var currentKey: String?
        var currentName: String?
        var currentBacklog: String?
        var currentRepo: String?
        var currentAliases: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            if indent == 2 && trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                if let key = currentKey {
                    entries.append(RegistryEntry(
                        name: currentName ?? key,
                        backlogPath: currentBacklog ?? "",
                        repo: currentRepo,
                        aliases: currentAliases
                    ))
                }
                currentKey = String(trimmed.dropLast())
                currentName = nil
                currentBacklog = nil
                currentRepo = nil
                currentAliases = []
            } else if indent >= 4 {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let field = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)

                switch field {
                case "name": currentName = value
                case "backlog": currentBacklog = value
                case "repo": currentRepo = value
                case "aliases":
                    currentAliases = value
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                default: break
                }
            }
        }

        if let key = currentKey {
            entries.append(RegistryEntry(
                name: currentName ?? key,
                backlogPath: currentBacklog ?? "",
                repo: currentRepo,
                aliases: currentAliases
            ))
        }

        return entries
    }

    /// A parsed backlog plus the lines the parser had to reject. Callers that
    /// only need the content use `parse`; the panel uses this so malformed
    /// lines reach the user instead of disappearing.
    package struct Result: Sendable {
        package var file: BacklogFile
        package var issues: [BacklogParseIssue]
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(file: BacklogFile, issues: [BacklogParseIssue]) {
            self.file = file
            self.issues = issues
        }
    }

    package static func parse(_ content: String) -> BacklogFile {
        parseWithIssues(content).file
    }

    package static func parseWithIssues(_ content: String) -> Result {
        let lines = content.components(separatedBy: .newlines)
        var project = ""
        var repo: String?
        var verifyDefault: String?
        // Frontmatter keys none of the three above — carried into the file so
        // the write-back stops deleting them.
        var unrecognisedFrontmatterLines: [String] = []
        // Lines between the closing frontmatter marker and the first epic
        // heading — an introduction, a link block, and usually the file's own
        // H1. Carried for the same reason as the frontmatter lines above: none
        // of this belongs to any section, so it used to be dropped on the floor
        // rather than deleted from one.
        var preambleLines: [String] = []
        var sections: [BacklogSection] = []
        var currentSection: String?
        var currentItems: [BacklogItem] = []
        var currentDescriptionLines: [String] = []
        // Lines this section had that no item could be made of. Reported as
        // issues *and* carried into the section, so the next write-back puts
        // them back rather than deleting the work they describe.
        var currentUnparsedLines: [String] = []
        // Prose this section had once its first item had appeared — a note
        // between two items, a caveat after the last one. Not an issue: nothing
        // was refused, and it is carried for the same reason the refused lines
        // are, so the write-back stops deleting it.
        var currentTrailingLines: [String] = []
        var inFrontmatter = false
        var frontmatterDone = false
        var issues: [BacklogParseIssue] = []
        // id → line it first appeared on; ids are the key every lookup and
        // agent hand-off uses, so a repeat makes one of the two unreachable.
        var idLines: [String: Int] = [:]

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "---" {
                if !frontmatterDone {
                    if inFrontmatter {
                        frontmatterDone = true
                        inFrontmatter = false
                    } else {
                        inFrontmatter = true
                    }
                }
                continue
            }

            if inFrontmatter {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "project": project = val
                case "repo": repo = val
                case "verify_default": verifyDefault = val
                // A key the app has no use for — kept as written so the next
                // write-back puts it back rather than deleting it. It is the
                // user's metadata, not a typo, so nothing is reported.
                default: unrecognisedFrontmatterLines.append(trimmed)
                }
                continue
            }

            if trimmed.hasPrefix("## ") {
                if let section = currentSection {
                    sections.append(BacklogSection(
                        name: section,
                        description: joinedDescription(currentDescriptionLines),
                        items: currentItems,
                        unparsedLines: currentUnparsedLines,
                        trailingLines: currentTrailingLines
                    ))
                }
                currentSection = String(trimmed.dropFirst(3))
                    .replacingOccurrences(of: "Epic: ", with: "")
                currentItems = []
                currentDescriptionLines = []
                // Anything unparsed above the first heading belongs to no
                // section, so it is dropped here rather than adopted by the one
                // that follows.
                currentUnparsedLines = []
                currentTrailingLines = []
                continue
            }

            if trimmed.hasPrefix("- [") {
                guard let parsed = parseItemLineWithUnrecognisedFields(trimmed, verifyDefault: nil) else {
                    issues.append(BacklogParseIssue(
                        line: lineNumber,
                        text: trimmed,
                        reason: malformedItemReason(trimmed)
                    ))
                    currentUnparsedLines.append(trimmed)
                    continue
                }
                let item = parsed.item
                if !parsed.unrecognised.isEmpty {
                    issues.append(BacklogParseIssue(
                        line: lineNumber,
                        text: trimmed,
                        reason: droppedFieldsReason(parsed.unrecognised, hasVerifyField: parsed.hasVerifyField)
                    ))
                }
                if !parsed.unreadable.isEmpty {
                    issues.append(BacklogParseIssue(
                        line: lineNumber,
                        text: trimmed,
                        reason: unreadableValuesReason(parsed.unreadable)
                    ))
                }
                if currentSection == nil {
                    issues.append(BacklogParseIssue(
                        line: lineNumber,
                        text: trimmed,
                        reason: "`\(item.id)` sits above the first `## ` heading — it isn't part of any epic and won't be kept."
                    ))
                }
                if let first = idLines[item.id] {
                    issues.append(BacklogParseIssue(
                        line: lineNumber,
                        text: trimmed,
                        reason: "Duplicate id `\(item.id)` — already used on line \(first). Edits and runs may hit the wrong item."
                    ))
                } else {
                    idLines[item.id] = lineNumber
                }
                currentItems.append(item)
                continue
            }

            // A non-item, non-heading line under an epic heading — captured as
            // the epic's description while no items have appeared yet, and as a
            // trailing line once one has. Either way it is kept: this branch used
            // to be where a note between two items went to be forgotten, so the
            // first status flip after it was typed deleted it.
            //
            // Before the first heading there is no section to attach to at all —
            // that is the preamble, kept in its own bucket for the same reason.
            if !trimmed.isEmpty {
                if currentSection != nil {
                    if currentItems.isEmpty {
                        currentDescriptionLines.append(trimmed)
                    } else {
                        currentTrailingLines.append(trimmed)
                    }
                } else {
                    preambleLines.append(trimmed)
                }
            }
        }

        if let section = currentSection {
            sections.append(BacklogSection(
                name: section,
                description: joinedDescription(currentDescriptionLines),
                items: currentItems,
                unparsedLines: currentUnparsedLines,
                trailingLines: currentTrailingLines
            ))
        }

        return Result(
            file: BacklogFile(project: project, repo: repo, verifyDefault: verifyDefault,
                              sections: sections,
                              unrecognisedFrontmatterLines: unrecognisedFrontmatterLines,
                              preambleLines: preambleLines),
            issues: issues
        )
    }

    /// Why a `- [`-looking line didn't parse, in terms of what to type instead.
    private static func malformedItemReason(_ line: String) -> String {
        let markerPattern = /^- \[(.?)\]/
        guard let match = line.firstMatch(of: markerPattern) else {
            return "Not an item — expected `- [ ] id | title`."
        }
        let marker = String(match.1)
        guard marker == " " || marker == "x" else {
            return "Unrecognized checkbox `[\(marker)]` — use `[ ]` or `[x]`."
        }
        return "Empty item — expected `- [ ] id | title`."
    }

    /// Why fields that matched no branch of `parseItemLine` were dropped, in
    /// terms of what to type instead.
    ///
    /// When the line carries a `verify:`, the overwhelmingly likely cause is the
    /// one `CLAUDE.md` warns about and `DefinitionOfReady.verifySeparator`
    /// refuses at grooming: a pipe written with spaces around it *is* the field
    /// separator, so the command was truncated there and its tail arrived here.
    /// That fix is named on the spot, so nobody has to go and read `CLAUDE.md`
    /// to understand a line they are looking at.
    private static func droppedFieldsReason(_ fields: [String], hasVerifyField: Bool) -> String {
        let named = fields.map { "`\($0)`" }.joined(separator: ", ")
        let noun = fields.count == 1 ? "field" : "fields"
        let head = "Unrecognised \(noun) \(named) — dropped, so \(fields.count == 1 ? "it has" : "they have") no effect. "
        if hasVerifyField {
            return head
                + "A `verify:` whose pipe is written with spaces splits on the field separator \" | \" — "
                + "write the pipe unspaced (`a|b`) to keep the whole command."
        }
        return head
            + "Fields are separated by \" | \"; the ones a line can carry are "
            + "`verify:`, `size:`, `needs:`, `from:`, a status, `3q`, `$0.42`, a date and `team`."
    }

    /// Why a field the parser recognised was left unset, in terms of what to
    /// type instead.
    ///
    /// This is a different failure from `droppedFieldsReason`: the field was
    /// claimed — `size:`, `$`, a trailing `q` — and only its value could not be
    /// converted, so naming the fields a line can carry would answer a question
    /// nobody asked. What is needed is the shape of the value, so each kind
    /// carries its own. `size:` is the expensive one: an unreadable value leaves
    /// `DefinitionOfReady.effectiveSize` with no size and the item is skipped at
    /// pickup for "no size set", on a line that visibly reads `size:Small`.
    private static func unreadableValuesReason(_ values: [UnreadableValue]) -> String {
        let named = values.map { "`\($0.field)`" }.joined(separator: ", ")
        let one = values.count == 1
        // One expectation per kind, in the order the fields were written: two
        // unreadable sizes on a line do not need telling twice.
        var expectations: [String] = []
        for value in values where !expectations.contains(value.kind.expectation) {
            expectations.append(value.kind.expectation)
        }
        return "Unreadable \(one ? "value" : "values") \(named) — the \(one ? "field is" : "fields are") "
            + "recognised but \(one ? "its value is not" : "their values are not"), so "
            + "\(one ? "it was" : "they were") left unset. "
            + expectations.joined(separator: " ")
    }

    private static func joinedDescription(_ lines: [String]) -> String? {
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    package static func parseItemLine(_ line: String, verifyDefault: String?) -> BacklogItem? {
        parseItemLineWithUnrecognisedFields(line, verifyDefault: verifyDefault)?.item
    }

    /// A parsed item plus the fields on its line that matched nothing the parser
    /// knows how to read.
    ///
    /// Dropping them silently is how a truncated `verify:` disappears: the tail
    /// of a spaced-pipe command arrives here as a field nothing recognises, and
    /// until `parseWithIssues` reported it, no surface anywhere said so. The
    /// item is still returned — this reports, it does not reject.
    package struct ItemLine {
        package var item: BacklogItem
        /// Fields dropped, trimmed, in the order they were written.
        package var unrecognised: [String]
        /// Fields claimed by a branch that could not read the value written,
        /// in the order they were written.
        package var unreadable: [UnreadableValue] = []
        /// Whether the line carried a `verify:` at all, which is what makes the
        /// spaced-pipe explanation the right one to offer.
        package var hasVerifyField: Bool
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(item: BacklogItem, unrecognised: [String], unreadable: [UnreadableValue] = [], hasVerifyField: Bool) {
            self.item = item
            self.unrecognised = unrecognised
            self.unreadable = unreadable
            self.hasVerifyField = hasVerifyField
        }
    }

    /// A field the parser recognised and then could not convert — `size:Small`,
    /// `$1,20`, `abcq`.
    ///
    /// These sit beside `unrecognised` rather than in it because the cause and
    /// the fix are different: the field was claimed, so nothing was dropped;
    /// only its value was, and it is left unset rather than guessed at. The item
    /// still parses and still appears — this reports, it does not reject.
    package struct UnreadableValue: Equatable {
        /// The field as it was written, trimmed.
        package var field: String
        /// Which field it is, which decides what a readable value looks like.
        package var kind: Kind

        package enum Kind: Equatable {
            case size
            case lane
            case flow
            case cost
            case queries

            /// What a value this field can read looks like.
            package var expectation: String {
                switch self {
                case .size: return "A size is written `XS`, `S`, `M`, `L` or `XL`."
                case .lane: return "The only lane a line writes is `lane:now`; leave it off for later."
                case .flow: return "The only flow a line writes is `flow:qa`; leave it off for the standard run."
                case .cost: return "A cost is written `$3.50` — digits and a dot, no thousands separator."
                case .queries: return "A query count is written `12q` — whole digits before the `q`."
                }
            }
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(field: String, kind: Kind) {
            self.field = field
            self.kind = kind
        }
    }

    /// The accumulators the field loop in `parseItemLineWithUnrecognisedFields`
    /// writes, lifted out of that function so each field group is its own small
    /// method instead of one branch of a single long chain.
    private struct ItemLineFields {
        var verify: String?
        var status: BacklogItemStatus
        var size: ItemSize?
        var lane: BacklogLane = .later
        var flow: BacklogFlow = .standard
        var queries: Int?
        var cost: Double?
        var completedDate: String?
        var team: String?
        var blockedReason: String?
        var from: String?
        var needs: [String] = []
        var touches: [String] = []
        var unrecognised: [String] = []
        var unreadable: [UnreadableValue] = []
        var hasVerifyField = false
        private let isDone: Bool

        init(isDone: Bool) {
            self.isDone = isDone
            self.status = isDone ? .done : .ready
        }

        /// A field whose branch claimed it and then could not read the value.
        /// An empty value is not one of these: nothing was written to read, the
        /// same reading the empty-field skip in the caller's loop takes, and a
        /// bare `size:` is visibly unset on the line in a way `size:Small` is
        /// not.
        private mutating func noteUnreadable(_ field: String, _ written: String, _ kind: UnreadableValue.Kind) {
            guard !written.isEmpty else { return }
            unreadable.append(UnreadableValue(field: field, kind: kind))
        }

        /// One non-empty, trimmed field from the line. Dispatches to a group of
        /// small methods, each owning the one field (or field family) it reads.
        mutating func apply(_ trimmed: String) {
            if applyPrefixedField(trimmed) { return }
            if applyBareField(trimmed) { return }
            if BacklogItemStatus(rawValue: trimmed) == nil {
                // Everything above declined it. Only reachable for a status word
                // on a `[x]` line — the checkbox already said done, so the status
                // branch skipped it — which is redundant, not unrecognised.
                unrecognised.append(trimmed)
            }
        }

        /// The fields that name themselves with a `prefix:` (or, for `blocked`,
        /// a bare prefix). Returns whether one claimed the field.
        private mutating func applyPrefixedField(_ trimmed: String) -> Bool {
            if applyRunField(trimmed) { return true }
            if trimmed.hasPrefix("verify:") {
                applyVerify(trimmed)
            } else if trimmed.hasPrefix("size:") {
                applySize(trimmed)
            } else if trimmed.hasPrefix("from:") {
                applyFrom(trimmed)
            } else if trimmed.hasPrefix("needs:") {
                applyNeeds(trimmed)
            } else if trimmed.hasPrefix("touches:") {
                applyTouches(trimmed)
            } else if trimmed.hasPrefix("blocked") {
                applyBlocked(trimmed)
            } else {
                return false
            }
            return true
        }

        /// The fields recognised by their own shape rather than a `prefix:` —
        /// a status word, `team`, a query count, a cost or a completed date.
        /// Returns whether one claimed the field.
        private mutating func applyBareField(_ trimmed: String) -> Bool {
            if let parsed = BacklogItemStatus(rawValue: trimmed), !isDone {
                status = parsed
            } else if trimmed == "team" {
                team = "team"
            } else if trimmed.hasSuffix("q") {
                applyQueries(trimmed)
            } else if trimmed.hasPrefix("$") {
                applyCost(trimmed)
            } else if trimmed.contains("-") && trimmed.count <= 10 {
                completedDate = trimmed
            } else {
                return false
            }
            return true
        }

        private mutating func applyVerify(_ trimmed: String) {
            hasVerifyField = true
            // A shell pipe inside a verify must be written **without spaces
            // around it** — `a --json|python3 -c '…'`. The fields were split
            // on `" | "` above, so a spaced pipe is that separator: the
            // command is truncated at it and the rest of it arrives here as a
            // field no branch below claims — so the item would run a shorter
            // command than its author wrote. That tail is collected into
            // `unrecognised` and reported by `parseWithIssues`; it used to be
            // dropped with no error and no warning, which is how the
            // truncation went unnoticed. Changing the separator is not on:
            // every backlog in every project uses it, and unspaced is
            // expressible.
            verify = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }

        private mutating func applySize(_ trimmed: String) {
            // `SMALL` is not `S`: an unreadable size is reported and left
            // unset, never mapped onto the nearest thing it resembles.
            let written = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            size = ItemSize(rawValue: written.uppercased())
            if size == nil { noteUnreadable(trimmed, written, .size) }
        }

        /// The two fields that say how the item runs rather than what it is —
        /// its lane and its flow. Returns whether one claimed the field.
        private mutating func applyRunField(_ trimmed: String) -> Bool {
            if trimmed.hasPrefix("lane:") { applyLane(trimmed); return true }
            if trimmed.hasPrefix("flow:") { applyFlow(trimmed); return true }
            return false
        }

        private mutating func applyLane(_ trimmed: String) {
            // `now` is the only lane a line writes: `later` is the default and
            // is left off, so anything else here — `lane:soon`, `lane:urgent`,
            // even `lane:later` — is a lane this format does not have. It is
            // reported and left at `later` rather than guessed at, exactly as an
            // unreadable `size:` is.
            let written = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard written.lowercased() == BacklogLane.now.rawValue else {
                noteUnreadable(trimmed, written, .lane)
                return
            }
            lane = .now
        }

        private mutating func applyFlow(_ trimmed: String) {
            // `qa` is the only flow a line writes, as `now` is the only lane:
            // anything else is reported and left at `standard`, never guessed at.
            let written = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard written.lowercased() == BacklogFlow.qa.rawValue else {
                noteUnreadable(trimmed, written, .flow)
                return
            }
            flow = .qa
        }

        private mutating func applyFrom(_ trimmed: String) {
            // Provenance, not a dependency: nothing downstream checks that the
            // id still exists, so an unknown parent is carried through as
            // written rather than dropped.
            let parent = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            from = parent.isEmpty ? nil : parent
        }

        private mutating func applyNeeds(_ trimmed: String) {
            // Unknown ids parse fine. Whether the id names anything is a
            // readiness question, answered against the whole file by
            // `DefinitionOfReady.Dependencies`; refusing the line here would
            // turn a typo into a vanished item instead of a reported one.
            needs = String(trimmed.dropFirst(6))
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        private mutating func applyTouches(_ trimmed: String) {
            // Parsed exactly like `needs:`. Whether the path it names exists
            // is not this line's question; no run is gated on it since the
            // protected-paths setting was retired.
            touches = String(trimmed.dropFirst(8))
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        private mutating func applyBlocked(_ trimmed: String) {
            status = .blocked
            if trimmed.contains(":") {
                blockedReason = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        private mutating func applyQueries(_ trimmed: String) {
            let written = String(trimmed.dropLast())
            queries = Int(written)
            if queries == nil { noteUnreadable(trimmed, written, .queries) }
        }

        private mutating func applyCost(_ trimmed: String) {
            let written = String(trimmed.dropFirst())
            cost = Double(written)
            if cost == nil { noteUnreadable(trimmed, written, .cost) }
        }
    }

    package static func parseItemLineWithUnrecognisedFields(_ line: String, verifyDefault: String?) -> ItemLine? {
        let checkboxPattern = /^- \[([ x])\] (.+)$/
        guard let match = line.wholeMatch(of: checkboxPattern) else { return nil }

        let isDone = match.1 == "x"
        var rest = String(match.2)

        // Extract → [detail](path) link if present
        var detailPath: String?
        let detailPattern = /→ \[detail\]\((.+?)\)\s*$/
        if let detailMatch = rest.firstMatch(of: detailPattern) {
            detailPath = String(detailMatch.1)
            rest = String(rest[rest.startIndex..<detailMatch.range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }

        let parts = rest.components(separatedBy: " | ")
        guard !parts.isEmpty else { return nil }

        let idPart = parts[0].trimmingCharacters(in: .whitespaces)
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        var type: BacklogItemType = .local
        var jiraKey: String?
        var id = idPart

        // Jira items are either explicit ("JIRA:ABC-123") or match the
        // canonical key shape: uppercase project code, dash, number.
        // Anything else — including uppercase-ish local ids — stays local.
        let jiraKeyPattern = /^[A-Z][A-Z0-9]+-\d+$/
        if idPart.hasPrefix("JIRA:") {
            jiraKey = String(idPart.dropFirst(5))
            id = jiraKey ?? idPart
            type = .jira
        } else if idPart.wholeMatch(of: jiraKeyPattern) != nil {
            jiraKey = idPart
            type = .jira
        }

        var fields = ItemLineFields(isDone: isDone)
        for part in parts.dropFirst(2) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // `a | | b` and a trailing separator: nothing was written, so
                // there is nothing to report as dropped.
                continue
            }
            fields.apply(trimmed)
        }

        return makeItemLine(
            id: id, title: title, type: type, jiraKey: jiraKey, detailPath: detailPath,
            line: line, fields: fields, verifyDefault: verifyDefault
        )
    }

    private static func makeItemLine(
        id: String, title: String, type: BacklogItemType, jiraKey: String?, detailPath: String?,
        line: String, fields: ItemLineFields, verifyDefault: String?
    ) -> ItemLine {
        let item = BacklogItem(
            id: id,
            title: title,
            verify: fields.verify ?? verifyDefault,
            status: fields.status,
            type: type,
            size: fields.size,
            lane: fields.lane,
            flow: fields.flow,
            queries: fields.queries,
            cost: fields.cost,
            completedDate: fields.completedDate,
            blockedReason: fields.blockedReason,
            jiraKey: jiraKey,
            team: fields.team,
            detailPath: detailPath,
            from: fields.from,
            needs: fields.needs,
            touches: fields.touches,
            // Carried, not read: the item behaves exactly as it would without
            // them, and the only thing that looks at them is the serializer,
            // which writes them back so a status flip stops deleting the text
            // the parse issue is about.
            unrecognisedFields: fields.unrecognised
        )
        // The line as written, kept so `BacklogSerializer.serializeItem` has
        // something known-good to fall back to if a later edit makes this item
        // unable to round-trip — see its `reconciled(_:for:)`.
        var itemWithSource = item
        itemWithSource.sourceLine = line
        return ItemLine(
            item: itemWithSource,
            unrecognised: fields.unrecognised,
            unreadable: fields.unreadable,
            hasVerifyField: fields.hasVerifyField
        )
    }

    // MARK: - Tier-2 Detail Parser

    package static func parseDetail(at url: URL) -> BacklogItemDetail? {
        // Decoded lossily: one bad byte must not make a groomed file read as missing.
        guard let data = try? Data(contentsOf: url) else { return nil }
        let content = String(decoding: data, as: UTF8.self)
        // A file named <id>.md identifies itself; frontmatter is not the only
        // way to know which item it belongs to.
        return parseDetail(content, fallbackID: url.deletingPathExtension().lastPathComponent)
    }

    /// Parses a groomed detail file.
    ///
    /// Frontmatter is optional. Every one of the 40 hand-written detail files in
    /// use had none, and requiring it made `DefinitionOfReady` treat them all as
    /// missing — which blocked every item in every project at pickup. A file
    /// that is just `## What` / `## How` / `## Validation` is a groomed item;
    /// the frontmatter carries extras, not the substance.
    package static func parseDetail(_ content: String, fallbackID: String? = nil) -> BacklogItemDetail? {
        let lines = content.components(separatedBy: .newlines)
        let hasFrontmatter = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) == "---"
        var inFrontmatter = false
        var frontmatterDone = !hasFrontmatter
        var frontmatterLines: [String] = []
        var bodyLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !frontmatterDone {
                    if inFrontmatter { frontmatterDone = true; inFrontmatter = false }
                    else { inFrontmatter = true }
                } else {
                    bodyLines.append(line)
                }
                continue
            }
            if inFrontmatter { frontmatterLines.append(line) }
            else if frontmatterDone { bodyLines.append(line) }
        }

        // Parse frontmatter
        var id = "", title = "", status: String?, epic: String?, priority: String?
        var size: String?, owner: String?, jira: String?, repo: String?
        var verifyCommands: [BacklogItemDetail.VerifyCommand] = []
        var inVerify = false
        var currentVerifyName: String?
        var currentVerifyCmd: String?
        var currentVerifyExpect: String?

        for line in frontmatterLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name:") && inVerify {
                if let name = currentVerifyName, let cmd = currentVerifyCmd {
                    verifyCommands.append(.init(name: name, cmd: cmd, expect: currentVerifyExpect))
                }
                currentVerifyName = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                currentVerifyCmd = nil
                currentVerifyExpect = nil
                continue
            }
            if inVerify && trimmed.hasPrefix("cmd:") {
                currentVerifyCmd = Self.doubleQuotedScalar(String(trimmed.dropFirst(4)))
                continue
            }
            if inVerify && trimmed.hasPrefix("expect:") {
                currentVerifyExpect = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // `omittingEmptySubsequences: false` so a key whose value is empty
            // still parses. `verify:` opens a block and has nothing after the
            // colon, so the default splitting returned a single element, the
            // guard bailed, and `inVerify` never became true — every frontmatter
            // verify block was silently dropped, leaving the item with no verify
            // command and so failing the Definition-of-Ready that requires one.
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "verify" {
                inVerify = true
                continue
            }
            inVerify = false

            switch key {
            case "id": id = val
            case "title": title = val
            case "status": status = val
            case "epic": epic = val
            case "priority": priority = val
            case "size": size = val
            case "owner": owner = val
            case "jira": jira = val == "null" ? nil : val
            case "repo": repo = val
            default: break
            }
        }
        if let name = currentVerifyName, let cmd = currentVerifyCmd {
            verifyCommands.append(.init(name: name, cmd: cmd, expect: currentVerifyExpect))
        }

        if id.isEmpty, let fallbackID { id = fallbackID }
        guard !id.isEmpty else { return nil }

        // Parse body sections
        var why: String?
        var acceptanceCriteria: [String] = []
        var outOfScope: [String] = []
        var context: String?
        var notes: String?
        var what: String?
        var approach: String?
        var premise: [String] = []

        var currentSection: String?
        var sectionContent: [String] = []

        func flushSection() {
            guard let sec = currentSection else { return }
            let text = sectionContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            switch sec {
            case "What": what = text
            case "How", "Approach": approach = text
            case "Why": why = text
            case "Acceptance Criteria", "Validation":
                // Any `- ` bullet is a criterion, not only a `- [ ]` checkbox.
                // The app's writers all scaffold checkboxes, but a hand-groomed
                // file that lists its criteria as ordinary bullets used to parse
                // as none at all — and `DefinitionOfReady` then skipped the item
                // for "no Validation criteria" over a file that plainly had
                // them. `## Out of Scope` below has always read plain bullets.
                acceptanceCriteria = sectionContent
                    .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
                    .map { line in
                        let l = line.trimmingCharacters(in: .whitespaces)
                        if l.hasPrefix("- [ ] ") || l.hasPrefix("- [x] ") { return String(l.dropFirst(6)) }
                        // A `- [` that is not one of those two boxes is left as
                        // it was before, box included, rather than half-stripped.
                        if l.hasPrefix("- [") { return l }
                        return String(l.dropFirst(2))
                    }
            case "Out of Scope": outOfScope = plainBullets(sectionContent)
            // One claim per bullet, like Out of Scope; a bare `- ` — what a
            // grooming skeleton stamps for an item that states no premise —
            // reads as no claim rather than an empty one to verify.
            case "Premise": premise = plainBullets(sectionContent).filter { !$0.isEmpty }
            case "Context": context = text
            case "Notes": notes = text
            default: break
            }
        }

        for line in bodyLines {
            if line.hasPrefix("## ") {
                flushSection()
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                sectionContent = []
            } else {
                sectionContent.append(line)
            }
        }
        flushSection()

        return BacklogItemDetail(
            id: id, title: title, status: status, epic: epic,
            priority: priority, size: size, owner: owner, jira: jira, repo: repo,
            verifyCommands: verifyCommands, why: why,
            acceptanceCriteria: acceptanceCriteria, outOfScope: outOfScope,
            context: context, notes: notes,
            what: what, approach: approach,
            premise: premise
        )
    }

    /// The `- ` bullets of a section, marker stripped, in order. Every other
    /// line — prose, a blank, a sub-heading — is not an entry. Shared by the
    /// list sections that read plain bullets, so `## Out of Scope` and
    /// `## Premise` cannot drift apart in what they accept.
    package static func plainBullets(_ lines: [String]) -> [String] {
        lines
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(2)) }
    }

    /// A YAML double-quoted scalar, with its escapes resolved.
    ///
    /// Trimming quote characters off both ends was enough for as long as no
    /// command contained one. A command that quotes an inline script —
    /// `python3 -c "…"` — is written `\"` in the file, and trimming left the
    /// backslashes in place and ate the closing quote, yielding
    /// `python3 -c \"import json; assert x\` — a command no shell runs as
    /// written, and one the grounding check refused because the script's own
    /// words, `assert` and `print('ok`, are not programs on disk.
    ///
    /// An unquoted scalar is returned as-is, which is what every command
    /// written without quotes already relied on.
    package static func doubleQuotedScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        var out = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// The inverse: a string written down as the double-quoted scalar that
    /// `doubleQuotedScalar` reads back as that same string.
    ///
    /// The quotes are part of what this returns, so quoting and escaping stay
    /// one decision. Writing the escaped value into hand-written quotes is how
    /// this went wrong in the first place: `detailMarkdown()` escaped `"` and
    /// nothing else, so `find … -exec … {} \;` was written verbatim and came
    /// back as `find … -exec … {} ;` — the reader ate the backslash, and the
    /// command a run executed was not the command that was groomed. A verify
    /// mentioning a literal `\n` came back with a real newline in it, which the
    /// line-oriented reader then truncated at.
    ///
    /// The backslash has to be escaped before anything else, or the backslash
    /// this adds in front of a quote gets escaped in turn and the reader sees a
    /// literal backslash followed by the quote that ends the scalar. Doing it
    /// character by character — rather than as a sequence of replacements —
    /// makes that ordering impossible to get wrong later.
    /// `content` with one more entry in its frontmatter `verify:` list, named
    /// `verify-map` and running `command` — the detail-file half of widening an
    /// item's verify, since a groomed detail's list is what a run executes and
    /// the line is only read when that list is empty. Nil when the file has no
    /// frontmatter verify list, in which case the line alone is the verify and
    /// the caller has nothing to do here.
    package static func wideningDetailVerify(_ content: String, adding command: String) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let verify = lines[(open + 1)..<close].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "verify:" })
        else { return nil }
        // The list runs until the first frontmatter line that is not one of
        // its own (`- name:`, `cmd:`, `expect:`) — the next key, or the fence.
        var end = verify + 1
        while end < close, Self.isVerifyListLine(lines[end]) { end += 1 }
        guard end > verify + 1 else { return nil }
        let indent = lines[verify + 1].prefix { $0 == " " }
        lines.insert(contentsOf: ["\(indent)- name: verify-map",
                                  "\(indent)  cmd: \(doubleQuotedScalarLiteral(command))"], at: end)
        return lines.joined(separator: "\n")
    }

    private static func isVerifyListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- name:") || trimmed.hasPrefix("cmd:") || trimmed.hasPrefix("expect:")
    }

    package static func doubleQuotedScalarLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init() {
    
    }
}

// MARK: - The shared backlog branch

/// A team's backlog, carried by the project's own git remote on an **orphan
/// branch** — the `gh-pages` pattern applied to work items. The branch holds
/// `BACKLOG.md` + `backlog/` with no code history, the app keeps a private
/// checkout of it under `.kiteloop/backlog-tree/` (never the project's working
/// tree, so the auto-merger's clean-tree gate never sees it), and the remote
/// the team already shares does the sharing: clone the repo, open it in
/// Kiteloop, and the backlog is there. Design: `docs/backlog-branch.md`.
///
/// v1 sync is deliberately modest: commit on every write, fetch + fast-forward
/// on open, push best-effort and rate-limited. A branch that has *diverged*
/// (two machines writing offline) is left for a human — logged, never
/// force-resolved. Semantic merge and a cross-machine claim on items are the
/// documented next steps, not silent behaviors.
package enum BacklogBranch {
    package static let branchName = "kiteloop/backlog"
    package static let checkoutComponent = ".kiteloop/backlog-tree"
    private static let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog-branch")

    /// One queue for every git operation: writes come from detached tasks and
    /// the main actor both, and two `git commit`s racing in one checkout is a
    /// lock error at best.
    private static let queue = DispatchQueue(label: "ai.kasatkin.kiteloop.backlog-branch")
    /// Last push per project root — pushes are rate-limited so a burst of
    /// status flips costs one network round-trip, not one each. Guarded by
    /// `queue`: every read and write happens inside `queue.sync`, which is the
    /// isolation the annotation promises.
    nonisolated(unsafe) private static var lastPush: [String: Date] = [:]
    package static let pushInterval: TimeInterval = 60

    /// Deadlines for the git commands below. Every entry point runs inside
    /// `queue.sync` and `BacklogViewModel` calls three of them from the main
    /// actor, so a command with no time limit is a hung app, not a slow one.
    ///
    /// A command that only touches this machine either finishes at once or is
    /// stuck on a lock; a command that talks to `origin` can legitimately take a
    /// while on a slow link, so it gets the longer of the two.
    package static let commandTimeout: TimeInterval = 30
    package static let networkCommandTimeout: TimeInterval = 120
    /// The subcommands that reach the network, and so take
    /// `networkCommandTimeout`. Read from the command rather than passed at each
    /// call site: a call site can forget, this cannot.
    private static let networkSubcommands: Set<String> = ["fetch", "push", "pull", "clone", "ls-remote"]

    package static func checkoutURL(projectRoot: URL) -> URL {
        projectRoot.appending(path: checkoutComponent, directoryHint: .isDirectory)
    }

    package static func backlogFileURL(projectRoot: URL) -> URL {
        checkoutURL(projectRoot: projectRoot).appending(path: "BACKLOG.md")
    }

    package enum Availability: Equatable {
        /// The private checkout exists and holds a backlog — use it.
        case checkedOut
        /// The branch exists (locally, or as a remote-tracking ref from the
        /// last fetch/clone) but has no checkout yet — adoptable.
        case adoptable
        /// No branch anywhere this machine knows of.
        case absent
    }

    package static func availability(projectRoot: URL) -> Availability {
        queue.sync {
            if FileManager.default.fileExists(atPath: backlogFileURL(projectRoot: projectRoot).path(percentEncoded: false)) {
                return .checkedOut
            }
            // Remote-tracking ref, not `ls-remote`: this must answer offline,
            // from what the clone already knows.
            if git(["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"], cwd: projectRoot).status == 0
                || git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branchName)"], cwd: projectRoot).status == 0 {
                return .adoptable
            }
            return .absent
        }
    }

    /// Materialize the private checkout for a branch that exists. Returns the
    /// backlog file URL on success — the caller watches that file exactly as it
    /// would any other backlog location.
    @discardableResult
    package static func adopt(projectRoot: URL) -> URL? {
        queue.sync {
            let fileURL = backlogFileURL(projectRoot: projectRoot)
            let filePath = fileURL.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: filePath) { return fileURL }
            _ = git(["worktree", "prune"], cwd: projectRoot)
            // A local branch may not exist yet on a fresh clone — create it
            // tracking the remote one before checking it out.
            if git(["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"], cwd: projectRoot).status != 0 {
                let made = git(["branch", "--track", branchName, "origin/\(branchName)"], cwd: projectRoot)
                guard made.status == 0 else {
                    log.error("backlog-branch: no local or remote branch to adopt — \(made.output)")
                    return nil
                }
            }
            let checkout = checkoutURL(projectRoot: projectRoot).path(percentEncoded: false)
            let added = git(["worktree", "add", checkout, branchName], cwd: projectRoot)
            guard added.status == 0 else {
                log.error("backlog-branch: worktree add failed — \(added.output)")
                return nil
            }
            return FileManager.default.fileExists(atPath: filePath) ? fileURL : nil
        }
    }

    /// Create the shared branch from nothing: an orphan branch, a starter
    /// backlog, one commit, and a best-effort push. The project's own working
    /// tree is untouched throughout.
    @discardableResult
    package static func createShared(projectRoot: URL, projectName: String) -> URL? {
        queue.sync {
            let checkout = checkoutURL(projectRoot: projectRoot).path(percentEncoded: false)
            let made = git(["worktree", "add", "--orphan", "-b", branchName, checkout], cwd: projectRoot)
            guard made.status == 0 else {
                log.error("backlog-branch: orphan worktree failed — \(made.output)")
                return nil
            }
            let fileURL = backlogFileURL(projectRoot: projectRoot)
            let starter = """
            # \(projectName) Backlog

            ## Epic: Inbox

            """
            do {
                try starter.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                log.error("backlog-branch: couldn't write starter backlog — \(error.localizedDescription)")
                return nil
            }
            let checkoutURL = URL(fileURLWithPath: checkout, isDirectory: true)
            _ = git(["add", "-A"], cwd: checkoutURL)
            _ = git(["commit", "-m", "kiteloop: shared backlog"], cwd: checkoutURL)
            // Best-effort: a repo with no remote, or no network, still gets a
            // working local branch — the push happens on a later sync.
            _ = git(["push", "-u", "origin", branchName], cwd: checkoutURL)
            return fileURL
        }
    }

    /// Commit whatever the app just wrote, and push if the rate limit allows.
    /// Called after every backlog write on a branch-backed project — cheap when
    /// nothing changed (the status check short-circuits).
    package static func commitChanges(projectRoot: URL, message: String) {
        queue.sync {
            let checkout = checkoutURL(projectRoot: projectRoot)
            let dirty = git(["status", "--porcelain"], cwd: checkout)
            guard dirty.status == 0, !dirty.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = git(["add", "-A"], cwd: checkout)
            let committed = git(["commit", "-m", message], cwd: checkout)
            guard committed.status == 0 else {
                log.error("backlog-branch: commit failed — \(committed.output)")
                return
            }
            let key = projectRoot.path(percentEncoded: false)
            let now = Date()
            if now.timeIntervalSince(lastPush[key] ?? .distantPast) >= pushInterval {
                lastPush[key] = now
                _ = git(["push", "origin", branchName], cwd: checkout)
            }
        }
    }

    /// Fetch, fast-forward, push — each best-effort, none destructive. A
    /// diverged branch (both machines committed) is logged and left: v1 has no
    /// semantic merge, and a wrong automatic resolution of a team's backlog is
    /// strictly worse than a loud manual one.
    package static func sync(projectRoot: URL) {
        queue.sync {
            let checkout = checkoutURL(projectRoot: projectRoot)
            guard FileManager.default.fileExists(atPath: checkout.path(percentEncoded: false)) else { return }
            _ = git(["fetch", "origin", branchName], cwd: checkout)
            let merged = git(["merge", "--ff-only", "origin/\(branchName)"], cwd: checkout)
            if merged.status != 0, !merged.output.contains("not something we can merge") {
                // No remote ref is fine (nothing fetched); a real divergence is
                // the case worth a loud line.
                let diverged = git(["rev-list", "--count", "HEAD..origin/\(branchName)"], cwd: checkout)
                if (Int(diverged.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
                    log.error("""
                        backlog-branch: \(branchName) has diverged from origin — resolve by hand in \
                        \(checkout.path()); the app will keep using the local copy meanwhile
                        """)
                }
            }
            let ahead = git(["rev-list", "--count", "origin/\(branchName)..HEAD"], cwd: checkout)
            if (Int(ahead.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
                lastPush[projectRoot.path(percentEncoded: false)] = Date()
                _ = git(["push", "origin", branchName], cwd: checkout)
            }
        }
    }

    /// Prompt-free, and on a deadline: past it the command is killed — with
    /// anything it forked — and comes back non-zero with output saying it timed
    /// out, so every `status == 0` guard above takes its failure arm and the
    /// `log.error` line beside it names the timeout.
    private static func git(_ args: [String], cwd: URL) -> (status: Int32, output: String) {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        let networked = args.first.map(networkSubcommands.contains) ?? false
        let timeout = networked ? networkCommandTimeout : commandTimeout
        let result = SubprocessOutput.runWithDeadline(
            executable: "/usr/bin/git",
            arguments: args,
            directory: cwd,
            environment: env,
            timeout: timeout
        )
        // Logged here rather than at the call sites: `fetch` and the pushes are
        // best-effort and discard their result, so a stall that used to hang the
        // app for ever would otherwise pass in silence. Only the timeout is
        // logged — an ordinary failure (no remote configured, nothing to push)
        // is normal here and is the call site's to judge.
        if result.timedOut {
            log.error("backlog-branch: git \(args.joined(separator: " ")) timed out after \(Int(timeout))s — killed")
        }
        return (result.status, result.output)
    }
}
