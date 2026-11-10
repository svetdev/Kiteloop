import Foundation

/// Is a groomed item **true** about the repo it will be built in?
///
/// `DefinitionOfReady` checks that an item is *shaped* right — What/How/
/// Validation, a `verify:` command, a size. Nothing checked that what it says is
/// *so*, and to a worker the two failures look identical until it goes looking: a
/// detail file here told one to copy a tool-provider symbol that is in no file in
/// this repo, and the run was spent hunting for something that was never there.
/// Items groomed by reading the code first merged; items written from a one-line
/// description came back rejected.
///
/// (That symbol's name is deliberately not written anywhere in the sources —
/// here, or in the tests. Naming it would put it in the index and ground the one
/// invention this check was built to catch.)
///
/// This is a smoke test against invention, not a compiler. It pulls the concrete
/// claims a draft makes — backticked paths and symbols, plus the `verify:`
/// command's executable and the paths it hands that executable — and asks the
/// filesystem whether each one is there. Prose that names nothing concrete is
/// not a failure: the check fires on claims about the code, not on every
/// sentence.
///
/// The command's *arguments* are here for the same reason its executable is, one
/// step later: nothing checked that a `verify:` could run until a merge was on
/// the line. Twelve items on 2026-08-10 named `Kiteloop.xcodeproj` from the
/// project root, where the project is at `Kiteloop/Kiteloop.xcodeproj`, and each
/// was destined to be built against for a whole run and then fail its merge gate
/// in front of a person. What is asked is only whether the paths resolve from the
/// directory the command runs in — never whether the command can pass, which is
/// not decidable from the text and is not attempted.
///
/// Conservative in both directions, on purpose:
///   * only a backticked, code-shaped token is a claim at all — a bare word in a
///     sentence is prose, and guessing which words are symbols would flag half of
///     every draft;
///   * a reference the draft proposes to *create* ("add `GroundingCheck`", or
///     "`GroundingCheck`, which this item adds" — the cue may sit on either
///     side of the name in its sentence) is
///     exempt, and so is every later mention of that same name or path — a
///     Validation criterion three sections on is saying what the proposed thing
///     must do, not claiming it is already there, and a `verify:` that runs the
///     script the item adds is the item's own acceptance criterion rather than a
///     claim the script is on disk. A draft names things that don't exist yet by
///     design; checking those would fail every item that builds something new.
///     Only a name or a path *this draft* introduced is forgiven, so an
///     invention nobody proposed — and a `verify:` nothing in the repo can run —
///     is refused as before. A reference the draft reports as *gone*
///     ("the `docs/old.md` link is dangling") gets the same forgiveness for the
///     mirror-image reason: prose that says a reference is missing is a report
///     of its absence, not a claim it is there.
///
/// Both rules trade misses for false alarms. A missed invention costs one run; a
/// wrongly refused item strands real work and no one finds out why.
///
/// ## Which corpus a citation belongs to
///
/// The check began by asking one body of files — this repo — about every token,
/// and refused as an invention everything that named something real *somewhere
/// else*: a path in the vault the backlog lives in, a file in a sibling project,
/// a property of a platform object, a type the platform defines. Each was
/// patched with one more prefix rule, and another class nobody predicted
/// followed it every time; the trailing `:NNN` line reference alone refused
/// eleven correctly groomed items in a single pass.
///
/// The mistake was structural. A citation is a claim about *some* corpus, and
/// the question is which:
///   * a path is looked for in the repo, then in the vault, then in a sibling
///     project — but a sibling's tree only when the draft **names** that
///     project, so an unnamed corpus can never quietly ground a citation;
///   * a dotted name is judged by its **root**. `BacklogAutopilot.start` roots
///     in a type this repo **declares**, so the whole chain is checkable;
///     `window.name`, `res.ok` and `process.env` root in objects no file here
///     declares, so they are not claims about this code at all — and neither
///     is `Bundle.main`: this repo writes it constantly but declares no
///     `Bundle` of its own, so a member of it this repo never wrote is a
///     platform's business, not an invention;
///   * an undotted name that isn't here is judged by what it would be. A
///     capitalised one is a *type*, and types come from platforms, packages and
///     languages at least as often as from this source (`DOMString`) — corpora
///     no index of this tree can hold. A lower-camel one is a *member*, and a
///     member this repo does not define and nothing anchors is an invention:
///     `checkCostCaps` was caught that way and would have sent a worker looking
///     for code that never existed.
///
/// One corpus is not a tree at all. The app *writes* files that no checkout ever
/// holds — the settings file, the day's spend file, the agent catalog, a run's
/// pruned-transcript marker, the run-record log — and a draft about one of them
/// cites a name that is true of the running app and absent from every filesystem
/// this check can walk. Five of the eight refusals in one pass were exactly that,
/// and each of the five names is a quoted string literal sitting a few lines from
/// the code that opens the file. So a path no corpus holds is asked one last
/// question before it is refused: do this repo's own sources *construct* a file
/// by that name?
///
/// Nor is every slash a directory. A GitHub Action is written
/// `owner/name@ref`, which no checkout holds a file at and this repo's CI
/// resolves all the same — `ci-keeps-a-red-runs-output-nowhere` was parked for
/// citing `actions/upload-artifact@v4`, which `.github/workflows/ci.yml` names
/// on its own `uses:` line. So the workflow files are asked too, and they are
/// the whole of that corpus: an action nothing under `.github/workflows/` uses
/// is refused as before, and nobody asks GitHub whether it exists. A name no
/// source constructs, no workflow uses and no corpus holds is refused as before,
/// with the note it has always carried.
///
/// Every refusal names the rule that made the token checkable as well as the
/// token, because without it each new false positive is a fresh investigation.
///
/// Pure apart from `Sources`, which is the whole of its contact with the
/// filesystem — so the rules are testable without a repo on disk.
package enum GroundingCheck {

    // MARK: - What the check found

    /// One concrete claim, and whether the repo bears it out.
    package struct Reference: Equatable, Sendable {
        package enum Kind: String, Sendable {
            /// A file or directory the draft says is there.
            case path
            /// A type, function or property name the draft says is in the sources.
            case symbol
            /// The executable the `verify:` command runs.
            case command
            /// A path the `verify:` command hands to that executable, judged from
            /// the directory the command will run in.
            case commandPath = "command path"
        }

        package let kind: Kind
        /// Exactly as the draft wrote it — what a groomer has to go and find.
        package let text: String
        /// Why the check treated this span as a claim it could judge, in words —
        /// "it is written as a repo-relative path", "its root `Foo` is defined in
        /// this repo". A refusal that names only the token makes every new false
        /// positive an investigation into which rule selected it; this is that
        /// answer, carried on the reference and quoted in the note.
        package let rule: String
        package let resolved: Bool
        /// Why it didn't resolve, phrased for whoever has to fix the draft. Nil
        /// when it did.
        package let note: String?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(kind: Kind, text: String, rule: String, resolved: Bool, note: String?) {
            self.kind = kind
            self.text = text
            self.rule = rule
            self.resolved = resolved
            self.note = note
        }
    }

    /// The check's answer: everything it looked at, not merely what failed. A
    /// passing item should be auditable — "nothing was flagged" and "nothing was
    /// checked" are very different states, and only the audit tells them apart.
    package struct Verdict: Equatable, Sendable {
        package let checked: [Reference]

        package var unresolved: [Reference] { checked.filter { !$0.resolved } }

        package var isGrounded: Bool { unresolved.isEmpty }

        /// The failures on one line — what a skip log entry quotes.
        ///
        /// Each refused path or symbol carries, after its note, what would have
        /// excused it (`cueHint(for:)`) — a refusal that named only the
        /// reference sent the author to read the check to learn the rule, which
        /// is how four of five hand-groomed detail files stood refused for word
        /// order on 2026-09-03. Ends with the two remedies that clear every
        /// refusal this check can make, named once no matter how many
        /// references were refused: the check already forgives a name or path
        /// the draft itself introduces with a creation cue (`isProposed(_:)`),
        /// or reports as gone with an absence cue (`isAbsent(_:)`), so the fix
        /// for an unresolved citation is one of the two — "add", "create", … or
        /// "missing", "gone", … — in the same sentence as the backticked
        /// mention.
        package var summary: String {
            guard !unresolved.isEmpty else { return "" }
            let notes = unresolved.compactMap { reference in
                reference.note.map { $0 + (Verdict.cueHint(for: reference.kind).map { "; " + $0 } ?? "") }
            }
            return notes.joined(separator: "; ") + "; " + remedy
        }

        /// The clause a refused prose citation gets: how it was read, and the
        /// cue that would have excused it, with the sample cues read off
        /// `creationCues` so the message cannot drift from the set. A `verify:`
        /// refusal gets none — an executable is excused by proposing the script
        /// in the prose, and a path argument's refusal already names its `cd`.
        package static func cueHint(for kind: Reference.Kind) -> String? {
            let cue = "if this draft creates it, say so in the same sentence with a creation cue ("
                + sampleCreationCues.joined(separator: ", ") + ", …)"
            switch kind {
            case .path: return "read as a path; " + cue
            case .symbol: return "read as a symbol; " + cue
            case .command, .commandPath: return nil
            }
        }

        /// The single-line remedy clause appended to `summary`. A reference the
        /// draft proposes to create, or reports as gone, is exempt from this
        /// whole check — say so with a creation cue or an absence cue in the
        /// same sentence as the citation, and it reads as a proposal or a
        /// report instead of a claim that the reference is there today. A cue
        /// after the mention binds to the next backticked span in the sentence
        /// when there is one (`isExcused(after:)`), which the clause says.
        private var remedy: String {
            "a reference this draft proposes to create, or reports as gone,"
                + " is exempt from this check — say so with a creation cue"
                + " (\"add\", \"create\", …) or an absence cue (\"missing\", \"gone\", …)"
                + " in the same sentence as the backticked mention, before it or after it"
                + " (a cue after it belongs to the next backticked span in the sentence, if there is one)"
        }

        /// What was looked at, pass or fail. Failures are marked, so one line
        /// serves both the audit and the diagnosis.
        package var audit: String {
            guard !checked.isEmpty else { return "no code references to check" }
            let list = checked
                .map { "\($0.kind.rawValue) \($0.text)\($0.resolved ? "" : " ✗")" }
                .joined(separator: ", ")
            return "checked \(checked.count) reference\(checked.count == 1 ? "" : "s"): \(list)"
        }

        package static let grounded = Verdict(checked: [])
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(checked: [Reference]) {
            self.checked = checked
        }
    }

    // MARK: - The corpora a citation can be about

    /// One body of files a cited path could be a claim about.
    ///
    /// The repo is the first and the usual one. The vault the backlog lives in
    /// is a second: `Projects/kiteloop/Backlog.md` and the `backlog/<id>.md`
    /// files beside it are real, and refusing them refused correctly groomed
    /// items. A sibling project in the same portfolio is a third.
    package struct Corpus: Sendable {
        /// What a refusal calls it: "the repo", "the vault", "the aurora project".
        package let name: String
        /// The words that bring this corpus into scope. Empty means always in
        /// scope, which the repo and the vault are — an item's own detail file
        /// lives in one of them whether or not it says so.
        ///
        /// A sibling project's tree is *not* always in scope. `apps/web` is a
        /// claim about that project only when the draft names it; letting every
        /// project in the portfolio answer for every citation would ground
        /// tokens by coincidence and hollow the check out.
        package let namedBy: Set<String>
        /// Is this repo-relative path in this corpus? Implementations may match
        /// a suffix — a draft writes `Services/Foo.swift` for a file kept at
        /// `Kiteloop/Kiteloop/Services/Foo.swift`, and that is the same claim.
        package let contains: @Sendable (String) -> Bool

        package init(name: String, namedBy: Set<String> = [],
             contains: @escaping @Sendable (String) -> Bool) {
            self.name = name
            self.namedBy = namedBy
            self.contains = contains
        }

        /// Whether a draft that used these words brought this corpus into scope.
        package func isNamed(by words: Set<String>) -> Bool {
            namedBy.isEmpty || !namedBy.isDisjoint(with: words)
        }
    }

    /// Every question the check asks of the filesystem, in one injectable value.
    /// The real one is an index built once per run (`repository(root:vault:)`);
    /// tests pass sets instead, so no rule here needs a repo on disk to exercise.
    package struct Sources: Sendable {
        /// Where a path citation may resolve, nearest first — the repo, then the
        /// vault, then any sibling project the draft names. Order decides which
        /// corpus a refusal reports a path was found in when several hold it.
        package var corpora: [Corpus]
        /// Does this identifier appear anywhere in the sources?
        package var definesSymbol: @Sendable (String) -> Bool
        /// Is this name a type this repo declares — a top-level `struct`,
        /// `class`, `enum`, `actor`, `protocol` or `extension`?
        ///
        /// Narrower than `definesSymbol` on purpose. A dotted citation's root
        /// asks whether the chain is a claim about *this code specifically*,
        /// and `definesSymbol` answers a wider question than that: this repo
        /// writes `Bundle.main`, which puts `Bundle` in `definesSymbol`
        /// without this repo owning a single member of it, so every platform
        /// type the sources merely mention became a checkable root the same
        /// way — `Bundle.main.resourceURL` was refused for exactly that.
        ///
        /// `nil` when a `Sources` was built without this question, and the
        /// dotted-root check then falls back to `definesSymbol` — so a caller
        /// from before this distinction existed keeps asking what it always
        /// asked, rather than silently losing coverage of its dotted cases.
        package var declaresType: (@Sendable (String) -> Bool)?
        /// Does this command name resolve to something runnable?
        package var resolvesExecutable: @Sendable (String) -> Bool
        /// The directories `resolvesExecutable` looks in, so a refusal can say
        /// where the app searched. Empty when a `Sources` was built without
        /// them, in which case the note names no directories.
        package var searchDirectories: [String]
        /// Every repo-relative path whose last component is this name.
        ///
        /// Deliberately not `corpora`, which answer a *suffix-tolerant* question:
        /// a draft that writes `Services/Foo.swift` for a file kept at
        /// `Kiteloop/Kiteloop/Services/Foo.swift` is making the same claim, and
        /// letting that through is right for prose. A command is not prose — it
        /// runs in one directory, and `Kiteloop.xcodeproj` there is either exactly
        /// `Kiteloop.xcodeproj` or it is a path the shell cannot find. Asking for
        /// the paths by name gives that exact answer *and* the one thing a useful
        /// refusal needs: where the file actually is, so the note can name the
        /// `cd` that was left out.
        package var pathsNamed: @Sendable (String) -> [String]
        /// Do this repo's own sources construct a file by this name?
        ///
        /// Asked of a bare filename — the last component of a cited path — and
        /// only once every corpus has declined, because it answers a weaker
        /// question than they do: that the app writes a file by this name, not
        /// that any tree holds one at that path. That is the right strength for
        /// a runtime file and the wrong strength for anything else, which is why
        /// it goes last rather than beside `corpora`.
        ///
        /// It buys a class of false negative knowingly: a filename quoted
        /// anywhere in the sources — a fixture in a test, a value in a JSON —
        /// will ground a citation of a file that is not there. That is the trade
        /// this whole file makes, in the direction it always makes it. A missed
        /// invention costs one run; a wrongly refused item strands real work and
        /// no one finds out why.
        package var constructsFile: @Sendable (String) -> Bool
        /// Does a workflow file under `.github/workflows/` use this action?
        ///
        /// Asked of a token that reads as a path and that no corpus holds, for
        /// the same reason `constructsFile` is: a GitHub Action reference is
        /// written `owner/name@ref`, which has a slash in it and none of the
        /// exclusions `looksLikePath` makes, so it is read as a repo-relative
        /// path and refused — no checkout holds a file at
        /// `actions/upload-artifact@v4`, and this repo's CI runs it anyway.
        ///
        /// The corpus is this repo's workflow files and nothing else, which is
        /// what keeps the answer narrow: it says the action is one *this* CI
        /// already uses, not that some action by that name exists somewhere on
        /// GitHub. An invented reference is refused with the note it has always
        /// carried.
        ///
        /// Both spellings answer, because a draft writes both — the pinned
        /// `owner/name@ref` when it means the version CI runs, the bare
        /// `owner/name` when it means the action itself.
        package var usesAction: @Sendable (String) -> Bool

        package init(corpora: [Corpus],
             definesSymbol: @escaping @Sendable (String) -> Bool,
             resolvesExecutable: @escaping @Sendable (String) -> Bool,
             pathsNamed: @escaping @Sendable (String) -> [String] = { _ in [] },
             constructsFile: @escaping @Sendable (String) -> Bool = { _ in false },
             usesAction: @escaping @Sendable (String) -> Bool = { _ in false },
             declaresType: (@Sendable (String) -> Bool)? = nil,
             searchDirectories: [String] = []) {
            self.corpora = corpora
            self.definesSymbol = definesSymbol
            self.resolvesExecutable = resolvesExecutable
            self.searchDirectories = searchDirectories
            self.pathsNamed = pathsNamed
            self.constructsFile = constructsFile
            self.usesAction = usesAction
            self.declaresType = declaresType
        }

        /// The repo and nothing else — what a caller with no vault has, and what
        /// a test that only exercises the rules passes.
        package init(pathExists: @escaping @Sendable (String) -> Bool,
             definesSymbol: @escaping @Sendable (String) -> Bool,
             resolvesExecutable: @escaping @Sendable (String) -> Bool,
             pathsNamed: @escaping @Sendable (String) -> [String] = { _ in [] },
             constructsFile: @escaping @Sendable (String) -> Bool = { _ in false },
             usesAction: @escaping @Sendable (String) -> Bool = { _ in false },
             declaresType: (@Sendable (String) -> Bool)? = nil,
             searchDirectories: [String] = []) {
            self.init(corpora: [Corpus(name: "the repo", contains: pathExists)],
                      definesSymbol: definesSymbol,
                      resolvesExecutable: resolvesExecutable,
                      pathsNamed: pathsNamed,
                      constructsFile: constructsFile,
                      usesAction: usesAction,
                      declaresType: declaresType,
                      searchDirectories: searchDirectories)
        }

        /// The live check: index the corpora once, then answer from memory.
        /// Building walks a tree and reads every source file, so do it off the
        /// main actor and share the result across an item queue.
        ///
        /// `vault` widens the check rather than loosening it: it brings in the
        /// backlog's own directory, and — through the vault's registry — the
        /// other projects in the portfolio.
        ///
        /// `searchDirectories` is where a verify command's executable is looked
        /// for — the app's one search policy for this project unless a test
        /// hands in a list of its own. `baseBranch`: see `BaseTree.read`.
        package static func repository(root: URL, vault: URL? = nil, baseBranch: String? = nil,
                                       searchDirectories: [String]? = nil) -> Sources {
            let directories = searchDirectories ?? ExecutableSearchPath.resolved(projectRoot: root).directories
            let reading = BaseTree.read(root: root, baseBranch: baseBranch)
            var corpora = reading.corpora

            if let vault {
                // Paths only: a symbol that appears in a note rather than in
                // source is exactly the invention this check exists to catch, so
                // the vault answers about files and never about identifiers.
                let notes = SourceIndex.build(root: vault, indexingIdentifiers: false)
                corpora.append(Corpus(name: "the vault", contains: { notes.containsPath($0) }))
                corpora.append(contentsOf: siblingCorpora(vault: vault, excluding: root))
            }

            return Sources(
                corpora: corpora,
                definesSymbol: { reading.index.identifiers.contains($0) },
                resolvesExecutable: { reading.resolvesExecutable($0, root: root, searchDirectories: directories) },
                // The repo's index alone: a verify command runs in the checkout,
                // so the vault and the sibling projects have no standing to say
                // one of its paths is there.
                pathsNamed: { reading.index.pathsByName[$0] ?? [] },
                // Likewise: the question is what *this* repo's code writes, so
                // the vault's notes and a sibling's sources never answer it.
                constructsFile: { reading.index.fileLiterals.contains($0) },
                // And likewise: which actions *this* CI runs is a question only
                // this repo's `.github/workflows/` can answer, so the vault's
                // notes and a sibling's workflows never do.
                usesAction: { reading.index.actionReferences.contains($0) },
                declaresType: { reading.index.declaredTypes.contains($0) },
                searchDirectories: directories
            )
        }

        /// The other projects the vault's registry knows about, one corpus each,
        /// in scope only for a draft that names them.
        ///
        /// Asked directly rather than indexed: a citation of a sibling is written
        /// relative to that project's root (`apps/web`, `Cargo.toml`, `.sqlx/`),
        /// so an existence check answers it, and walking every project in the
        /// portfolio at every pickup would cost far more than the gate it feeds.
        package static func siblingCorpora(vault: URL, excluding root: URL) -> [Corpus] {
            let registryURL = vault.appending(path: "Logs/registry.yaml")
            guard let yaml = (try? Data(contentsOf: registryURL)).map({ String(decoding: $0, as: UTF8.self) }) else { return [] }
            let here = canonicalDirectory(root)

            return BacklogParser.parseRegistry(yaml).compactMap { entry -> Corpus? in
                guard let repo = entry.repo, !repo.isEmpty else { return nil }
                let path = canonicalDirectory(
                    URL(fileURLWithPath: (repo as NSString).expandingTildeInPath))
                // The project being checked is already the repo corpus. Listing
                // it again as a sibling would put its own tree behind a rule that
                // needs the item to name it.
                guard path != here else { return nil }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return nil }

                let sibling = URL(fileURLWithPath: path)
                let names = ([entry.name, sibling.lastPathComponent] + entry.aliases)
                    .map { $0.lowercased() }
                    .filter { !$0.isEmpty }
                guard !names.isEmpty else { return nil }

                return Corpus(name: "the \(entry.name) project", namedBy: Set(names)) { cited in
                    let relative = SourceIndex.normalize(cited)
                    guard !relative.isEmpty else { return false }
                    return FileManager.default.fileExists(
                        atPath: sibling.appending(path: relative).path(percentEncoded: false))
                }
            }
        }

        /// One spelling for a directory, so a registry entry and a project root
        /// that name the same tree compare equal — tilde expanded, symlinks
        /// resolved (`/var` is `/private/var` here), no trailing slash. Without
        /// it the project being checked reappears as its own sibling, and its
        /// own files then need the item to name the project to resolve.
        package static func canonicalDirectory(_ url: URL) -> String {
            var path = url.resolvingSymlinksInPath().standardizedFileURL
                .path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
    }

    // MARK: - Evaluate

    /// Judges one drafted item against the repo.
    ///
    /// - Parameters:
    ///   - item: the backlog line — its title carries the whole draft for a
    ///     project that grooms inline.
    ///   - detail: the groomed `backlog/<id>.md`, or nil when it has none.
    ///   - sources: what the repo actually contains.
    package static func evaluate(item: BacklogItem, detail: BacklogItemDetail?, sources: Sources) -> Verdict {
        var checked: [Reference] = []
        var seen: Set<String> = []
        let text = draftText(item: item, detail: detail)
        // Which corpora this draft put in scope, decided once from the whole
        // draft: a sibling project answers for the item that names it, anywhere
        // in it, not only for the sentence the citation sits in.
        let named = words(in: text)
        let corpora = sources.corpora.filter { $0.isNamed(by: named) }
        // The files this draft says it will create, read once from the whole
        // draft for the same reason: a `verify:` is written to run against the
        // finished item, so the script it names is proposed by the How three
        // sections above it and by nothing in the command itself.
        let proposed = proposedPaths(in: text)

        for citation in citations(in: text) {
            guard seen.insert("\(citation.kind.rawValue):\(citation.text)").inserted else { continue }
            // Nil means the token turned out not to be a claim about this code —
            // uncheckable, like prose, rather than unresolved.
            guard let reference = resolve(citation, corpora: corpora, sources: sources) else { continue }
            checked.append(reference)
        }

        for command in verifyCommands(item: item, detail: detail) {
            checkExecutables(in: command, proposed: proposed, sources: sources, seen: &seen, checked: &checked)
            checkPathArguments(in: command, proposed: proposed, sources: sources, seen: &seen, checked: &checked)
        }

        return Verdict(checked: checked)
    }

    /// The executables one verify command runs, each judged once.
    private static func checkExecutables(in command: String, proposed: Set<String>, sources: Sources,
                                         seen: inout Set<String>, checked: inout [Reference]) {
        for located in locatedExecutables(in: command) {
            let token = located.text
            // A path written after a `cd` runs from where the `cd` left the
            // shell; nil is somewhere this check cannot name, so nothing is said.
            guard let asked = executableQuery(located) else { continue }
            guard seen.insert("command:\(located.directory ?? "")/\(token)").inserted else { continue }
            // An item whose whole point is a new script has to verify by
            // running it, and the shell has nothing to run until the item is
            // built — so `PATH` is the wrong question to ask of a path this
            // draft proposes to create. Recorded as looked at either way; an
            // executable no draft proposed is still asked of the filesystem
            // and still refused with the note it has always carried.
            if isProposed(path: token, among: proposed) || isProposed(path: asked, among: proposed) {
                checked.append(Reference(
                    kind: .command, text: token,
                    rule: "\(commandRule), and this draft proposes to create it",
                    resolved: true, note: nil))
                continue
            }
            let resolved = sources.resolvesExecutable(asked)
            checked.append(Reference(
                kind: .command, text: token, rule: commandRule, resolved: resolved,
                note: resolved ? nil : missingExecutableNote(located, sources: sources)
            ))
        }
    }

    /// What `resolvesExecutable` is asked for one executable: the token itself
    /// when it is a bare name, an absolute path or written from the project
    /// root — exactly what it was always asked — and otherwise the token joined
    /// to the directory its `cd` left, still slashed so it is read as a repo
    /// path rather than looked up on the search path. Nil when that directory is
    /// unknown, or the join climbs out of the checkout.
    private static func executableQuery(_ located: LocatedExecutable) -> String? {
        let token = located.text
        guard token.contains("/"), !token.hasPrefix("/") else { return token }
        guard let directory = located.directory else { return nil }
        guard !directory.isEmpty else { return token }
        guard let joined = resolveRepoPath(token, from: directory), !joined.isEmpty else { return nil }
        return "./" + joined
    }

    /// The refusal for a slashed executable run after a `cd`: which directory
    /// it was looked for in, and — when the repo has the file under another
    /// directory — where, and the re-rooted spelling that reaches it.
    private static func missingExecutableNote(_ located: LocatedExecutable, sources: Sources) -> String {
        let token = located.text
        guard let directory = located.directory, !directory.isEmpty,
              token.contains("/"), !token.hasPrefix("/") else {
            return missingExecutableNote(token, sources: sources)
        }
        var note = "verify command runs `\(token)` from `\(directory)/`, where nothing executable is at that path"
        if let (elsewhere, reroot) = executableElsewhere(token, sources: sources) {
            note += " — the repo has it at `\(elsewhere)`; did you mean "
                + "`cd \"\(repoRootSubstitution)\(reroot)\" && \(token)`?"
        }
        return note + "; read as a claim because \(commandRule)"
    }

    /// Where else the repo has the file a slashed executable names — a path
    /// ending in the token's own components — and the directory, below the repo
    /// root and written `/dir` or `""`, a `cd` must reach for the token to find
    /// it. The root's copy is preferred, being the usual one a `cd` walked away from.
    private static func executableElsewhere(_ token: String, sources: Sources) -> (String, String)? {
        let written = SourceIndex.normalize(token)
        guard !written.hasPrefix("../"), !written.contains("/../") else { return nil }
        let candidates = sources.pathsNamed((written as NSString).lastPathComponent)
            .filter { $0 == written || $0.hasSuffix("/" + written) }
        guard let found = candidates.first(where: { $0 == written }) ?? candidates.first else { return nil }
        let below = String(found.dropLast(written.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (found, below.isEmpty ? "" : "/" + below)
    }

    /// The path arguments one verify command hands its executables, each
    /// judged once from the directory the command reaches it from.
    private static func checkPathArguments(in command: String, proposed: Set<String>, sources: Sources,
                                           seen: inout Set<String>, checked: inout [Reference]) {
        for argument in pathArguments(in: command) {
            guard seen.insert("commandPath:\(argument.directory)/\(argument.text)").inserted
            else { continue }
            guard let reference = resolve(argument, proposing: proposed, sources: sources)
            else { continue }
            checked.append(reference)
        }
    }

    private static let commandRule = "it is the executable of a `verify:` command"

    /// The refusal for an executable nothing resolved, saying where the app
    /// actually looked: on 2026-09-03 the note said only "resolves to no
    /// executable" about a `cargo` that was installed, and nothing in it said
    /// the app had never looked in `~/.cargo/bin`. The three shapes
    /// `Executables.resolvedPath` distinguishes get the three answers it gave
    /// them — a path is never looked up on the search path, so naming that
    /// list for one sent whoever had to fix the draft after their `PATH`
    /// instead of after the repo path or the missing execute bit.
    private static func missingExecutableNote(_ token: String, sources: Sources) -> String {
        let reason: String
        if token.hasPrefix("/") {
            reason = "nothing executable is at that path"
        } else if token.contains("/") {
            reason = "it is not an executable file under the repo root, "
                + "and a `verify:` path is resolved from the repo root rather than looked up on the search path"
        } else {
            reason = Executables.searchedDescription(sources.searchDirectories)
        }
        return "verify command runs `\(token)`, which resolves to no executable ("
            + reason + ")"
            + "; read as a claim because \(commandRule)"
    }
    private static let pathArgumentRule = "it is a path argument of a `verify:` command"

    /// The words a draft used, for deciding which corpora it named. Split on
    /// anything a project name can't contain, so `the aurora-web repo` names
    /// both `aurora-web` and — via the sibling's own folder name — nothing else.
    package static func words(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .map(String.init))
    }

    /// The `.path` arm of `resolve`: a corpus holds it, or this repo's sources
    /// write a file by that name, or its workflows use it as an action — else
    /// a refusal naming what was searched.
    private static func resolvePath(_ citation: Citation, corpora: [Corpus], sources: Sources) -> Reference {
        let rule = "it is written as a repo-relative path"
        if let corpus = corpora.first(where: { $0.contains(citation.text) }) {
            return Reference(kind: .path, text: citation.text,
                             rule: "\(rule), and it is in \(corpus.name)",
                             resolved: true, note: nil)
        }
        // No tree holds it — which is also true of every file the app writes
        // at run time. Those are not inventions, and the sources that open
        // them name them: ask, on the bare filename, before refusing.
        let name = (SourceIndex.normalize(citation.text) as NSString).lastPathComponent
        if !name.isEmpty, sources.constructsFile(name) {
            return Reference(
                kind: .path, text: citation.text,
                rule: "\(rule), and this repo's sources name the file `\(name)`",
                resolved: true, note: nil)
        }
        // Nor is every slash a directory. `actions/upload-artifact@v4` is a
        // GitHub Action, which no tree holds and this repo's CI resolves —
        // and the workflow files that run it are what can say so.
        if sources.usesAction(citation.text) {
            return Reference(
                kind: .path, text: citation.text,
                rule: "\(rule), and this repo's workflow files under `.github/workflows/`"
                      + " use the action `\(citation.text)`",
                resolved: true, note: nil)
        }
        let searched = list(corpora.map(\.name))
        return Reference(
            kind: .path, text: citation.text, rule: rule, resolved: false,
            note: "cites `\(citation.text)`, which is not in \(searched)"
                  + "; read as a claim because \(rule)"
        )
    }

    /// Judges one citation against the corpora in scope.
    ///
    /// Nil when the token is not a claim this repo can be asked about at all —
    /// a property of an object defined elsewhere, a type some platform owns. A
    /// refusal is reserved for a claim that *is* about this code and is false.
    private static func resolve(_ citation: Citation, corpora: [Corpus],
                                sources: Sources) -> Reference? {
        switch citation.kind {
        case .path:
            return resolvePath(citation, corpora: corpora, sources: sources)

        case .symbol:
            let parts = citation.text.split(separator: ".").map(String.init)
            guard let root = parts.first else { return nil }

            if parts.count > 1 {
                // Judge a dotted name by its root. If the root is a type this
                // repo *declares* the whole chain is a claim about this code,
                // and a broken link in it is still a refusal —
                // `BacklogAutopilot.resumeQueue` names a method that isn't
                // there. If the root is not declared here the draft is
                // talking about something else's object — `window.name`,
                // `res.ok`, `process.env`, or a platform type this repo only
                // *mentions*, like `Bundle.main` — and this repo has no
                // standing to call any member of it wrong.
                guard sources.declaresType?(root) ?? sources.definesSymbol(root) else { return nil }
                let rule = "its root `\(root)` is defined in this repo"
                guard let missing = parts.dropFirst().first(where: { !sources.definesSymbol($0) }) else {
                    return Reference(kind: .symbol, text: citation.text, rule: rule,
                                     resolved: true, note: nil)
                }
                return Reference(
                    kind: .symbol, text: citation.text, rule: rule, resolved: false,
                    note: "cites `\(citation.text)` — `\(missing)` — which is in no source file in the repo"
                          + "; read as a claim because \(rule)"
                )
            }

            if sources.definesSymbol(root) {
                return Reference(kind: .symbol, text: citation.text,
                                 rule: "it is a name written in this repo's sources",
                                 resolved: true, note: nil)
            }
            // Not here, and nothing anchors it. What it would be decides whether
            // that is an invention or merely something this repo doesn't own: a
            // capitalised name is a *type*, and a platform, a package or the
            // language defines types this tree could never index (`DOMString`).
            // A lower-camel name is a *member*, and a member is either in these
            // sources or made up — which is the whole point of the check.
            guard let initial = root.first, !initial.isUppercase else { return nil }
            let rule = "it is a lower-camel-case name, which is a member this repo would define"
            return Reference(
                kind: .symbol, text: citation.text, rule: rule, resolved: false,
                note: "cites `\(citation.text)`, which is in no source file in the repo"
                      + "; read as a claim because \(rule)"
            )

        case .command:
            let resolved = sources.resolvesExecutable(citation.text)
            return Reference(
                kind: .command, text: citation.text, rule: commandRule, resolved: resolved,
                note: resolved ? nil : missingExecutableNote(citation.text, sources: sources)
            )

        case .commandPath:
            // Not a shape prose can produce. A path argument is only a claim
            // together with the directory the command reaches it from, which
            // `pathArguments(in:)` carries and a backticked span does not; the
            // `resolve(_:sources:)` beside this one judges it.
            return nil
        }
    }

    /// Judges one path a `verify:` command hands to a program, from the directory
    /// the command will be in when it does.
    ///
    /// Nil when the check has nothing to say. That covers far more than it
    /// refuses, deliberately: static text cannot tell a path the command *reads*
    /// from one it *writes* (`tee results/out.json` names a file that shouldn't
    /// exist yet), nor either of them from a file the run is about to create. So
    /// exactly one shape of miss is a refusal — **the same relative path sitting
    /// under a directory the command never entered**. That is not a guess about
    /// intent; it is a missing `cd`, it names its own fix, and it is the whole of
    /// the failure this rule was built for: twelve open items on 2026-08-10 ran
    /// `xcodebuild -project Kiteloop.xcodeproj` from the project root, where the
    /// project is at `Kiteloop/Kiteloop.xcodeproj`, and every one of them was
    /// destined to fail at its own merge gate in front of a person.
    ///
    /// Nothing here asks whether the command can *pass* — only whether the paths
    /// it names are where it will look for them.
    private static func resolve(_ argument: PathArgument, proposing proposed: Set<String>,
                                sources: Sources) -> Reference? {
        // Nil climbs out of the checkout, where nothing is indexed and no
        // refusal could be justified.
        guard let cited = resolveRepoPath(argument.text, from: argument.directory),
              !cited.isEmpty else { return nil }
        // The forgiveness the prose already gets, reached one step later: a
        // command handed the file this item adds is describing the item, not
        // claiming the file is on disk today.
        if isProposed(path: cited, among: proposed) {
            return Reference(kind: .commandPath, text: argument.text,
                             rule: "\(pathArgumentRule), and this draft proposes to create `\(cited)`",
                             resolved: true, note: nil)
        }
        let candidates = sources.pathsNamed((cited as NSString).lastPathComponent)

        if candidates.contains(cited) {
            return Reference(kind: .commandPath, text: argument.text,
                             rule: "\(pathArgumentRule), and `\(cited)` is in the repo",
                             resolved: true, note: nil)
        }
        guard let elsewhere = candidates.first(where: { $0.hasSuffix("/" + cited) }) else { return nil }

        let directory = String(elsewhere.dropLast(cited.count + 1))
        let from = argument.directory.isEmpty ? "the project root" : "`\(argument.directory)/`"
        return Reference(
            kind: .commandPath, text: argument.text, rule: pathArgumentRule, resolved: false,
            note: "verify command names `\(argument.text)`, which does not exist from \(from)"
                  + " — the repo has it at `\(elsewhere)`; did you mean `cd \(directory) && …`?"
                  + "; read as a claim because \(pathArgumentRule)"
        )
    }

    /// "the repo", "the repo or the vault", "the repo, the vault or the aurora
    /// project" — a refusal has to say where it looked, and a comma-joined list
    /// reads as one place.
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "any corpus in scope" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    /// The prose the check reads. Notes are left out on purpose: they carry past
    /// rejection feedback, which quotes symbols from a diff that may since have
    /// been renamed, and re-litigating that would fail items for their history.
    package static func draftText(item: BacklogItem, detail: BacklogItemDetail?) -> String {
        var parts: [String] = [item.title]
        if let detail {
            parts.append(contentsOf: [detail.what, detail.approach, detail.context].compactMap { $0 })
            parts.append(contentsOf: detail.acceptanceCriteria)
            parts.append(contentsOf: detail.outOfScope)
        }
        return parts.joined(separator: "\n")
    }

    /// Every verify command the run could use — the groomed ones, and the item
    /// line's own as the fallback, matching how `DefinitionOfReady` picks one.
    package static func verifyCommands(item: BacklogItem, detail: BacklogItemDetail?) -> [String] {
        let groomed = (detail?.verifyCommands ?? [])
            .map { $0.cmd.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !groomed.isEmpty { return groomed }
        let line = (item.verify ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? [] : [line]
    }

    // MARK: - Extraction

    /// One concrete reference lifted out of a draft, before the repo is asked
    /// about it.
    package struct Citation: Equatable, Sendable {
        package let kind: Reference.Kind
        package let text: String
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(kind: Reference.Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Pulls the claims out of a draft's prose: backticked spans that look like a
    /// path or a code identifier, minus anything the draft says is being created.
    /// Fenced code blocks are skipped — a snippet is an illustration, not a claim
    /// about what's on disk.
    ///
    /// Two passes over the same spans, because "being created" is a fact about
    /// the *draft*, not about the sentence a span happens to sit in. The cue
    /// excuses the sentence that introduces a name; nothing excused the sentence
    /// three sections later that says what the name must do, so a well-groomed
    /// item was refused by its own acceptance criteria.
    /// `run-records-finalize-without-a-request` sat parked exactly that way: its
    /// How proposed a new method on the control server, and the refusal quoted
    /// the mention of that same method in its Validation.
    ///
    /// So the first pass reads the names the draft *proposes* and the second
    /// pass forgives them wherever they turn up again. It stays narrow in the
    /// direction that matters: only a name this draft itself introduced with a
    /// cue is excused, so an invention nobody proposed is refused exactly as
    /// before.
    ///
    /// Paths are read the same way, and were not at first. A file the draft
    /// proposes was excused only in the sentence that proposed it, so the
    /// Validation bullet saying what the new file must do was refused as a claim
    /// the file is already there — and a bullet that *opens* with the path has no
    /// preceding prose to carry a cue at all, which is how a correctly groomed
    /// draft was refused by its own acceptance criteria. Forgiving a proposed
    /// path says nothing about any other file the draft cites: `Services/Nope.swift`
    /// beside a proposed `scripts/check.sh` is still an invention, and still
    /// refused.
    package static func citations(in text: String) -> [Citation] {
        let symbols = proposedNames(in: text)
        let paths = proposedPaths(in: text)
        var found: [Citation] = []

        for span in backtickedSpans(in: text) {
            guard !isExcused(span), let citation = classify(span.text) else { continue }
            switch citation.kind {
            case .symbol where isProposed(citation.text, among: symbols): continue
            case .path where isProposed(path: citation.text, among: paths): continue
            default: found.append(citation)
            }
        }
        return found
    }

    /// The names this draft forgives — every backticked span whose preceding
    /// prose carries a creation cue or an absence cue, broken into the
    /// identifiers inside it.
    ///
    /// Broken up rather than taken whole because a groomer writes the
    /// introduction as a declaration — "add a `func finalizeRunRecord(id:)` on
    /// the control server" — and `classify` drops any span with a space in it
    /// long before the cue is consulted, so the introduction was invisible twice
    /// over. Splitting on everything that can't be in an identifier reads the
    /// name out of the declaration, and `looksLikeSymbol`'s camel-hump rule
    /// leaves the keywords around it out: `func`, `let`, `String` and `id` have
    /// no hump, and `finalizeRunRecord` does.
    package static func proposedNames(in text: String) -> Set<String> {
        var names: Set<String> = []
        for span in backtickedSpans(in: text) where isExcused(span) {
            let words = span.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            for word in words.map(String.init) where looksLikeSymbol(word) {
                names.insert(word)
            }
        }
        return names
    }

    /// The files this draft forgives — every backticked span whose preceding
    /// prose carries a creation cue or an absence cue and which reads as a path.
    ///
    /// Taken whole rather than broken into words, which is the opposite of
    /// `proposedNames` and for the same reason: a path *is* the span, and the
    /// pieces of one ("scripts", "sh") are not claims anybody makes. The span
    /// goes through the reading a citation gets, so a path proposed at the end of
    /// a sentence and cited bare in the next is one claim rather than two, and
    /// `SourceIndex.normalize` settles the rest — a leading `./` and a trailing
    /// slash are spellings, not different files.
    package static func proposedPaths(in text: String) -> Set<String> {
        var paths: Set<String> = []
        for span in backtickedSpans(in: text) where isExcused(span) {
            guard let citation = classify(span.text), citation.kind == .path else { continue }
            let normalized = SourceIndex.normalize(citation.text)
            if !normalized.isEmpty { paths.insert(normalized) }
        }
        return paths
    }

    /// Whether a cited path is one of the files the draft introduced.
    ///
    /// Matched on the suffix, either way round, because one file gets written two
    /// ways in one draft: a How that proposes `Kiteloop/Kiteloop/Services/Foo.swift`
    /// and a Validation bullet that says `Services/Foo.swift` are saying the same
    /// thing, and a `verify:` reaches the same file from wherever its `cd` left
    /// the shell. The comparison is on whole components — `Foo.swift` does not
    /// forgive `MyFoo.swift`.
    package static func isProposed(path cited: String, among proposed: Set<String>) -> Bool {
        let normalized = SourceIndex.normalize(cited)
        guard !normalized.isEmpty else { return false }
        if proposed.contains(normalized) { return true }
        return proposed.contains {
            $0.hasSuffix("/" + normalized) || normalized.hasSuffix("/" + $0)
        }
    }

    /// Whether a symbol citation is one of the names the draft introduced —
    /// matched on the citation itself, or on the root before its first `.`, the
    /// same part `resolve` judges a dotted name by. A draft that adds `Foo` has
    /// said what `Foo.bar` is about; one that adds nothing named `Baz` has not.
    package static func isProposed(_ symbol: String, among proposed: Set<String>) -> Bool {
        if proposed.contains(symbol) { return true }
        guard let root = symbol.split(separator: ".").first else { return false }
        return proposed.contains(String(root))
    }

    /// One backticked span, with the prose that precedes it on its own line —
    /// what the cue window is read from — and the rest of the line after it,
    /// backticks included, which is where a cue written after the name is read
    /// from (`isExcused(after:)`).
    package struct BacktickedSpan: Equatable, Sendable {
        package let text: String
        package let prose: String
        package let rest: String

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(text: String, prose: String, rest: String = "") {
            self.text = text
            self.prose = prose
            self.rest = rest
        }
    }

    /// Every backticked span in the draft, in order, skipping fenced blocks. The
    /// walk both passes share, so a span read as a proposal in the first is the
    /// same span classified in the second.
    package static func backtickedSpans(in text: String) -> [BacktickedSpan] {
        var spans: [BacktickedSpan] = []
        var inFence = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            let parts = line.components(separatedBy: "`")
            // A span needs both delimiters: with n parts only indices 1..<n-1 sit
            // between a pair, so an unclosed backtick contributes nothing.
            guard parts.count >= 3 else { continue }
            for index in stride(from: 1, to: parts.count - 1, by: 2) {
                spans.append(BacktickedSpan(text: parts[index],
                                            prose: parts[..<index].joined(separator: "`"),
                                            rest: parts[(index + 1)...].joined(separator: "`")))
            }
        }
        return spans
    }

    /// Whether one backticked span is a checkable claim, and which kind, read
    /// with the prose before it alone. The passes over a draft ask `isExcused`
    /// of the whole span instead, so a cue after the name counts too; this is
    /// the before-window reading on its own, which the tests of that window
    /// exercise.
    package static func classify(_ span: String, precededBy prose: String) -> Citation? {
        guard !isProposed(prose), !isAbsent(prose) else { return nil }
        return classify(span)
    }

    /// The same reading with the cue left out: what the span *would* be a claim
    /// about. That is the question the proposal pass asks — the sentence
    /// introducing a file is excused as a claim and is still the place the file
    /// is named — so both passes spell one reference the same way.
    package static func classify(_ span: String) -> Citation? {
        let raw = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // Anything with a space is a command or a phrase, not a single reference;
        // the `verify:` field is where commands get checked.
        guard !raw.contains(" ") else { return nil }
        // A placeholder or a shell expansion names no one thing — `backlog/<id>.md`
        // is a pattern, not a file. A Swift string interpolation is that same
        // class one language over: `\(home.path)/Library/Caches` is an expression
        // that builds a path at run time, and no checkout holds a file at it, so
        // reading it as a repo-relative claim can only refuse a correct citation.
        // `clone-that-stops-to-ask-a-question-never-returns` was parked for
        // quoting the interpolated home-directory expression the item existed to
        // fix — which is the shape a draft about path-building is necessarily
        // about.
        guard !raw.contains(where: { "<>*?${}|\"'".contains($0) }),
              !raw.contains("\\(") else { return nil }

        var token = raw
        // Sentence punctuation trailing a reference is not part of it. A
        // trailing elision is: eating the periods off `Kiteloop/Services/...`
        // leaves a bare `Kiteloop/Services/`, which no corpus holds either, so
        // the elision would be refused under a name the draft never wrote.
        while let last = token.last, ",.;:!".contains(last), !token.hasSuffix("/...") { token.removeLast() }
        if token.hasSuffix("()") { token.removeLast(2) }
        // `Services/Foo.swift:145` names a line in a file, and the file is the
        // part that can be checked. Without this the whole span is looked up as
        // a path, never found, and the item refused — which is how the
        // Coordinator's own filings were rejected en masse on 2026-08-09, since
        // it cites code as file:line by convention.
        if let colon = token.lastIndex(of: ":"),
           token.index(after: colon) < token.endIndex,
           isLineReference(String(token[token.index(after: colon)...])) {
            token = String(token[..<colon])
        }
        guard !token.isEmpty else { return nil }

        if looksLikePath(token) { return Citation(kind: .path, text: token) }
        if looksLikeSymbol(token) { return Citation(kind: .symbol, text: token) }
        return nil
    }

    /// Whether a span is excused from being a claim: the prose before it
    /// carries a creation or absence cue, or the rest of its sentence does and
    /// the cue binds back to it (`isExcused(after:)`). The one question all
    /// three readers of a span — `citations`, `proposedNames`, `proposedPaths` —
    /// ask, so a span excused in one pass is excused in the others.
    package static func isExcused(_ span: BacktickedSpan) -> Bool {
        isProposed(span.prose) || isAbsent(span.prose) || isExcused(after: span.rest)
    }

    /// Creation cues in the words just before a reference. "Add `Foo`" is a
    /// proposal, not a claim, and the draft would be wrong to say `Foo` is
    /// already there. Only the tail of the preceding prose is read, so a cue two
    /// sentences back doesn't excuse an unrelated reference.
    package static func isProposed(_ prose: String) -> Bool {
        cues(in: String(prose.suffix(80)), words: creationCues, phrases: creationPhrases) > 0
    }

    /// Whether a cue *after* a span, in the same sentence, binds back to it.
    ///
    /// The before-window alone judged word order, not meaning: "X creates the
    /// policy file `quality.json`" passed and "the policy file `quality.json`,
    /// which X creates" was refused, and on 2026-09-03 four of five hand-groomed
    /// detail files would have been refused that way. So the rest of the
    /// sentence is read too, with one binding rule — a cue binds *forward* to
    /// the next backticked span in the sentence when there is one, and back to
    /// the span before it only when there is none. "`foo.json` is gone, so
    /// create `bar.json`" has two cues before `bar.json`: the nearer, "create",
    /// is what introduces `bar.json`, and "gone" is left to `foo.json`. A lone
    /// cue between two spans is the second span's, so in "`foo.json`, so create
    /// `bar.json`" nothing excuses `foo.json`. Both cue kinds count the same
    /// way, since either kind excuses a span. The before-window rule is
    /// untouched: this only adds a way to be excused.
    package static func isExcused(after rest: String) -> Bool {
        let sentence = sentenceAfter(rest)
        let stretch = String(sentence.prefix { $0 != "`" })
        let claimedForward = stretch.count < sentence.count ? 1 : 0
        return cues(in: stretch, words: creationCues.union(absenceCues),
                    phrases: creationPhrases + absencePhrases) > claimedForward
    }

    /// The rest of the sentence a span sits in: the line after it, cut at the
    /// first `.`, `?` or `!` outside a backticked span. A newline ends a
    /// sentence by construction — spans are read per line, so `rest` never
    /// holds one. The terminator set is that simple on purpose: nothing in this
    /// check reads sentences otherwise, and an abbreviation like "e.g." or a
    /// bare file name in prose ends the sentence early, which can only refuse
    /// a span, never excuse one.
    package static func sentenceAfter(_ rest: String) -> String {
        var inSpan = false
        return String(rest.prefix { character in
            if character == "`" { inSpan.toggle() }
            return inSpan || !".?!".contains(character)
        })
    }

    /// How many cues a window of prose holds: one per cue word, one per cue
    /// phrase, matched case-insensitively. The before-windows only ask whether
    /// there is one; the after-window has to count, because the last cue before
    /// the next span belongs to that span.
    private static func cues(in window: String, words cueWords: Set<String>, phrases: [String]) -> Int {
        let lowered = window.lowercased()
        let phraseCount = phrases.reduce(0) { count, phrase in
            count + lowered.components(separatedBy: phrase).count - 1
        }
        let wordCount = lowered.split(whereSeparator: { !$0.isLetter })
            .filter { cueWords.contains(String($0)) }.count
        return phraseCount + wordCount
    }

    /// The multi-word creation cues, read whole because no single word in them
    /// is one: "call it `runCloser`" is a proposal, and "call" alone is not.
    private static let creationPhrases = ["name it", "call it", "named it", "called it"]

    /// The uninflected creation cues, first four alphabetically — what a
    /// refusal quotes as its example (`Verdict.summary`). Read off the set so
    /// the message cannot drift from it: a word only ever leaves the message
    /// by leaving `creationCues`.
    package static var sampleCreationCues: [String] {
        Array(creationCues.filter { !$0.hasSuffix("s") && !$0.hasSuffix("ing") }.sorted().prefix(4))
    }

    /// A closed set, deliberately: a pattern over verbs would let unrelated prose
    /// excuse a genuine invention, which is the one thing this check exists to
    /// catch. It stays a list so it can be audited.
    ///
    /// It started at nineteen words, which turned out to be a vocabulary rather
    /// than a rule. `backlog-templates` was refused on 2026-08-11 for citing
    /// `release.md` — the template the item exists to produce — because its
    /// sentence read "Ship one real template", and "ship" was not a word here;
    /// changing it to "Add" made the item runnable with no other edit. The verbs
    /// below are the rest of the ways a groomer writes the same act.
    private static let creationCues: Set<String> = [
        "add", "adds", "adding", "create", "creates", "creating", "new",
        "introduce", "introduces", "introducing", "write", "writes", "writing",
        "rename", "renames", "scaffold", "scaffolds", "generate", "generates",
        "ship", "ships", "shipping", "provide", "provides", "providing",
        "supply", "supplies", "supplying", "include", "includes", "including",
        "publish", "publishes", "publishing", "produce", "produces", "producing",
        "emit", "emits", "emitting", "define", "defines", "defining",
        "declare", "declares", "declaring",
        // Carving a new file out of an existing one is still creating it.
        "extract", "extracts", "extracting", "split", "splits", "splitting",
        // Writing the body of a method the platform calls is creating it here,
        // whoever declared the shape: `finalize-run-records-at-quit` sat parked
        // as a draft whose How read "implement applicationShouldTerminate", an
        // AppKit hook no file in this repo defines yet.
        "implement", "implements", "implementing",
        "override", "overrides", "overriding"
    ]

    /// Absence cues in the words just before a reference — the mirror image of
    /// `isProposed`. "The `docs/old.md` link is gone" is a report that the file
    /// isn't there, not a claim that it is, so a draft whose whole subject is a
    /// missing reference reads the same way a draft proposing a new one does:
    /// forgiven in the sentence that says so, and in every later mention of the
    /// same name or path, the way `docs-link-to-two-documents-that-are-gone`
    /// needed to be to clear this gate at all.
    package static func isAbsent(_ prose: String) -> Bool {
        cues(in: String(prose.suffix(80)), words: absenceCues, phrases: absencePhrases) > 0
    }

    /// The multi-word absence cue, mirroring `creationPhrases`.
    private static let absencePhrases = ["no longer"]

    /// A closed set, deliberately, mirroring `creationCues`: the ways a groomer
    /// writes that something is not there, kept separate from the creation verbs
    /// so a "ship" or "add" never starts excusing a claim about a file that is
    /// gone, and neither list widens by pattern instead of by name.
    private static let absenceCues: Set<String> = [
        "missing", "gone", "removed", "removes", "removing",
        "deleted", "deletes", "deleting", "dangling", "absent"
    ]

    /// Whether what follows a trailing colon is a line reference rather than part
    /// of the name — `14` or a range like `6-14`.
    ///
    /// A single line number was already stripped; a range was not, because the
    /// hyphen fails an all-digits test. So `ci.yml:6-14` was looked up whole,
    /// found missing, and the item refused — which is how correctly groomed
    /// drafts sat parked on 2026-08-10 citing a file that plainly exists.
    package static func isLineReference(_ suffix: String) -> Bool {
        let parts = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Whether a token is one of the closed classes that read as a path — a
    /// slash-bearing token — but can never be one: a media type, a host, a
    /// prose abbreviation, a shell variable assignment. Collected behind one
    /// call so `looksLikePath` gains one branch per new exclusion here rather
    /// than one in the caller, keeping the caller's own complexity flat as the
    /// list of exclusions grows.
    private static func isExcludedFromPathReading(_ token: String) -> Bool {
        looksLikeMIMEType(token) || looksLikeHost(token) || looksLikeProseAbbreviation(token)
            || looksLikeAssignment(token)
    }

    package static func looksLikePath(_ token: String) -> Bool {
        // Only *repo-relative* paths are claims this check can judge. A token
        // rooted at the home directory or at `/` names something outside the
        // repo — a runtime file like `~/.kiteloop/global-config.json`, or an API
        // route like `/v1/coordinator/policy`. Checking those against the repo
        // index reports them missing and refuses a correctly groomed item; that
        // is what happened to the first five items of the global-agent epic on
        // 2026-08-07, every one of which cites the global config by its real
        // runtime path.
        //
        // A leading `@` is the same class of mistake one prefix further on: it
        // starts a package name (`@testing-library/react`) or a bundler alias
        // (`@/lib/api`), neither of which can ever be a file at that path.
        //
        // A URL is the same mistake again, reached from the other end: the
        // slashes in `http://127.0.0.1:4517/v1/backlog` are a scheme and an
        // authority, not directories, and no checkout ever contains that file.
        // On 2026-08-10 `docs-remote-control-tailnet` was refused for citing the
        // loopback address the control API actually listens on.
        if token.hasPrefix("~") || token.hasPrefix("/") || token.hasPrefix("@") { return false }
        if token.contains("://") { return false }
        if isExcludedFromPathReading(token) { return false }
        if token.contains("/") {
            // A span of nothing but dot segments — `./`, `../`, `../../` — names
            // no file: there is no last component for a corpus to hold, so this
            // is uncheckable prose rather than an unresolvable path claim.
            let components = token.split(separator: "/", omittingEmptySubsequences: true)
            if components.allSatisfy({ $0 == "." || $0 == ".." }) { return false }
            // A component that stands in for an elided remainder is the same
            // thing one step on: `Kiteloop/Services/…` names a directory whose
            // rest the draft left out, not a claim that a file sits at that
            // exact path, and no corpus can hold one. Read as a path it
            // resolves nowhere and the item is refused —
            // `runnable-queue-with-an-idle-fleet-reads-as-healthy` was, its
            // recorded reason being that the token is not in the repo or the
            // vault and was read as a claim because it is written as a
            // repo-relative path.
            if components.contains(where: isElision) { return false }
            return true
        }
        let ext = (token as NSString).pathExtension.lowercased()
        return !ext.isEmpty && fileExtensions.contains(ext)
    }

    /// Whether a path component is an elision — the single ellipsis character a
    /// groomer types, or the three periods they type when they don't. Both
    /// spellings say the same thing and neither names a file, in the middle of a
    /// path as much as at the end.
    package static func isElision(_ component: Substring) -> Bool {
        component == "…" || component == "..."
    }

    /// Whether a token is a media type rather than a path — `text/xml`,
    /// `image/svg+xml`, `application/json`.
    ///
    /// A MIME type is written with a slash because that is how MIME types are
    /// written, and it is the *correct* spelling in prose, so the workaround for
    /// a refusal — dropping the backticks — makes the item worse to read. No
    /// checkout will ever hold a file at `text/xml`, so reading one as a repo
    /// claim can only ever refuse a correct citation: on 2026-08-11
    /// `sitemap-served-not-just-200` was unstartable for naming the two content
    /// types a sitemap may be served as.
    ///
    /// Keyed on a closed list of the IANA top-level types, the same shape
    /// `fileExtensions` uses — a list, not a guess about what a slash means. A
    /// file kept under a directory that happens to be named for one of them is
    /// still a path: `image/logo.png` ends in an extension this repo knows, and
    /// only a subtype that does not is a media type.
    package static func looksLikeMIMEType(_ token: String) -> Bool {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, mimeTopLevelTypes.contains(String(parts[0])) else { return false }
        let subtype = String(parts[1])
        guard let initial = subtype.first, initial.isLetter || initial.isNumber else { return false }
        // A subtype is lower-case letters, digits and `+.-` and nothing else, so
        // `text/Foo.swift` — a real file under a real directory — is not one.
        guard subtype.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0.isNumber || "+-.".contains($0) })
        else { return false }
        return !fileExtensions.contains((subtype as NSString).pathExtension)
    }

    /// Whether a token names something on another host rather than in this
    /// checkout — `squareup.com/appointments`, `nebula.wsimg.com/aadc63d8/logo`.
    ///
    /// A scheme already excludes a URL, but prose drops the scheme far more often
    /// than it keeps it, and a project whose whole subject is other people's
    /// websites cites hosts by nature: three of the four items that stalled on
    /// 2026-08-11 were in a website-audit project.
    ///
    /// The signal is not a dot in the first segment — `Kiteloop.xcodeproj/project.pbxproj`
    /// is a real repo path with one. It is a dot followed by a **public suffix**,
    /// from the closed list below, and this repo's own file and bundle extensions
    /// win the tie: `Kiteloop.app/Contents/Info.plist` is a path, not a host in
    /// the `.app` gTLD.
    package static func looksLikeHost(_ token: String) -> Bool {
        guard let first = token.split(separator: "/").first, first.count < token.count else { return false }
        let host = String(first)
        guard let dot = host.lastIndex(of: "."), dot != host.startIndex else { return false }
        // A host label is letters, digits and hyphens; anything else is some
        // other token that merely ends in a word this list happens to hold.
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return false }
        let suffix = String(host[host.index(after: dot)...]).lowercased()
        guard !fileExtensions.contains(suffix), !bundleExtensions.contains(suffix) else { return false }
        return publicSuffixes.contains(suffix)
    }

    /// Whether a token is a prose abbreviation written with a slash rather than
    /// a path — `n/a`, `and/or`, `w/o`, `I/O`, `24/7`.
    ///
    /// A slash in prose is not always a directory separator; some abbreviations
    /// are conventionally written with one, and no checkout will ever hold a
    /// file at any of them. `marathon-scorecard-only-in-prose` was parked for
    /// citing `n/a` in a scorecard cell — a correctly groomed item refused
    /// because its own text happened to spell a word this way.
    ///
    /// Keyed on a closed list, the same shape `looksLikeMIMEType` uses — a list,
    /// not a guess about what a slash means, so nothing here infers from a
    /// token's length or component count. Matched case-insensitively on the
    /// whole token, after the punctuation trimming `classify` already did, so
    /// `N/A` and a trailing `n/a,` or `n/a.` all match the same entry a bare
    /// `n/a` does.
    package static func looksLikeProseAbbreviation(_ token: String) -> Bool {
        proseAbbreviations.contains(token.lowercased())
    }

    /// The closed list `looksLikeProseAbbreviation` matches against. Short and
    /// defensible on purpose: each entry is a phrase a groomer writes in prose,
    /// and none of them is ever the name of a file or a directory this or any
    /// repo could hold.
    private static let proseAbbreviations: Set<String> = [
        "n/a", "and/or", "w/o", "i/o", "24/7"
    ]

    /// Whether a token is a shell variable assignment rather than a path —
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, the search path a spawn is given.
    ///
    /// The `=` sits before the token's first `/`, and everything in front of it
    /// is a shell variable name, so no checkout will ever hold a file at that
    /// path — reading it as a repo claim can only refuse a correct citation.
    /// `signal-sources-spawn-off-the-inherited-path` was parked for exactly
    /// this, its recorded reason being that the assignment it quotes is not in
    /// the repo or the vault and was read as a claim because it is written as
    /// a repo-relative path.
    ///
    /// This is the same reading `executableIndex` already gives a leading
    /// assignment and `isPathArgument` already gives any word holding an `=` —
    /// applied here to the token's *name*, not just the presence of the sign,
    /// so a path that merely contains an `=` after its first slash, or whose
    /// head isn't a variable name, is still read as a path claim.
    package static func looksLikeAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), let slash = token.firstIndex(of: "/"),
              equals < slash
        else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Identifier shape, plus a reason to believe it's code rather than a word:
    /// a case change inside the token, or a dotted member. `ready` and `verify`
    /// are prose in backticks; `phantomToolProvider` and `BacklogAutopilot.start`
    /// are claims.
    package static func looksLikeSymbol(_ token: String) -> Bool {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 1 else { return false }
        for component in components {
            guard let first = component.first, first.isLetter || first == "_" else { return false }
            guard component.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        }
        if components.count > 1 { return true }
        // A capital past the first letter is not enough on its own: every
        // all-capitals word has one, so `DROP` and `GROUP` were looked up as code
        // and reported missing. SQL keywords, HTTP verbs and constants quoted in
        // prose all trip that. A camel hump — a capital *and* a lowercase letter
        // past the first — is what a word in caps can't fake and
        // `phantomToolProvider` has.
        let rest = token.dropFirst()
        return rest.contains { $0.isUppercase } && rest.contains { $0.isLowercase }
    }

    /// The executables a shell command would run: the first word of each
    /// `&&`/`||`/`;`/pipe segment, with builtins dropped — `cd Kiteloop &&
    /// xcodebuild …` is a claim about `xcodebuild`, not about `cd`.
    package static func executableTokens(in command: String) -> [String] {
        topLevelSegments(in: command).compactMap(executableToken(inSegment:))
    }

    /// The program one segment runs, or nil for a builtin, a substitution or a
    /// glob — the per-segment half of `executableTokens`.
    private static func executableToken(inSegment segment: String) -> String? {
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let index = executableIndex(in: words) else { return nil }
        let token = words[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
        guard !token.isEmpty, !shellBuiltins.contains(token) else { return nil }
        // A substitution or glob names no one binary — nothing to check.
        guard !token.contains(where: { "<>*?${}".contains($0) }) else { return nil }
        return token
    }

    /// One executable a `verify:` command runs, with the directory the command
    /// runs it from — what a slashed token like `./scripts/x.sh` is relative to.
    package struct LocatedExecutable: Equatable, Sendable {
        /// Exactly as the command writes it.
        package let text: String
        /// Repo-relative, `""` for the project root, and nil once a `cd` has
        /// gone somewhere this check cannot name.
        package let directory: String?

        package init(text: String, directory: String?) {
            self.text = text
            self.directory = directory
        }
    }

    /// `executableTokens`, each paired with the directory it runs from: the
    /// working directory walks with the segments the way `pathArguments(in:)`
    /// walks it, so `cd Kiteloop && ./scripts/x.sh` runs `Kiteloop/scripts/x.sh`.
    package static func locatedExecutables(in command: String) -> [LocatedExecutable] {
        var found: [LocatedExecutable] = []
        var current: String? = ""
        for segment in topLevelSegments(in: command) {
            if let token = executableToken(inSegment: segment) {
                found.append(LocatedExecutable(text: token, directory: current))
            }
            current = directory(after: segment, from: current)
        }
        return found
    }

    /// Where the shell is after one segment: moved when the segment is a `cd`,
    /// unchanged otherwise.
    private static func directory(after segment: String, from directory: String?) -> String? {
        let words = shellWords(in: segment)
        guard let executable = executableIndex(in: words), words[executable] == "cd" else { return directory }
        return destination(ofCD: Array(words[words.index(after: executable)...]), from: directory)
    }

    /// Which word of a segment names the program it runs.
    ///
    /// Leading `FOO=bar` assignments belong to the next word rather than to it,
    /// and so does `!`: that is the POSIX keyword negating the segment's exit
    /// status, not a program, and it is in no `PATH`. Three correctly written
    /// items were refused for "running" it on 2026-08-11 — `! grep -q …` is the
    /// only way to write "this string must not be present", which is exactly
    /// what a verify for a documentation fix needs.
    ///
    /// Stepped over rather than listed in `shellBuiltins`: a builtin skips the
    /// whole segment, and the program *after* the negation is still a claim this
    /// check is meant to judge — `! gerp -q …` must still be refused.
    package static func executableIndex(in words: [String]) -> Int? {
        words.indices.first { !words[$0].contains("=") && !isShellNegation(words[$0]) }
    }

    /// Whether a word is the shell's negation keyword rather than a program. The
    /// quote and paren trim matches `executableTokens`, so a segment written
    /// `(! grep …)` reads the same way.
    package static func isShellNegation(_ word: String) -> Bool {
        word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()")) == "!"
    }

    /// One path a `verify:` command hands to a program, with the directory the
    /// command will be in by the time it does.
    package struct PathArgument: Equatable, Sendable {
        /// Exactly as the command writes it — what a groomer has to go and edit.
        package let text: String
        /// Repo-relative, and `""` for the project root, which is where a verify
        /// starts: `WorktreeManager.runShell` runs it in the worktree (or the
        /// project) root, not in any subdirectory.
        package let directory: String
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(text: String, directory: String) {
            self.text = text
            self.directory = directory
        }
    }

    /// The paths a command names, each paired with the directory it is written
    /// from — the executables' arguments, which `executableTokens` skips.
    ///
    /// The working directory walks with the segments, so `cd Kiteloop &&
    /// xcodebuild -project Kiteloop.xcodeproj` asks about
    /// `Kiteloop/Kiteloop.xcodeproj` and the same command without the `cd` asks
    /// about `Kiteloop.xcodeproj`. A `cd` this check cannot follow — an absolute
    /// path, a `~`, a command substitution other than the repo root — stops it
    /// reading any later segment rather than guessing where it landed.
    package static func pathArguments(in command: String) -> [PathArgument] {
        var found: [PathArgument] = []
        // Nil once a `cd` leaves for somewhere unnameable.
        var directory: String? = ""

        for segment in topLevelSegments(in: command) {
            let words = shellWords(in: segment)
            // Leading assignments and a leading `!` belong to the next word, as
            // in `executableTokens`; the executable itself is checked there.
            guard let executable = executableIndex(in: words) else { continue }
            if let directory {
                for word in words[words.index(after: executable)...] where isPathArgument(word) {
                    found.append(PathArgument(text: word, directory: directory))
                }
            }
            if words[executable] == "cd" {
                directory = destination(ofCD: Array(words[words.index(after: executable)...]),
                                        from: directory)
            }
        }
        return found
    }

    /// Where a `cd` with these arguments leaves the shell, relative to the repo
    /// root — nil for anywhere this check can't name, which includes every `cd`
    /// made from an already-unknown directory.
    package static func destination(ofCD arguments: [String], from directory: String?) -> String? {
        guard let directory else { return nil }
        // A bare `cd` goes home and `cd -` goes back to wherever the shell was;
        // neither is a directory in this repo.
        guard let target = arguments.first(where: { !$0.hasPrefix("-") }), !target.isEmpty
        else { return nil }
        // The one substitution this check can read: it names the repo root, so
        // the walk restarts there rather than stopping.
        if let below = belowRepoRoot(target) { return resolveRepoPath(below, from: "") }
        // Every other `$(…)`, every backtick and every `~` is resolved by the
        // shell at run time out of anything readable here.
        guard !target.hasPrefix("/"), !target.hasPrefix("~"),
              !target.contains("$"), !target.contains("`") else { return nil }
        return resolveRepoPath(target, from: directory)
    }

    /// The command substitution that names the repo root. `CLAUDE.md` recommends
    /// this spelling for a `verify:` precisely because it is sturdy — it lands in
    /// the same place from any directory — and until it was read here it was also
    /// the one spelling that turned the check off: `destination(ofCD:from:)`
    /// refused every `$`, so a `verify:` in the recommended shape could name any
    /// path at all and ground, while the same mistake written `cd Kiteloop && …`
    /// was caught and named. That is the wrong way round for the form the docs
    /// tell a groomer to write.
    package static let repoRootSubstitution = "$(git rev-parse --show-toplevel)"

    /// The part of a `cd` target that sits below the repo root, or nil when the
    /// target isn't written from it.
    ///
    /// Nothing is executed: `git rev-parse --show-toplevel` prints the root of
    /// the checkout, which is the directory a verify command already starts in,
    /// so the substitution's *value* is known from its text alone. That is true
    /// of no other substitution — `$(dirname …)`, `$(mktemp -d)`, a backtick —
    /// and each of those keeps stopping the walk, which is the conservative
    /// default this file argues for: a missed invention costs one run, and a
    /// wrongly refused item strands real work.
    package static func belowRepoRoot(_ target: String) -> String? {
        guard target.hasPrefix(repoRootSubstitution) else { return nil }
        let rest = target.dropFirst(repoRootSubstitution.count)
        // `…toplevel)-suffix` is some other word that merely starts this way.
        guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        // A second expansion in the remainder puts the destination back out of
        // reach, root or no root.
        guard !rest.contains(where: { $0 == "$" || $0 == "`" }) else { return nil }
        return String(rest.drop(while: { $0 == "/" }))
    }

    /// Whether one word of a command is a path it expects to find.
    ///
    /// Everything that isn't plainly a path is dropped: a flag (whose own value
    /// is the next word, and is judged on its own), an assignment — `-destination
    /// "platform=macOS"` and `--only-testing:Foo` are neither files nor claims —
    /// and anything the shell would rewrite before the program saw it. A path
    /// outside the checkout is left alone too: `/usr/bin`, `~/.kiteloop` and a
    /// URL name things no repo index can answer for.
    package static func isPathArgument(_ word: String) -> Bool {
        guard !word.isEmpty, !word.hasPrefix("-"), !word.contains("=") else { return false }
        guard !word.contains(where: { "$*?{}<>|&()!`".contains($0) }) else { return false }
        guard !word.hasPrefix("~") else { return false }
        return looksLikePath(word) || bundleExtensions.contains((word as NSString).pathExtension.lowercased())
    }

    /// A repo-relative path for `path` written from `directory`, or nil when it
    /// climbs above the repo root — outside everything the index holds.
    package static func resolveRepoPath(_ path: String, from directory: String) -> String? {
        var components = directory.split(separator: "/").map(String.init)
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    /// A segment's words, split where a shell would split them: on whitespace
    /// outside quotes, with the quotes taken off. Splitting on plain whitespace
    /// would read `cd "$(git rev-parse --show-toplevel)/Kiteloop"` as five words
    /// and then judge `rev-parse` as a path argument of `cd`.
    package static func shellWords(in segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var quoted = false
        var escaped = false

        for character in segment {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; quoted = true; continue }
            if character.isWhitespace {
                if !current.isEmpty || quoted { words.append(current) }
                current = ""
                quoted = false
                continue
            }
            current.append(character)
        }
        if !current.isEmpty || quoted { words.append(current) }
        return words
    }

    /// Cut a command at the separators that start a new command — but only at
    /// the ones the shell would, which are the ones outside quotes. Splitting on
    /// every `;` and `|` read the inside of `python3 -c "…; assert x; print('ok')"`
    /// as three programs to run, and refused the item for failing to ground
    /// `assert` and `print('ok` — binaries nobody ever meant to invoke.
    ///
    /// A lone `&` is deliberately not a separator: it would cut `2>&1` in half
    /// and leave `1` looking like an executable.
    package static func topLevelSegments(in command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        let chars = Array(command)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if escaped {
                current.append(c); escaped = false; i += 1; continue
            }
            if c == "\\" {
                current.append(c); escaped = true; i += 1; continue
            }
            if let open = quote {
                if c == open { quote = nil }
                current.append(c); i += 1; continue
            }
            if c == "\"" || c == "'" {
                quote = c; current.append(c); i += 1; continue
            }
            if c == ";" || c == "|" {
                segments.append(current); current = ""
                if c == "|", i + 1 < chars.count, chars[i + 1] == "|" { i += 1 }
                i += 1; continue
            }
            if c == "&", i + 1 < chars.count, chars[i + 1] == "&" {
                segments.append(current); current = ""; i += 2; continue
            }
            current.append(c); i += 1
        }
        segments.append(current)
        return segments
    }

    private static let shellBuiltins: Set<String> = [
        "cd", "echo", "true", "false", "set", "export", "unset", "source", ".", ":",
        "exit", "test", "[", "if", "then", "else", "elif", "fi", "for", "while",
        "do", "done", "read", "eval", "exec", "printf", "return", "shift", "trap",
        "wait", "local", "pushd", "popd"
    ]

    /// Extensions worth treating a dotted token as a file. Deliberately a list
    /// rather than "anything after a dot": `Foo.bar` is a member reference far
    /// more often than it is a filename.
    private static let fileExtensions: Set<String> = [
        "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp", "ts", "tsx", "js", "jsx",
        "py", "rb", "go", "rs", "java", "kt", "sh", "bash", "zsh", "pl", "php",
        "md", "markdown", "txt", "json", "yml", "yaml", "toml", "plist", "xml",
        "html", "css", "scss", "sql", "lock", "cfg", "ini", "entitlements",
        "pbxproj", "xcconfig", "storyboard", "xib", "strings", "png", "jpg", "svg"
    ]

    /// Directories a build is *pointed at*, which count as paths for a command
    /// argument and not for a sentence. `Kiteloop.xcodeproj` is the argument
    /// twelve items got wrong; as a backticked word in prose it is the name of
    /// the project far more often than a claim about a directory, and widening
    /// `fileExtensions` would start judging it there too.
    private static let bundleExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "xcassets", "xctestplan", "playground", "app"
    ]

    /// The IANA top-level media types, all of them. A closed list for the same
    /// reason `fileExtensions` is one: "a word before a slash" would take half of
    /// every repo path with it, while the registry is nine entries long and does
    /// not grow.
    private static let mimeTopLevelTypes: Set<String> = [
        "application", "audio", "font", "image", "message", "model", "multipart",
        "text", "video"
    ]

    /// Suffixes that make the first segment of a token a host rather than a
    /// directory. A sample of the public suffix list, not the whole of it: the
    /// list has thousands of entries and every one added here is a repo path
    /// shape given away, so this holds the suffixes that turn up in the prose of
    /// an audit and stops.
    ///
    /// Deliberately missing: every suffix this repo already reads as a file or a
    /// bundle extension — `app`, `sh`, `md`, `py`, `pl`, `cc`. `looksLikeHost`
    /// gives those to `fileExtensions`/`bundleExtensions` anyway, so listing them
    /// would be dead text suggesting a decision that isn't made here.
    private static let publicSuffixes: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "name",
        "io", "co", "ai", "dev", "xyz", "tech", "cloud", "online", "site",
        "store", "shop", "blog", "news", "tv",
        "uk", "de", "fr", "es", "it", "nl", "se", "no", "fi", "dk", "pt", "ie",
        "ch", "at", "be", "pw", "eu", "ru", "ua", "cn", "jp", "kr", "in", "au",
        "nz", "ca", "us", "mx", "br", "ar", "za", "il", "tr"
    ]

    // MARK: - The live index

    /// A project's `baseBranch`, read as a tree rather than as the checkout.
    package enum BaseTree {
        /// What stands for "the repo" in a check: one index, and — when that
        /// index is the base branch's tree — the checkout's paths beside it.
        package struct Reading: Sendable {
            package let index: SourceIndex
            /// Nil when `index` is the checkout itself.
            package let checkout: SourceIndex?

            /// The checkout still answers for paths, as a corpus of its own:
            /// files git does not track are real there, and this check errs
            /// towards a missed refusal, never a false one.
            package var corpora: [Corpus] {
                let index = index
                var corpora = [Corpus(name: "the repo", contains: { index.containsPath($0) })]
                if let checkout {
                    corpora.append(Corpus(name: "the checkout", contains: { checkout.containsPath($0) }))
                }
                return corpora
            }

            /// A script the base branch tracks is there for the run, which
            /// forks from the base, even when the checkout has no such file.
            package func resolvesExecutable(_ token: String, root: URL, searchDirectories: [String]) -> Bool {
                Executables.resolves(token, root: root, searchDirectories: searchDirectories)
                    || (checkout != nil && BaseTree.tracksScript(token, in: index))
            }
        }

        /// `baseBranch` is the project's own setting. Runs fork from it and land
        /// on it, so when it names a local branch the checkout is not on, that
        /// branch's tree is what gets indexed — otherwise an item about code the
        /// checkout predates is refused as naming nothing, by a check that read
        /// a different tree from the run it gates.
        package static func read(root: URL, baseBranch: String?) -> Reading {
            let base = branchToIndex(root: root, baseBranch: baseBranch).flatMap { index(root: root, branch: $0) }
            guard let base else { return Reading(index: SourceIndex.build(root: root), checkout: nil) }
            return Reading(index: base, checkout: SourceIndex.build(root: root, indexingIdentifiers: false))
        }

        /// The branch to index in place of the checkout: the configured base
        /// when it is a local branch the checkout is not on. Nil otherwise —
        /// none configured, the checkout is already on it, it names no local
        /// branch, or `root` is no git repository — and the checkout is read
        /// exactly as before.
        package static func branchToIndex(root: URL, baseBranch: String?) -> String? {
            guard let base = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else {
                return nil
            }
            let path = root.path(percentEncoded: false)
            let head = SubprocessOutput.git(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
            guard head.status == 0,
                  head.output.trimmingCharacters(in: .whitespacesAndNewlines) != base else { return nil }
            let ref = SubprocessOutput.git(
                ["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/\(base)^{commit}"])
            return ref.status == 0 ? base : nil
        }

        /// The index of `branch`'s tree: archived out of git into a scratch
        /// directory, walked by the same `SourceIndex.build` the checkout is,
        /// and removed. Nil when git or tar refused, so the caller falls back
        /// to the checkout rather than grounding against nothing.
        ///
        /// It writes the whole tree once per index — the price of one walker
        /// for both trees — and only for a project whose base is not checked
        /// out. `scratchParent` is where the scratch directory is made.
        package static func index(root: URL, branch: String,
                                  scratchParent: URL = FileManager.default.temporaryDirectory) -> SourceIndex? {
            let fileManager = FileManager.default
            let scratch = scratchParent.appending(path: "kiteloop-grounding-\(UUID().uuidString)")
            let tree = scratch.appending(path: "tree")
            defer { try? fileManager.removeItem(at: scratch) }
            guard (try? fileManager.createDirectory(at: tree, withIntermediateDirectories: true)) != nil else {
                return nil
            }
            let archive = scratch.appending(path: "tree.tar").path(percentEncoded: false)
            let archived = SubprocessOutput.git(
                ["-C", root.path(percentEncoded: false), "archive", "--format=tar", "-o", archive,
                 "refs/heads/\(branch)"])
            guard archived.status == 0,
                  let unpacked = try? SubprocessOutput.run(
                    executable: "/usr/bin/tar",
                    arguments: ["-xf", archive, "-C", tree.path(percentEncoded: false)]),
                  unpacked.status == 0 else { return nil }
            return SourceIndex.build(root: tree)
        }

        /// Whether `token` — a verify command's executable — is a repo-relative
        /// script the base tree holds. A bare name is not: that is looked up on
        /// the search path, which no branch changes.
        package static func tracksScript(_ token: String, in index: SourceIndex) -> Bool {
            !token.hasPrefix("/") && token.contains("/") && index.containsPath(token)
        }
    }

    /// A snapshot of what's in the repo: every path, and every identifier that
    /// appears in a source file. Built once and queried many times — a per-symbol
    /// grep over the tree would cost a full walk per reference.
    package struct SourceIndex: Sendable {
        /// Last path component → the repo-relative paths carrying it, so a draft
        /// can cite a suffix of the real path.
        package let pathsByName: [String: [String]]
        package let identifiers: Set<String>
        /// Every file-shaped quoted literal the sources construct — the bare
        /// names, since that is how a filename is written in code:
        /// `dir.appending(path: "global-config.json")`. What a repo *writes* is
        /// not what a repo *has*, so these are kept apart from `pathsByName`.
        package let fileLiterals: Set<String>
        /// Every top-level type name this repo's `.swift` sources declare via
        /// `struct`, `class`, `enum`, `actor`, `protocol` or `extension` —
        /// narrower than `identifiers`, which also holds every name a source
        /// merely *uses*. `Bundle` is in `identifiers` because the sources
        /// write `Bundle.main`; it is in here only if the sources declare or
        /// extend a `Bundle` of their own.
        package let declaredTypes: Set<String>
        /// Every GitHub Action a workflow file under `.github/workflows/` names
        /// on a `uses:` line, in both spellings — `actions/upload-artifact@v4`
        /// and the bare `actions/upload-artifact`. Kept apart from `pathsByName`
        /// for the reason `fileLiterals` is: what this repo's CI *runs* is not a
        /// file this repo *has*.
        package let actionReferences: Set<String>

        package func containsPath(_ cited: String) -> Bool {
            let normalized = Self.normalize(cited)
            guard !normalized.isEmpty,
                  let name = normalized.split(separator: "/").last.map(String.init),
                  let candidates = pathsByName[name] else { return false }
            return candidates.contains { $0 == normalized || $0.hasSuffix("/" + normalized) }
        }

        /// One spelling for a cited path. The trailing slash goes because a
        /// directory is indexed under its own name — `docs/` and `docs` are the
        /// same claim, and both resolve.
        package static func normalize(_ path: String) -> String {
            var value = path
            while value.hasPrefix("./") { value.removeFirst(2) }
            while value.hasSuffix("/") { value.removeLast() }
            while value.hasPrefix("/") { value.removeFirst() }
            return value
        }

        /// Walks `root`, recording paths and harvesting identifiers and file
        /// literals from source files. Bounded — an oversized file or a tree
        /// bigger than the byte budget stops contributing either rather than the
        /// walk stalling a run — and blind to the directories a repo generates
        /// rather than writes.
        ///
        /// `indexingIdentifiers: false` walks for paths alone, which is what a
        /// corpus that answers only about files (the vault) needs and costs no
        /// file reads at all. `pathOnlyDirectories` draws the same distinction one
        /// subtree at a time, for a tree that is inside the repo but is not its
        /// sources.
        package static func build(root: URL,
                          indexingIdentifiers: Bool = true,
                          maxFileBytes: Int = 512_000,
                          maxTotalBytes: Int = 32_000_000,
                          fileManager: FileManager = .default) -> SourceIndex {
            var pathsByName: [String: [String]] = [:]
            var identifiers: Set<String> = []
            var fileLiterals: Set<String> = []
            var declaredTypes: Set<String> = []
            var actionReferences: Set<String> = []
            var totalBytes = 0

            // Enumerate by path, not by URL: the path enumerator yields entries
            // already relative to the root, which is what an indexed path is. A
            // URL walk hands back resolved paths (`/private/var/…` for a root
            // given as `/var/…`), and subtracting the root by prefix would then
            // match nothing at all.
            let rootPath = root.path(percentEncoded: false)
            guard let walker = fileManager.enumerator(atPath: rootPath) else {
                return SourceIndex(pathsByName: [:], identifiers: [], fileLiterals: [],
                                   declaredTypes: [], actionReferences: [])
            }

            for case let entry as String in walker {
                let relative = SourceIndex.normalize(entry)
                guard !relative.isEmpty else { continue }
                let name = (relative as NSString).lastPathComponent
                let isDirectory = (walker.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory

                if isDirectory, skippedDirectories.contains(name) {
                    // The tree's *contents* are what pruning is about; the
                    // directory itself is still a path in the repo, and a draft
                    // that cites it is telling the truth. Dropping its entry
                    // alongside its descendants refused `untrack-derived-data`
                    // on 2026-08-11 for citing `.derived/` — a tree with 4,759
                    // tracked files under it. Recorded, then not descended into,
                    // so nothing the tree holds grounds anything.
                    pathsByName[name, default: []].append(relative)
                    walker.skipDescendants()
                    continue
                }
                pathsByName[name, default: []].append(relative)

                let ext = (relative as NSString).pathExtension.lowercased()
                guard indexingIdentifiers, !isDirectory, sourceExtensions.contains(ext),
                      harvestsIdentifiers(from: relative) else { continue }
                let size = (walker.fileAttributes?[.size] as? Int) ?? 0
                guard size <= maxFileBytes, totalBytes + size <= maxTotalBytes else { continue }
                let url = root.appending(path: relative)
                guard let text = (try? Data(contentsOf: url)).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
                totalBytes += size
                collectIdentifiers(from: text, into: &identifiers)
                collectFileLiterals(from: text, into: &fileLiterals)
                // The declaration keywords are Swift's; asking of every
                // `sourceExtensions` file would read `class`/`struct` out of
                // TypeScript and Go sources that happen to share the word.
                if ext == "swift" {
                    collectDeclaredTypes(from: text, into: &declaredTypes)
                }
                // A `uses:` line is a claim about CI wherever it is written, but
                // only a workflow file's is one this repo acts on — so the
                // corpus is that directory rather than every YAML in the tree.
                if isWorkflowFile(relative) {
                    collectActionReferences(from: text, into: &actionReferences)
                }
            }

            return SourceIndex(pathsByName: pathsByName, identifiers: identifiers,
                               fileLiterals: fileLiterals, declaredTypes: declaredTypes,
                               actionReferences: actionReferences)
        }

        /// Every `[A-Za-z_][A-Za-z0-9_]*` run in the text. Crude on purpose: this
        /// answers "is this name written anywhere here", which is all the check
        /// claims to know.
        package static func collectIdentifiers(from text: String, into identifiers: inout Set<String>) {
            var current = ""
            func flush() {
                defer { current = "" }
                guard let first = current.first, first.isLetter || first == "_" else { return }
                identifiers.insert(current)
            }
            for character in text {
                if character.isLetter || character.isNumber || character == "_" {
                    current.append(character)
                } else {
                    flush()
                }
            }
            flush()
        }

        /// A top-level type declaration — anchored at column 0, so a type
        /// nested inside another one is not read as a name this file offers
        /// to the rest of the app. Attributes and modifiers may precede the
        /// keyword (`@MainActor final class Foo`). The same reading
        /// `quality/bin/check-features-map.py`'s `DECLARATION_RE` uses for its own
        /// reachability passes, with `extension` added: extending a platform
        /// type is what makes that type a claim about this code, the same as
        /// declaring one outright.
        private static let declarationPattern: NSRegularExpression? = try? NSRegularExpression(
            pattern: #"^(?:(?:@[\w.]+(?:\([^)\n]*\))?|public|internal|private|fileprivate|open|final)\s+)*"#
                   + #"(?:struct|class|enum|actor|protocol|extension)\s+(\w+)"#,
            options: [.anchorsMatchLines]
        )

        /// Every top-level type name a `.swift` file declares — what
        /// `declaredTypes` is built from.
        package static func collectDeclaredTypes(from text: String, into types: inout Set<String>) {
            guard let declarationPattern else { return }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            declarationPattern.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: text) else { return }
                types.insert(String(text[nameRange]))
            }
        }

        /// Every file-shaped quoted literal in the text — the names the code
        /// itself builds paths out of.
        ///
        /// Read per line and per delimiter, the way `backtickedSpans` reads a
        /// draft: a literal is a span between two quotes of the same kind on one
        /// line. An apostrophe in a comment therefore opens a span that the end
        /// of the line closes, and what it caught has spaces in it and fails the
        /// shape test — so prose costs a missed literal at worst, never a false
        /// one, which is the direction this whole file errs in.
        ///
        /// A literal is not always written bare: `home.appending(path:
        /// ".kiteloop/repo-links.json")` builds a runtime file out of one quoted
        /// literal that already carries its directory. `looksLikeFilename` rejects
        /// the whole span outright — a slash in it makes it a claim about a
        /// directory, which is not what this index is for — so a span with a
        /// slash is retried on its last component alone. Only the last: the
        /// directory part is not a claim this answer has standing to make,
        /// exactly as it isn't for a bare literal.
        package static func collectFileLiterals(from text: String, into literals: inout Set<String>) {
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                for quote in ["\"", "'"] {
                    let parts = line.components(separatedBy: quote)
                    // As in `backtickedSpans`: only indices 1..<n-1 sit between a
                    // pair, so an unclosed quote contributes nothing.
                    guard parts.count >= 3 else { continue }
                    for index in stride(from: 1, to: parts.count - 1, by: 2) {
                        let literal = parts[index]
                        if looksLikeFilename(literal) {
                            literals.insert(literal)
                        } else if let name = literal.split(separator: "/").last,
                                  literal.contains("/"), looksLikeFilename(String(name)) {
                            literals.insert(String(name))
                        }
                    }
                }
            }
        }

        /// Whether a path is one of this repo's GitHub Actions workflow files —
        /// the only files whose `uses:` lines answer for an action reference.
        /// Asked of a normalized, repo-relative path, so the prefix is exact.
        package static func isWorkflowFile(_ relative: String) -> Bool {
            guard relative.hasPrefix(".github/workflows/") else { return false }
            let ext = (relative as NSString).pathExtension.lowercased()
            return ext == "yml" || ext == "yaml"
        }

        /// Every action a workflow file's `uses:` lines name, in both the
        /// spellings a draft writes it in: the pinned `owner/name@ref` and the
        /// bare `owner/name` before the `@`.
        ///
        /// Read per line rather than parsed as YAML, the way `collectFileLiterals`
        /// reads a source: a `uses:` is a leaf value on its own line, optionally
        /// opening a list item, and everything this index needs is to its right.
        ///
        /// A local action (`./.github/actions/setup`) and a container
        /// (`docker://alpine:3`) are left out. Neither is what this answer is
        /// for: the first is a real path the walk already indexed, and the
        /// second is excluded from being read as a path at all.
        package static func collectActionReferences(from text: String, into references: inout Set<String>) {
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("-") {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                guard line.hasPrefix("uses:") else { continue }
                var value = String(line.dropFirst("uses:".count))
                if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
                value = value.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard value.contains("/"), !value.hasPrefix("."), !value.contains("://") else { continue }
                references.insert(value)
                if let at = value.firstIndex(of: "@"), at != value.startIndex {
                    references.insert(String(value[..<at]))
                }
            }
        }

        /// Whether a literal is a filename the code is assembling a path out of:
        /// letters, digits, dot, dash and underscore, no slash, and an extension.
        ///
        /// A slash would make it a path fragment — a claim about a directory this
        /// answer has no standing to make — and the names in question are written
        /// bare anyway (`appending(path: "daily-spend.json")`). The extension is
        /// asked for by shape rather than against `fileExtensions`: the app writes
        /// `control-runs.jsonl`, which that list does not hold and should not, and
        /// a suffix of letters and digits starting with a letter already excludes
        /// the literals a source is thick with — a version, a `127.0.0.1`, a
        /// number.
        package static func looksLikeFilename(_ literal: String) -> Bool {
            guard !literal.isEmpty, literal.count <= 128 else { return false }
            guard literal.allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
            }) else { return false }
            // A dot at the start is a leading-dot name (`.gitignore`), not an
            // extension, and one at the end names nothing.
            guard let dot = literal.lastIndex(of: "."), dot != literal.startIndex else { return false }
            let ext = literal[literal.index(after: dot)...]
            guard (1...8).contains(ext.count), let initial = ext.first, initial.isLetter,
                  ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
            return true
        }

        /// What a repo builds, vendors or checks out rather than writes. Kiteloop's
        /// own `.kiteloop/worktrees` is in here for a specific reason: it holds
        /// whole copies of the repo, and indexing them would multiply the walk by
        /// the number of runs in flight.
        ///
        /// Two different derived trees, and only one of them was covered.
        /// `DerivedData` is the leaf `WorktreeBuildOutput.derivedDataDirectory`
        /// builds a worktree run into — gitignored, disposable, already skipped.
        /// `.derived` is the tree the repo root keeps: several hundred megabytes,
        /// *tracked*, so every worktree gets a full checkout of it too. Leaving it
        /// out meant all of it was stat-walked on every pickup and every grooming
        /// pass, with the artefacts landing in `pathsByName` where a cited
        /// filename could suffix-match one. Nothing should ever cite build output,
        /// so the tree is pruned rather than filtered afterwards.
        package static let skippedDirectories: Set<String> = [
            ".git", ".build", ".swiftpm", "build", "DerivedData", ".derived",
            "node_modules", "Pods", "Carthage", "xcuserdata", "worktrees", "logs",
            "sessions", "traces", ".venv", "venv", "__pycache__", ".next", "dist",
            "target", ".gradle", "vendor"
        ]

        /// Subtrees the index reads for paths and never for contents — neither
        /// identifiers nor file literals — the same split
        /// `indexingIdentifiers: false` makes for the vault, applied inside a
        /// repo.
        ///
        /// `.kiteloop` is the app's own runtime state, not this repo's sources,
        /// and the two halves have to be treated differently. Its paths are real
        /// and drafts legitimately cite them (`.kiteloop/team.json`,
        /// `.kiteloop/autopilot-config.json`), so the walk keeps them. Its
        /// *contents* are the check's own output fed back to it: checkpoints are
        /// JSON, `sourceExtensions` lists json, and each one embeds the item's own
        /// What/How/Validation prose — so every word an agent wrote about a draft
        /// became an identifier, and the very invention this check exists to catch
        /// grounded itself the moment one run checkpointed. A checkpoint's quoted
        /// values are the same hazard read the other way — a JSON string that is
        /// nothing but a filename is file-shaped — so the literals are gathered
        /// behind this guard too.
        package static let pathOnlyDirectories: Set<String> = [".kiteloop"]

        /// Whether a file's contents count as sources — for identifiers and for
        /// file literals alike. False inside a `pathOnlyDirectories` subtree; the
        /// file's own name is not a directory, so it is not consulted.
        package static func harvestsIdentifiers(from relative: String) -> Bool {
            !relative.split(separator: "/").dropLast()
                .contains { pathOnlyDirectories.contains(String($0)) }
        }

        /// Files whose contents count as "the sources". Markdown is not among
        /// them on purpose: a symbol that appears only in a backlog file or a doc
        /// is exactly the invention this check exists to catch.
        package static let sourceExtensions: Set<String> = [
            "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp", "ts", "tsx", "js",
            "jsx", "py", "rb", "go", "rs", "java", "kt", "sh", "bash", "zsh",
            "json", "yml", "yaml", "toml", "plist", "entitlements", "pbxproj",
            "xcconfig", "gradle", "cfg", "ini", "sql"
        ]
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(pathsByName: [String: [String]], identifiers: Set<String>, fileLiterals: Set<String>, declaredTypes: Set<String>, actionReferences: Set<String>) {
            self.pathsByName = pathsByName
            self.identifiers = identifiers
            self.fileLiterals = fileLiterals
            self.declaredTypes = declaredTypes
            self.actionReferences = actionReferences
        }
    }

    /// Does a command name something runnable? Answered against the app's one
    /// executable search policy (`ExecutableSearchPath`), handed in as a
    /// directory list rather than read from `ProcessInfo`: a GUI app inherits a
    /// thin `PATH`, and the list this used to build for itself had no
    /// `~/.cargo/bin` in it — which is how a `cargo` verify was refused at
    /// grooming on 2026-09-03 on a machine that had cargo.
    package enum Executables {
        package static func resolves(_ token: String, root: URL,
                                     fileManager: FileManager = .default,
                                     searchDirectories: [String]) -> Bool {
            resolvedPath(token, root: root, fileManager: fileManager,
                         searchDirectories: searchDirectories) != nil
        }

        /// Where `token` resolves to — an absolute path — or nil when it names
        /// nothing runnable. An absolute token is taken as it stands, a token
        /// with a slash is relative to `root`, and a bare name is looked up in
        /// `searchDirectories` in order, then in `root` itself.
        package static func resolvedPath(_ token: String, root: URL,
                                         fileManager: FileManager = .default,
                                         searchDirectories: [String]) -> String? {
            if token.hasPrefix("/") { return fileManager.isExecutableFile(atPath: token) ? token : nil }
            if token.contains("/") {
                let path = root.appending(path: SourceIndex.normalize(token)).path(percentEncoded: false)
                return fileManager.isExecutableFile(atPath: path) ? path : nil
            }
            for directory in searchDirectories where fileManager.isExecutableFile(atPath: directory + "/" + token) {
                return directory + "/" + token
            }
            let inRoot = root.appending(path: token).path(percentEncoded: false)
            return fileManager.isExecutableFile(atPath: inRoot) ? inRoot : nil
        }

        /// The searched directories as one line for a refusal note, so the
        /// operator reads *where* the app looked rather than only that it
        /// failed — `PATH` is the usual answer, and it is not this app's `PATH`.
        /// Cut past `limit` characters with a count of what was left off.
        package static func searchedDescription(_ directories: [String], limit: Int = 200) -> String {
            guard !directories.isEmpty else { return "no directory was searched" }
            var kept: [String] = []
            var length = 0
            for directory in directories {
                length += directory.count + 1
                guard length <= limit else { break }
                kept.append(directory)
            }
            let omitted = directories.count - kept.count
            let suffix = omitted > 0 ? " and \(omitted) more" : ""
            return "searched " + kept.joined(separator: ":") + suffix
        }
    }
}
