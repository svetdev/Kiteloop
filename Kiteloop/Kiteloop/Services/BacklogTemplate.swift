import Foundation
import KiteloopCore
import os.log

private let templateLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "backlog-template")

/// A recurring multi-item process, written down once.
///
/// Kiteloop's own release checklist is the case that motivated this: `CLAUDE.md`
/// says a ship bumps `MARKETING_VERSION` in three places that must not drift and
/// flips the CHANGELOG heading — a small dependency-ordered graph of work that
/// was re-derived from prose at every release. A template is that graph as a
/// file: the item lines and their groomed detail bodies, in the formats they will
/// be filed in, with `{{variable}}` placeholders where the release differs.
///
/// The point of writing it in the *existing* formats rather than a schema of its
/// own is that a template reads as the backlog fragment it will become, and is
/// read by the very same parsers — `BacklogParser.parseItemLine` for the line,
/// `BacklogParser.parseDetail` for the body. There is no second dialect to keep
/// in step.
///
/// A stamp is all-or-nothing. A variable that fails its constraint, or an id that
/// is already in the backlog, refuses the whole instantiation rather than filing
/// the items that happened to be fine — half a release checklist is worse than
/// none, since the missing half is invisible.
struct BacklogTemplate: Equatable, Sendable {

    /// One value the stamp has to be given, as the header declares it.
    struct Variable: Equatable, Sendable {
        var name: String
        var description: String?
        /// A stamp that omits a required variable is refused. An optional one that
        /// is omitted substitutes to nothing.
        var required: Bool = true
        /// A regular expression the supplied value must match **whole**. Nil
        /// accepts any single-line value. This is what stops `version=next` from
        /// being stamped into three verify commands that then look for a tag
        /// nobody will ever push.
        var pattern: String?
    }

    /// One item the template stamps: its backlog line and its detail body, both
    /// verbatim, both still holding their placeholders.
    struct ItemBlock: Equatable, Sendable {
        /// The `- [ ] id | title | size:… | verify:… | needs:…` line, as written.
        var line: String
        /// Everything after it — `## What` / `## Premise` / `## How` /
        /// `## Validation` / `## Out of Scope`, in detail-file layout.
        var body: String
    }

    /// The file's stem: `templates/<name>.md`.
    var name: String
    var description: String?
    /// The epic stamped items are filed under, when the backlog has one by that
    /// name. Nil files them where any other drafted item goes.
    var epic: String?
    var variables: [Variable]
    var items: [ItemBlock]

    /// The variable by that name, or nil.
    func variable(named name: String) -> Variable? {
        variables.first { $0.name == name }
    }

    // MARK: - Parsing

    /// Reads a template file. `name` is the file's stem, which is the template's
    /// name — a template identifies itself by where it lives, the same way a
    /// `backlog/<id>.md` does.
    static func parse(_ content: String, name: String) throws -> BacklogTemplate {
        let (frontmatter, body) = splitFrontmatter(content)
        var template = try parseHeader(frontmatter, name: name)
        template.items = try parseItemBlocks(body)

        guard !template.items.isEmpty else { throw BacklogTemplateError.noItems }

        // A `{{typo}}` in the body would otherwise survive substitution and be
        // stamped verbatim into a backlog line — refused here, where the fix is
        // one edit to the template, rather than found in the filed item.
        let declared = Set(template.variables.map(\.name))
        for item in template.items {
            for placeholder in placeholders(in: item.line).union(placeholders(in: item.body))
            where !declared.contains(placeholder) {
                throw BacklogTemplateError.undeclaredPlaceholder(placeholder)
            }
        }
        for variable in template.variables {
            guard let pattern = variable.pattern else { continue }
            guard (try? Regex(pattern)) != nil else {
                throw BacklogTemplateError.badPattern(name: variable.name, pattern: pattern)
            }
        }
        return template
    }

