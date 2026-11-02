import XCTest
@testable import KiteloopCore

/// Behaviours of the grounding check that a mutation pass showed no test was
/// pinning: the shell-reading edges (escapes, empty quoted words, `||`, a
/// trailing separator), the token-shape rules at their boundaries (hosts with
/// hyphens, Swift dot-shorthand, underscore-prefixed members), the index's
/// byte and length budgets at their exact edges, and the paths the check hands
/// to the filesystem written without percent-encoding. Each test asserts a
/// behaviour a draft or a repo can actually exhibit.
final class GroundingCheckHardeningTests: XCTestCase {

    // MARK: - A Sources built from just pathExists still refuses inventions

    /// The convenience init leaves `constructsFile` and `usesAction` answering
    /// "no" — a caller that only knows what paths exist must not have its
    /// missing paths quietly grounded by the defaults.
    func testASourcesBuiltFromJustPathExistsRefusesAMissingPath() {
        let sources = GroundingCheck.Sources(
            pathExists: { _ in false },
            definesSymbol: { _ in false },
            resolvesExecutable: { _ in true })
        let item = BacklogItem(id: "hardening", title: "Fix `Services/Nope.swift` parsing",
                               verify: nil, status: .ready, type: .local, size: .m,
                               detailPath: "backlog/hardening.md")

        let verdict = GroundingCheck.evaluate(item: item, detail: nil, sources: sources)

        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["Services/Nope.swift"])
    }

    // MARK: - Sibling corpora

    private func makeSiblingCorpus() throws -> GroundingCheck.Corpus {
        let temporary = try makeTemporaryDirectory(prefix: "grounding-hardening-portfolio")
        let vault = temporary.appending(path: "vault")
        let here = temporary.appending(path: "kiteloop")
        let sibling = temporary.appending(path: "aurora")
        let fm = FileManager.default
        try fm.createDirectory(at: vault.appending(path: "Logs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: here, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)

        try "# Überblick\n".write(to: sibling.appending(path: "Übersicht.md"),
                                  atomically: true, encoding: .utf8)
        try """
        projects:
          aurora:
            name: Aurora
            backlog: Projects/aurora/Backlog.md
            repo: \(sibling.path(percentEncoded: false))
        """.write(to: vault.appending(path: "Logs/registry.yaml"), atomically: true, encoding: .utf8)

        return try XCTUnwrap(
            GroundingCheck.Sources.siblingCorpora(vault: vault, excluding: here).first)
    }

    /// A sibling's file with a non-ASCII name is the same claim as any other —
    /// the corpus asks the filesystem for the literal name, not a
    /// percent-encoded spelling of it.
    func testASiblingFileWithANonASCIINameStillGrounds() throws {
        let aurora = try makeSiblingCorpus()
        XCTAssertTrue(aurora.contains("Übersicht.md"))
    }

    /// A citation that names nothing — `./`, a bare slash — must never ground
    /// in a sibling: with no relative path to append, the check would otherwise
    /// be asking whether the sibling's root exists, which it always does.
    func testACitationThatNamesNothingNeverGroundsInASibling() throws {
        let aurora = try makeSiblingCorpus()
        XCTAssertFalse(aurora.contains("./"))
        XCTAssertFalse(aurora.contains("/"))
    }

    /// One byte that is not UTF-8 in an unrelated line of the registry must not
    /// drop every sibling — the listed project still gets its corpus.
    func testASiblingSurvivesABadByteInTheRegistry() throws {
        let temporary = try makeTemporaryDirectory(prefix: "grounding-hardening-bad-byte")
        let vault = temporary.appending(path: "vault")
        let here = temporary.appending(path: "kiteloop")
        let sibling = temporary.appending(path: "aurora")
        let fm = FileManager.default
        try fm.createDirectory(at: vault.appending(path: "Logs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: here, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)

        var data = Data("# notes ".utf8)
        data.append(0xFF)
        data.append(Data("""

        projects:
          aurora:
            name: Aurora
            backlog: Projects/aurora/Backlog.md
            repo: \(sibling.path(percentEncoded: false))
        """.utf8))
        try data.write(to: vault.appending(path: "Logs/registry.yaml"))

        let corpora = GroundingCheck.Sources.siblingCorpora(vault: vault, excluding: here)
        XCTAssertEqual(corpora.map(\.name), ["the Aurora project"])
    }

    /// One spelling for a directory: literal characters (a registry entry may
    /// name `~/My Projects/foo`), and the filesystem root left as `/` rather
    /// than trimmed to nothing.
    func testCanonicalDirectoryKeepsSpacesLiteralAndLeavesTheRootAlone() throws {
        let base = try makeTemporaryDirectory(prefix: "grounding-hardening-canonical")
        let spaced = base.appending(path: "My Projects")
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)

        let canonical = GroundingCheck.Sources.canonicalDirectory(spaced)
        XCTAssertTrue(canonical.hasSuffix("/My Projects"), canonical)

        XCTAssertEqual(GroundingCheck.Sources.canonicalDirectory(URL(fileURLWithPath: "/")), "/")
    }

    // MARK: - The proposal pass

    /// A citation that names nothing is never one of the files or names a
    /// draft introduced — degenerate spellings fall out before any suffix
    /// matching could accidentally forgive them.
    func testDegenerateCitationsAreNeverProposed() {
        XCTAssertFalse(GroundingCheck.isProposed(path: "./", among: ["scripts/check.sh"]))
        XCTAssertFalse(GroundingCheck.isProposed(path: "", among: ["scripts/check.sh"]))
        XCTAssertFalse(GroundingCheck.isProposed(".", among: ["Foo"]))
        XCTAssertFalse(GroundingCheck.isProposed("", among: ["Foo"]))
    }

    /// "name it `x`" and "call it `x`" are how a groomer introduces a name
    /// without any of the creation verbs — the phrases excuse the reference on
    /// their own.
    func testNameItAndCallItPhrasesExcuseTheIntroducedName() {
        XCTAssertTrue(GroundingCheck.isProposed("there should be a run closer; call it "))
        XCTAssertTrue(GroundingCheck.isProposed("a tiny helper — name it "))

        let names = GroundingCheck.proposedNames(
            in: "There should be a run closer; call it `runRecordCloser`.")
        XCTAssertTrue(names.contains("runRecordCloser"), "\(names)")
    }

    /// "no longer" is the one two-word absence phrase, the mirror image of
    /// "name it"/"call it" — it excuses the reference on its own, with no
    /// single-word cue anywhere in the window.
    func testNoLongerPhraseExcusesTheGoneReference() {
        XCTAssertTrue(GroundingCheck.isAbsent("the guide is no longer "))

        let paths = GroundingCheck.proposedPaths(
            in: "The migration guide is no longer accurate: `docs/removed-guide.md`.")
        XCTAssertTrue(paths.contains("docs/removed-guide.md"), "\(paths)")
    }

    /// A citation that names nothing is never excused by absence either —
    /// degenerate spellings fall out before the cue is even consulted, the
    /// same guard `testDegenerateCitationsAreNeverProposed` pins for creation.
    func testDegenerateCitationsAreNeverExcusedByAbsence() {
        XCTAssertFalse(GroundingCheck.isProposed(path: "./", among: ["docs/removed-guide.md"]))
        XCTAssertEqual(GroundingCheck.proposedPaths(in: "Gone: `./` from the tree."), [])
    }

    // MARK: - Token shapes

    /// A line reference is `14` or `6-14` and nothing else: a dangling range, a
    /// third part, or letters make the suffix part of the name again.
    func testOnlyANumberOrANumberRangeIsALineReference() {
        XCTAssertTrue(GroundingCheck.isLineReference("14"))
        XCTAssertTrue(GroundingCheck.isLineReference("6-14"))
        XCTAssertFalse(GroundingCheck.isLineReference("6-"))
        XCTAssertFalse(GroundingCheck.isLineReference("1-2-3"))
        XCTAssertFalse(GroundingCheck.isLineReference("14a"))
    }

    /// A media type is exactly two labels, and the subtype is lower-case: a
    /// doubled slash, an empty or dot-led subtype, and a capitalised name
    /// under a type-named directory are all paths (or nothing), never MIME.
    func testAMediaTypeIsExactlyTwoWellFormedLowercaseLabels() {
        XCTAssertTrue(GroundingCheck.looksLikeMIMEType("application/json"))
        XCTAssertTrue(GroundingCheck.looksLikeMIMEType("image/svg+xml"))
        XCTAssertFalse(GroundingCheck.looksLikeMIMEType("text//plain"))
        XCTAssertFalse(GroundingCheck.looksLikeMIMEType("text/"))
        XCTAssertFalse(GroundingCheck.looksLikeMIMEType("image/.hidden"))
        XCTAssertFalse(GroundingCheck.looksLikeMIMEType("text/README"))
    }

    /// A host label is letters, digits and hyphens — `my-store.com` is a host,
    /// and a first segment carrying an underscore is some other token that
    /// merely ends in a word the suffix list happens to hold.
    func testHostLabelsMayCarryHyphensAndNothingElse() {
        XCTAssertTrue(GroundingCheck.looksLikeHost("my-store.com/products"))
        XCTAssertFalse(GroundingCheck.looksLikeHost("run_logs.tv/schedule"))
    }

    /// Swift's enum dot-shorthand (`.userInitiated`) roots in nothing and is
    /// prose; an underscore-prefixed member and a digit-bearing camel name are
    /// exactly the identifiers this repo writes.
    func testDotShorthandUnderscoresAndDigitsReadCorrectlyAsSymbols() {
        XCTAssertFalse(GroundingCheck.looksLikeSymbol(".userInitiated"))
        XCTAssertFalse(GroundingCheck.looksLikeSymbol("foo..bar"))
        XCTAssertTrue(GroundingCheck.looksLikeSymbol("_cachedValue"))
        XCTAssertTrue(GroundingCheck.looksLikeSymbol("utf8Decoder"))
    }

    // MARK: - Reading a verify command

    /// What sits below the repo-root substitution comes back repo-relative —
    /// no leading slash — which is the spelling every other path rule speaks.
    func testBelowRepoRootReturnsARepoRelativePathWithoutALeadingSlash() {
        XCTAssertEqual(
            GroundingCheck.belowRepoRoot("$(git rev-parse --show-toplevel)/Kiteloop"), "Kiteloop")
        XCTAssertEqual(
            GroundingCheck.belowRepoRoot("$(git rev-parse --show-toplevel)"), "")
    }

    /// A backslash escapes exactly one character: `a\ b` is one word, and the
    /// escape does not bleed into the characters after it.
    func testShellWordsHonorBackslashEscapes() {
        XCTAssertEqual(GroundingCheck.shellWords(in: #"touch a\ b c"#), ["touch", "a b", "c"])
    }

    /// `''` is a word to the shell — dropping it would shift every argument
    /// after it one position left.
    func testAnEmptyQuotedStringIsStillAWord() {
        XCTAssertEqual(GroundingCheck.shellWords(in: "grep '' notes.md"), ["grep", "", "notes.md"])
    }

    /// A run of spaces is one split, not a word per space.
    func testRunsOfWhitespaceInventNoWords() {
        XCTAssertEqual(GroundingCheck.shellWords(in: "ls  -la  docs"), ["ls", "-la", "docs"])
    }

    /// A command that opens with a quoted argument keeps its separators
    /// inside the quotes, same as a quote anywhere else in the command.
    func testALeadingQuotedArgumentKeepsItsSeparatorsInside() {
        XCTAssertEqual(GroundingCheck.topLevelSegments(in: #""a;b" c"#), [#""a;b" c"#])
    }

    /// `\;` is an escaped semicolon — an argument, not a separator; the
    /// unescaped one after it still splits.
    func testAnEscapedSemicolonDoesNotStartANewCommand() {
        XCTAssertEqual(GroundingCheck.topLevelSegments(in: #"echo a\;b; ls"#),
                       [#"echo a\;b"#, " ls"])
    }

    /// `||` is one separator, not two — a doubled bar must not leave an empty
    /// phantom segment between its halves.
    func testDoubleBarIsOneSeparatorNotTwo() {
        XCTAssertEqual(GroundingCheck.topLevelSegments(in: "x || y"), ["x ", " y"])
    }

    /// A separator as the command's last character — a trailing pipe, a
    /// backgrounding `&` — is malformed or harmless, and must never read past
    /// the end of the command.
    func testATrailingSeparatorDoesNotReadPastTheCommand() {
        XCTAssertEqual(GroundingCheck.topLevelSegments(in: "cat notes.md |"), ["cat notes.md ", ""])
        XCTAssertEqual(GroundingCheck.topLevelSegments(in: "sleep 1 &"), ["sleep 1 &"])
    }

    /// `2>&1` stays in its segment — cutting it at the `&` leaves `1` looking
    /// like an executable, the exact failure the segment rules exist to avoid.
    func testStderrRedirectionStaysInOneSegment() {
        XCTAssertEqual(GroundingCheck.topLevelSegments(in: "swift test 2>&1"), ["swift test 2>&1"])
    }

    // MARK: - The index's budgets, at their edges

    /// A file exactly at the byte budgets is still read: the caps are
    /// inclusive, so tightening them by one byte is a decision, not a drift.
    func testAFileExactlyAtTheByteBudgetIsStillIndexed() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-hardening-budget")
        let body = "let budgetEdgeMarker = 1\n"
        try body.write(to: root.appending(path: "Marker.swift"), atomically: true, encoding: .utf8)
        let size = body.utf8.count

        let index = GroundingCheck.SourceIndex.build(root: root,
                                                     maxFileBytes: size, maxTotalBytes: size)

        XCTAssertTrue(index.identifiers.contains("budgetEdgeMarker"), "\(index.identifiers.count)")
    }

    /// A repo rooted at a path with a space — `~/Documents/My Projects/…` is a
    /// normal macOS location — still indexes: the walk asks the filesystem for
    /// the literal path, never a percent-encoded spelling of it.
    func testARepoRootedAtAPathWithASpaceStillIndexes() throws {
        let base = try makeTemporaryDirectory(prefix: "grounding-hardening-spaced-root")
        let root = base.appending(path: "My Repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "let spacedRootMarker = 1\n".write(to: root.appending(path: "Marker.swift"),
                                               atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)

        XCTAssertTrue(index.containsPath("Marker.swift"))
        XCTAssertTrue(index.identifiers.contains("spacedRootMarker"))
    }

    /// A source file with one byte that is not UTF-8 still grounds the symbols
    /// on either side of it: a draft right about the code is not refused
    /// because one character in the cited file was cut off.
    func testASourceFileWithOneBadByteStillGivesUpItsSymbols() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-hardening-bad-byte")
        var data = Data("struct BadByteDeclaredMarker {}\n// ".utf8)
        data.append(0xFF)
        data.append(Data("\nlet afterBadByteMarker = 1\n".utf8))
        try data.write(to: root.appending(path: "Marker.swift"))

        let index = GroundingCheck.SourceIndex.build(root: root)

        XCTAssertTrue(index.identifiers.contains("BadByteDeclaredMarker"))
        XCTAssertTrue(index.identifiers.contains("afterBadByteMarker"))
        XCTAssertTrue(index.declaredTypes.contains("BadByteDeclaredMarker"))
    }

    /// A source file that cannot be read at all — here a link to nothing —
    /// contributes no symbols and does not stop the walk over its neighbours.
    func testAnUnreadableSourceFileContributesNothingAndTheWalkGoesOn() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-hardening-unreadable")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Dangling.swift"),
            withDestinationURL: root.appending(path: "Missing.swift"))
        try "let readableNeighbourMarker = 1\n".write(to: root.appending(path: "Neighbour.swift"),
                                                  atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)

        XCTAssertTrue(index.containsPath("Dangling.swift"))
        XCTAssertTrue(index.identifiers.contains("readableNeighbourMarker"))
        XCTAssertFalse(index.identifiers.contains("Dangling"))
    }

    /// Swift writes `_cachedValue` and `utf8Count`; both are identifiers the
    /// index must hold whole.
    func testIdentifiersKeepTheirUnderscorePrefixesAndDigits() {
        var identifiers: Set<String> = []
        GroundingCheck.SourceIndex.collectIdentifiers(
            from: "let _cachedValue = utf8Count", into: &identifiers)

        XCTAssertTrue(identifiers.contains("_cachedValue"), "\(identifiers)")
        XCTAssertTrue(identifiers.contains("utf8Count"), "\(identifiers)")
        XCTAssertFalse(identifiers.contains("8"))
    }

    /// Workflows are written in both YAML spellings; nothing else under the
    /// workflows directory — and no YAML outside it — answers for actions.
    func testBothYAMLSpellingsAreWorkflowFilesAndNothingElseIs() {
        XCTAssertTrue(GroundingCheck.SourceIndex.isWorkflowFile(".github/workflows/ci.yml"))
        XCTAssertTrue(GroundingCheck.SourceIndex.isWorkflowFile(".github/workflows/release.yaml"))
        XCTAssertFalse(GroundingCheck.SourceIndex.isWorkflowFile(".github/workflows/README.md"))
        XCTAssertFalse(GroundingCheck.SourceIndex.isWorkflowFile("docs/ci.yml"))
    }

    /// The 128-character cap on a file literal is inclusive at the boundary.
    func testAFilenameExactlyAtTheLengthCapIsStillFileShaped() {
        let name = String(repeating: "a", count: 123) + ".json"
        XCTAssertEqual(name.count, 128)
        XCTAssertTrue(GroundingCheck.SourceIndex.looksLikeFilename(name))
        XCTAssertFalse(GroundingCheck.SourceIndex.looksLikeFilename("a" + name))
    }

    // MARK: - Resolving executables

    /// A repo-relative or bare executable with a non-ASCII name resolves — the
    /// filesystem is asked for the literal name, never a percent-encoded
    /// spelling of it.
    func testAnExecutableWithANonASCIINameResolves() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-hardening-exec")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "tools"), withIntermediateDirectories: true)
        for relative in ["tools/prüfen.sh", "prüfen"] {
            let url = root.appending(path: relative)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755],
                                 ofItemAtPath: url.path(percentEncoded: false))
        }

        XCTAssertTrue(GroundingCheck.Executables.resolves("tools/prüfen.sh", root: root,
                                                          searchDirectories: []))
        XCTAssertTrue(GroundingCheck.Executables.resolves("prüfen", root: root, searchDirectories: []))
    }
}