    /// Frontmatter (between the opening and closing `---`) and everything after
    /// it. A file with no frontmatter is all body, which then declares no
    /// variables — legitimate for a template with nothing to parameterise.
    private static func splitFrontmatter(_ content: String) -> ([String], [String]) {
        let lines = content.components(separatedBy: .newlines)
        let firstMeaningful = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard firstMeaningful?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([], lines)
        }
        var frontmatter: [String] = []
        var body: [String] = []
        var seenOpen = false
        var done = false
        for line in lines {
            if !done, line.trimmingCharacters(in: .whitespaces) == "---" {
                if seenOpen { done = true } else { seenOpen = true }
                continue
            }
            if done { body.append(line) } else if seenOpen { frontmatter.append(line) }
        }
        return (frontmatter, body)
    }

    /// `name`, `description`, `epic` and the `variables:` list. Written in the
    /// same YAML-lite a detail file's `verify:` block uses, and read the same way
    /// — indentation is not significant, the `- name:` marker opens each entry.
    private static func parseHeader(_ lines: [String], name: String) throws -> BacklogTemplate {
        var template = BacklogTemplate(name: name, variables: [], items: [])
        var inVariables = false
        var current: Variable?

        func flush() throws {
            guard let variable = current else { return }
            guard !variable.name.isEmpty else { throw BacklogTemplateError.unnamedVariable }
            guard template.variable(named: variable.name) == nil else {
                throw BacklogTemplateError.duplicateVariable(variable.name)
            }
            template.variables.append(variable)
            current = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- name:") {
                try flush()
                inVariables = true
                current = Variable(name: String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                continue
            }
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if inVariables, current != nil {
                switch key {
                case "description": current?.description = value.isEmpty ? nil : value
                case "pattern": current?.pattern = value.isEmpty ? nil : value
                case "required": current?.required = value.lowercased() != "false"
                default: break
                }
                continue
            }
            switch key {
            case "variables": inVariables = true
            // No `name:` here on purpose. A template is identified by where it
            // lives, the same way a `backlog/<id>.md` is, and a frontmatter name
            // that disagreed with the file stem would list the template under one
            // name and stamp it under another.
            case "description": template.description = value.isEmpty ? nil : value
            case "epic": template.epic = value.isEmpty ? nil : value
            default: break
            }
        }
        try flush()
        return template
    }

    /// The body, cut at each `## Item` heading. Anything before the first one is
    /// prose about the template and is ignored.
    private static func parseItemBlocks(_ lines: [String]) throws -> [ItemBlock] {
        var blocks: [[String]] = []
        var current: [String]?
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == itemHeading {
                if let current { blocks.append(current) }
                current = []
                continue
            }
            current?.append(line)
        }
        if let current { blocks.append(current) }

        return try blocks.map { block in
            guard let index = block.firstIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }), block[index].trimmingCharacters(in: .whitespaces).hasPrefix("- [") else {
                throw BacklogTemplateError.blockWithoutAnItemLine
            }
            return ItemBlock(line: block[index].trimmingCharacters(in: .whitespaces),
                             body: block[(index + 1)...].joined(separator: "\n"))
        }
    }

    /// What opens an item block. `## Item` rather than the item line itself
    /// because a `## Validation` checkbox is written `- [ ] …` too, and splitting
    /// on that would cut a block in half at its own acceptance criteria.
    static let itemHeading = "## Item"

    // MARK: - Placeholders

    /// Every `{{name}}` in `text`, by name.
    static func placeholders(in text: String) -> Set<String> {
        var found: Set<String> = []
        scan(text) { name, _ in found.insert(name) }
        return found
    }

    /// `text` with each `{{name}}` replaced by `values[name]`. A name with no
    /// value is left as written, so a caller can tell substitution apart from a
    /// value that happened to be empty.
    static func substitute(_ text: String, values: [String: String]) -> String {
        var out = ""
        var consumed = text.startIndex
        scan(text) { name, range in
            out += text[consumed..<range.lowerBound]
            out += values[name] ?? String(text[range])
            consumed = range.upperBound
        }
        out += text[consumed...]
        return out
    }

    /// One pass over `text`, calling `body` with the name and the full `{{…}}`
    /// range of each placeholder. Substituted text is never rescanned — a value
    /// that contains braces cannot become a placeholder of its own.
    private static func scan(_ text: String, _ body: (String, Range<String.Index>) -> Void) {
        var index = text.startIndex
        while let open = text.range(of: "{{", range: index..<text.endIndex) {
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else { return }
            let name = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            body(name, open.lowerBound..<close.upperBound)
            index = close.upperBound
        }
    }

    // MARK: - Stamping

    /// One item this stamp would file, in the shape everything downstream already
    /// speaks: `QueueRefill.Draft` is what the coordinator files, so a stamped
    /// item and a drafted one are written by the same code, judged by the same
    /// gates and land as the same bytes.
    typealias Stamped = QueueRefill.Draft

    /// A stamped item plus what resolving its `needs:` had to say about it —
    /// `QueueRefill.Drafted`, for the same reason `Stamped` is `Draft`.
    typealias Drafted = QueueRefill.Drafted

    /// Substitute, validate, and return the items this template would file.
    ///
    /// Throws — rather than returning what it could — on the first refusal, so
    /// nothing partial can reach a caller that writes. The order matters to the
    /// message a person reads: what they typed is checked before what the
    /// template says, and the backlog is consulted last.
    ///
    /// What comes back is `Drafted` rather than `Stamped` because the `needs:`
    /// ids on a template's item lines are resolved against the backlog before
    /// anything is written, exactly as the coordinator's drafts are — see
    /// `QueueRefill.resolveDependencies`. A template is written once and stamped
    /// for years, so an id it names can be renamed or deleted out from under it,
    /// and an unresolvable one is not a refusal but a permanent withholding: the
    /// pickup gate reads it as `needs <id> — no such item` on every pass, for
    /// ever, and nothing returns the item to the groomer. It is dropped from the
    /// line and said in the item's notes instead.
    ///
    /// - Parameters:
    ///   - values: the variables, by name.
    ///   - existingIDs: every id already in the backlog. A stamped id that
    ///     collides refuses the whole instantiation — which is also the guard
    ///     against filing the same release twice. It is also what a `needs:` id
    ///     has to name, along with the items of this same stamp: they are filed
    ///     together, so a step may wait for one written after it.
    func stamp(values: [String: String], existingIDs: Set<String>) throws -> [Drafted] {
        let resolved = try resolve(values)

        var stamped: [Stamped] = []
        var taken = existingIDs
        for block in items {
            let line = Self.substitute(block.line, values: resolved)
            guard let item = BacklogParser.parseItemLine(line, verifyDefault: nil),
                  !item.id.isEmpty else {
                throw BacklogTemplateError.unreadableItemLine(line)
            }
            let body = Self.substitute(block.body, values: resolved)
            let detail = BacklogParser.parseDetail(body, fallbackID: item.id)

            if let rejection = CoordinatorBounds.filedItemRejection(
                draft: .init(id: item.id, title: item.title), existingIDs: taken) {
                throw BacklogTemplateError.idRejected(rejection)
            }
            taken.insert(item.id)

            stamped.append(Stamped(
                id: item.id,
                title: item.title,
                size: item.size?.rawValue ?? "",
                verify: item.verify ?? "",
                what: detail?.what ?? "",
                how: detail?.approach ?? "",
                validation: detail?.acceptanceCriteria ?? [],
                outOfScope: detail?.outOfScope ?? [],
                epic: epic,
                needs: item.needs,
                premise: detail?.premise ?? []
            ))
        }
        // The stamp's own ids count as known, since they are filed together —
        // which is what keeps the ordering a template writes between its own
        // steps.
        return QueueRefill.resolveDependencies(stamped, existingIDs: existingIDs)
    }

    /// The variables as substitution will use them: every declared name mapped to
    /// the value it was given, or to nothing when it is optional and absent.
    private func resolve(_ values: [String: String]) throws -> [String: String] {
        for name in values.keys where variable(named: name) == nil {
            throw BacklogTemplateError.unknownVariable(name)
        }
        var resolved: [String: String] = [:]
        for variable in variables {
            let value = (values[variable.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                guard !variable.required else {
                    throw BacklogTemplateError.missingVariable(variable.name)
                }
                resolved[variable.name] = ""
                continue
            }
            // Structural, whatever the pattern says: a backlog line is one line,
            // and a value carrying braces would stamp something that looks like a
            // placeholder into a filed item.
            guard !value.contains(where: \.isNewline),
                  !value.contains("{{"), !value.contains("}}") else {
                throw BacklogTemplateError.unusableValue(variable.name)
            }
            if let pattern = variable.pattern {
                guard let regex = try? Regex(pattern) else {
                    throw BacklogTemplateError.badPattern(name: variable.name, pattern: pattern)
                }
                guard (try? regex.wholeMatch(in: value)) != nil else {
                    throw BacklogTemplateError.constraintViolated(
                        name: variable.name, value: value, pattern: pattern)
                }
            }
            resolved[variable.name] = value
        }
        return resolved
    }
}

// MARK: - Gating and filing

extension BacklogTemplate {

    /// One stamped item with the filing gates' verdict on it.
    struct GatedItem: Sendable {
        let draft: Stamped
        /// `ready` when both gates pass, `draft` when either doesn't.
        let status: BacklogItemStatus
        /// What the stamp has to say about this item: a gate's own words for why
        /// it isn't `ready`, and anything resolving its `needs:` had to report.
        /// Written into the item's `## Notes`, so whoever finds a parked item is
        /// told what stopped it — and whoever finds a `ready` one is told what
        /// the stamp had to change to get it there.
        let notes: [String]
    }

    /// The same two gates a coordinator filing faces — `DefinitionOfReady` and
    /// `GroundingCheck` — run before anything is written.
    ///
    /// A template is written once and stamped for years, so a stamp is exactly
    /// where a checklist can go stale: a `verify:` naming a file that has since
    /// moved passes review the day it is written and refuses at pickup a year
    /// later. Parking rather than refusing matches `CoordinatorQueueRefill.gate`
    /// — a `draft` item is one autopilot will never pick up, and the reason
    /// travels with it.
    ///
    /// It is the **gates** that park an item, not the notes it arrives with. A
    /// stamp has things to say that aren't refusals — a `needs:` id that named
    /// nothing was dropped rather than written — and an item is not made
    /// unrunnable by something already fixed on its way here, which is the
    /// distinction `CoordinatorQueueRefill.gate` draws for the same reason.
    static func gate(_ drafts: [Drafted], sources: GroundingCheck.Sources) -> [GatedItem] {
        drafts.map { drafted in
            let draft = drafted.draft
            var notes = drafted.notes
            var refused = false
            let item = draft.item(status: .ready)
            let readiness = DefinitionOfReady.evaluate(item: item, detail: draft.detail)
            if !readiness.isReady {
                notes.append("self-check failed: \(readiness.summary)")
                refused = true
            }
            let grounding = GroundingCheck.evaluate(item: item, detail: draft.detail, sources: sources)
            if !grounding.isGrounded {
                notes.append("grounding check failed: \(grounding.summary)")
                refused = true
            }
            return GatedItem(draft: draft, status: refused ? .draft : .ready, notes: notes)
        }
    }

    /// The stamp as previewable edit ops, so it is filed through
    /// `BacklogAIEditor`'s preview-then-apply rather than by a second writer.
    static func ops(for gated: [GatedItem], epic: String) -> [BacklogEditOp] {
        gated.map { .stampItem(epic: epic, draft: $0.draft, status: $0.status, notes: $0.notes) }
    }

    /// Where stamped items go: the epic the template names when the backlog has
    /// it, its first section otherwise — the same choice
    /// `CoordinatorQueueRefill.section(for:in:)` makes, and for the same reason.
    /// Inventing an epic per stamp would turn a groomed backlog into a pile of
    /// one-item sections.
    func section(in backlog: BacklogFile?) -> String {
        if let epic, backlog?.sections.contains(where: { $0.name == epic }) == true { return epic }
        return backlog?.sections.first?.name ?? "Now"
    }
}

// MARK: - Grooming skeletons

extension BacklogTemplate {

    /// What a fresh item's shape is judged against before it names anything —
    /// the clause its kind demands in `## What`. A bug is reproduced before
    /// it's explained; a feature names what someone using the app sees
    /// change; tooling names the check or script it serves. The What/How/
    /// Validation shape stays exactly what `DefinitionOfReady` already judges
    /// — a kind adds a sentence, never a field.
    ///
    /// `feature` is the steering lever: internal polish has no honest answer
    /// to "what does someone using the app see change", so the sentence is
    /// what makes it structurally hard to file as a feature.
    enum ItemKind: String, CaseIterable, Sendable {
        case bug
        case feature
        case tooling

        /// The literal label this kind's required sentence opens with — the
        /// same string both the skeleton's own body and `carriesClause`
        /// look for, so the two cannot drift apart.
        var clauseLabel: String {
            switch self {
            case .bug: return "Repro:"
            case .feature: return "User-visible outcome:"
            case .tooling: return "Serves:"
            }
        }

        /// Whether `what` carries this kind's required sentence — the label
        /// followed by something on the same line, not the label standing
        /// alone with nothing after it.
        func carriesClause(_ what: String) -> Bool {
            guard let range = what.range(of: clauseLabel) else { return false }
            let rest = what[range.upperBound...].prefix { !$0.isNewline }
            return !rest.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// This kind's grooming skeleton — a starting shape for a fresh
        /// detail file, read by the same parser a hand-authored
        /// `templates/*.md` is. Parsed once from content fixed at build time
        /// and proven by `testEveryGroomingSkeletonParses`, so a parse
        /// failure here would already have failed that test.
        var skeleton: BacklogTemplate {
            // swiftlint:disable:next force_try
            try! BacklogTemplate.parse(Self.skeletonSource(for: self), name: rawValue)
        }

        /// The same two gates a coordinator filing faces
        /// (`BacklogTemplate.gate`), plus this kind's own: a stamp whose
        /// `## What` doesn't carry the sentence this kind demands is parked
        /// exactly as an ungrounded or ill-groomed one would be. Both
        /// `bug.md`'s and `tooling.md`'s clause variable is optional at the
        /// template level for the same reason — omitting it must still file
        /// something a groomer can find and finish, not refuse the stamp
        /// outright.
        func gate(_ drafts: [Drafted], sources: GroundingCheck.Sources) -> [GatedItem] {
            BacklogTemplate.gate(drafts, sources: sources).map { gated in
                guard !carriesClause(gated.draft.what) else { return gated }
                var notes = gated.notes
                notes.append("self-check failed: `## What` is missing this kind's required sentence "
                             + "— \"\(clauseLabel) …\"")
                return GatedItem(draft: gated.draft, status: .draft, notes: notes)
            }
        }

        private static func skeletonSource(for kind: ItemKind) -> String {
            switch kind {
            case .bug:
                return skeleton(
                    description: "A bug — reproduced before it's explained.",
                    what: "What is broken, in one line.",
                    extra: "repro", extraDescription: "Exact steps that reproduce it, from a clean state.",
                    sentence: "Repro: {{repro}}")
            case .feature:
                return skeleton(
                    description: "A feature — what someone using the app sees change.",
                    what: "What exists or behaves differently when it's done.",
                    extra: "outcome",
                    extraDescription: "What someone using the app sees change. Internal polish has no honest answer here.",
                    sentence: "User-visible outcome: {{outcome}}")
            case .tooling:
                return skeleton(
                    description: "Tooling — the check or script this item serves.",
                    what: "What the check or script does today, and what's wrong with it.",
                    extra: "serves", extraDescription: "The check or script this item serves, named exactly.",
                    sentence: "Serves: {{serves}}")
            }
        }

        /// One skeleton per kind, from the four things that differ: the
        /// frontmatter's description, the `what` variable's description, the one
        /// variable only this kind carries, and the sentence in `## What` that
        /// uses it. Everything else — the shared variables, the premise, the
        /// body's sections — is written once, which is what keeps the three
        /// from drifting apart a line at a time: the premise variable landed in
        /// three places when it landed at all.
        private static func skeleton(description: String, what: String,
                                     extra: String, extraDescription: String,
                                     sentence: String) -> String {
            skeletonFrontmatter(description: description, what: what,
                                extra: extra, extraDescription: extraDescription)
                + skeletonBody(sentence: sentence)
        }

        private static func skeletonFrontmatter(description: String, what: String,
                                                extra: String, extraDescription: String) -> String {
            """
            ---
            description: \(description)
            variables:
              - name: id
                required: true
              - name: title
                required: true
              - name: size
                description: XS, S or M
                required: true
                pattern: ^(XS|S|M)$
              - name: verify
                required: true
              - name: what
                description: \(what)
                required: true
              - name: \(extra)
                description: \(extraDescription)
                required: false
              - name: premise
                description: The claims the item rests on, for the worker to check against the tree before building. Empty when it states none.
                required: false
              - name: how
                required: true
              - name: validation
                required: true
              - name: outOfScope
                required: true
            ---

            """
        }

        private static func skeletonBody(sentence: String) -> String {
            """
            ## Item

            - [ ] {{id}} | {{title}} | size:{{size}} | verify:{{verify}}

            ## What

            {{what}}

            \(sentence)

            ## Premise

            - {{premise}}

            ## How

            {{how}}

            ## Validation

            - [ ] {{validation}}

            ## Out of Scope

            - {{outOfScope}}
            """
        }
    }
}

/// Why a template could not be read, or could not be stamped. Every case carries
/// what the person who has to fix it needs to know — which variable, which
/// pattern, which id — because "the template is invalid" sends them reading the
/// file from the top.
enum BacklogTemplateError: Error, Equatable, LocalizedError {
    case noItems
    case blockWithoutAnItemLine
    case unnamedVariable
    case duplicateVariable(String)
    case undeclaredPlaceholder(String)
    case badPattern(name: String, pattern: String)
    case unknownVariable(String)
    case missingVariable(String)
    case unusableValue(String)
    case constraintViolated(name: String, value: String, pattern: String)
    case unreadableItemLine(String)
    case idRejected(String)

    var message: String {
        switch self {
        case .noItems:
            return "template stamps no items — a template needs at least one \"\(BacklogTemplate.itemHeading)\" block"
        case .blockWithoutAnItemLine:
            return "a \"\(BacklogTemplate.itemHeading)\" block does not start with a `- [ ] id | title | …` line"
        case .unnamedVariable:
            return "a declared variable has no name"
        case .duplicateVariable(let name):
            return "variable \"\(name)\" is declared twice"
        case .undeclaredPlaceholder(let name):
            return "{{\(name)}} is used but not declared under variables:"
        case .badPattern(let name, let pattern):
            return "variable \"\(name)\" has an unreadable pattern: \(pattern)"
        case .unknownVariable(let name):
            return "this template declares no variable \"\(name)\""
        case .missingVariable(let name):
            return "variable \"\(name)\" is required and was not given"
        case .unusableValue(let name):
            return "the value for \"\(name)\" must be one line and must not contain {{ or }}"
        case .constraintViolated(let name, let value, let pattern):
            return "\"\(value)\" is not a usable \"\(name)\" — it must match \(pattern)"
        case .unreadableItemLine(let line):
            return "this line is not a backlog item: \(line)"
        case .idRejected(let reason):
            return reason
        }
    }

    var errorDescription: String? { message }
}

/// Where a project's templates live, and what is in them.
///
/// Beside the backlog file, which is where the item lines they stamp already
/// live. The project root is searched too when the backlog is somewhere else —
/// a vault-backed project keeps its backlog outside the repo, and a process
/// checklist for that repo belongs under version control with the code it is
/// about. The two are the same directory for a project-local `BACKLOG.md`.
enum BacklogTemplateStore {

    /// One file in a templates directory: parsed, or the reason it wasn't.
    ///
    /// A template that fails to parse is listed rather than dropped. Silently
    /// omitting it reads as "there is no such template", which sends whoever
    /// wrote it looking in the wrong place.
    struct Entry: Sendable {
        let name: String
        let url: URL
        let template: BacklogTemplate?
        let error: String?
    }

    static let directoryName = "templates"

    /// The directories searched, nearest first and without duplicates.
    static func directories(backlogURL: URL?, projectRoot: URL) -> [URL] {
        var out: [URL] = []
        if let backlogURL {
            out.append(backlogURL.deletingLastPathComponent().appending(path: directoryName))
        }
        out.append(projectRoot.appending(path: directoryName))
        var seen: Set<String> = []
        return out.filter { seen.insert($0.standardizedFileURL.path(percentEncoded: false)).inserted }
    }

    /// Every `.md` file in those directories, in directory order and then by
    /// name. The first directory holding a name wins, so a project-local template
    /// shadows a repo one rather than both appearing.
    static func list(backlogURL: URL?, projectRoot: URL) -> [Entry] {
        var entries: [Entry] = []
        var seen: Set<String> = []
        for directory in directories(backlogURL: backlogURL, projectRoot: projectRoot) {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls.filter({ $0.pathExtension.lowercased() == "md" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name).inserted else { continue }
                entries.append(read(url))
            }
        }
        return entries
    }

    /// One template by name, or nil when no searched directory has it.
    static func load(named name: String, backlogURL: URL?, projectRoot: URL) -> Entry? {
        for directory in directories(backlogURL: backlogURL, projectRoot: projectRoot) {
            let url = directory.appending(path: "\(name).md")
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            return read(url)
        }
        return nil
    }

    private static func read(_ url: URL) -> Entry {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return Entry(name: name, url: url, template: nil, error: "couldn't read \(url.lastPathComponent)")
        }
        let content = String(decoding: data, as: UTF8.self)
        do {
            return Entry(name: name, url: url,
                         template: try BacklogTemplate.parse(content, name: name), error: nil)
        } catch let error as BacklogTemplateError {
            templateLog.error("template \(name, privacy: .public): \(error.message, privacy: .public)")
            return Entry(name: name, url: url, template: nil, error: error.message)
        } catch {
            return Entry(name: name, url: url, template: nil, error: error.localizedDescription)
        }
    }
}
