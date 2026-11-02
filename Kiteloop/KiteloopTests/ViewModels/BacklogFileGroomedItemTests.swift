import XCTest
import KiteloopCore
@testable import Kiteloop

/// `BacklogViewModel.fileGroomedItem` — the write the coordinator's refill loop
/// files through. It touches two files at once (`BACKLOG.md` and
/// `backlog/<id>.md`) on behalf of something that files in a loop with no human
/// watching, so these go to disk and read back rather than trusting the
/// in-memory model.
@MainActor
final class BacklogFileGroomedItemTests: XCTestCase {

    private var tempDir: URL!
    private var backlog: BacklogViewModel!

    private let detailMarkdown = """
    ---
    id: refill-one
    title: Summarise the backlog
    size: S
    verify:
      - name: verify
        cmd: "/bin/echo ok"
    ---

    ## What

    The file gains a summary line.

    ## How

    Emit the counts above the first section.

    ## Validation

    - [ ] The summary line reports the open count

    ## Out of Scope

    - Changing the item syntax
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "file-groomed")
        try "# Backlog\n\n## Now\n\n- [ ] existing | Already here | ready\n"
            .write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

        backlog = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
    }

    override func tearDownWithError() throws {
        backlog = nil
    }

    @discardableResult
    private func file(id: String = "refill-one",
                      section: String = "Now",
                      status: BacklogItemStatus = .ready,
                      from: String? = nil,
                      needs: [String] = []) -> BacklogViewModel.FilingOutcome {
        backlog.fileGroomedItem(sectionName: section, id: id, title: "Summarise the backlog",
                                size: .s, verify: "/bin/echo ok", status: status,
                                from: from, needs: needs, detailMarkdown: detailMarkdown)
    }

    // MARK: - The happy path

    func testFilingWritesTheLineTheDetailAndTheLinkBetweenThem() throws {
        XCTAssertEqual(file(), .filed)

        let item = try XCTUnwrap(backlog.backlogFile?.sections.flatMap(\.items).first { $0.id == "refill-one" })
        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(item.size, .s)
        XCTAssertEqual(item.verify, "/bin/echo ok")
        XCTAssertEqual(item.detailPath, "backlog/refill-one.md")

        let onDisk = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("refill-one"), onDisk)
        XCTAssertTrue(onDisk.contains("existing"), "filing must not drop what was already there")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appending(path: "backlog/refill-one.md").path(percentEncoded: false)))
    }

    /// The whole point of writing both files: what comes back off disk has to
    /// satisfy the gate autopilot applies at pickup.
    func testAFiledItemReadsBackAsReadyByTheDefinitionOfReady() throws {
        XCTAssertEqual(file(), .filed)
        backlog.reload()

        let item = try XCTUnwrap(backlog.backlogFile?.sections.flatMap(\.items).first { $0.id == "refill-one" })
        let detail = try XCTUnwrap(backlog.loadDetail(for: item))
        XCTAssertEqual(detail.what?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "The file gains a summary line.")
        let verdict = DefinitionOfReady.evaluate(item: item, detail: detail)
        XCTAssertTrue(verdict.isReady, verdict.summary)
    }

    /// A gated draft is filed too — as `draft`, which is a status autopilot's
    /// queue never picks up. The status the caller asks for is the gate's
    /// verdict, so it must not be overridden by the project's new-item flow.
    func testTheRequestedStatusWinsOverTheProjectFlowDefault() throws {
        XCTAssertEqual(file(id: "parked", status: .draft), .filed)
        let item = try XCTUnwrap(backlog.backlogFile?.sections.flatMap(\.items).first { $0.id == "parked" })
        XCTAssertEqual(item.status, .draft)
    }

    // MARK: - Provenance

    /// An item the coordinator split out of another one says so on its line, and
    /// keeps saying so once the file has been read back off disk — which is the
    /// only way anything else can group children under the item they came from.
    func testFilingStampsWhereTheItemCameFrom() throws {
        XCTAssertEqual(file(id: "split-child", from: "existing"), .filed)

        let onDisk = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("from:existing"), onDisk)

        backlog.reload()
        let item = try XCTUnwrap(backlog.backlogFile?.sections.flatMap(\.items).first { $0.id == "split-child" })
        XCTAssertEqual(item.from, "existing")
    }

    /// Lineage is a record, not a constraint: the item is picked up on exactly
    /// the same terms as one that came from nowhere in particular.
    func testProvenanceDoesNotChangeWhetherTheItemIsReady() throws {
        XCTAssertEqual(file(id: "with-parent", from: "existing"), .filed)
        XCTAssertEqual(file(id: "no-parent"), .filed)
        backlog.reload()

        for id in ["with-parent", "no-parent"] {
            let item = try XCTUnwrap(backlog.backlogFile?.sections.flatMap(\.items).first { $0.id == id })
            let verdict = DefinitionOfReady.evaluate(item: item, detail: backlog.loadDetail(for: item))
            XCTAssertTrue(verdict.isReady, "\(id): \(verdict.summary)")
        }
    }

    /// Most work comes out of reading the code rather than out of another item,
    /// so the token has to be absent — not empty — when there is no parent.
    func testFilingWithoutAParentWritesNoProvenanceToken() throws {
        XCTAssertEqual(file(), .filed)
        let onDisk = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("from:"), onDisk)
    }

    // MARK: - Sequencing

    /// The opposite of provenance in the way that matters: this one is read. An
    /// item filed behind another has to come back off disk still saying so, and
    /// be withheld by the gate autopilot applies at pickup until that one is done.
    func testAFiledItemWaitsForWhatItWasFiledBehind() throws {
        XCTAssertEqual(file(id: "second-half", needs: ["existing"]), .filed)

        let onDisk = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("needs:existing"), onDisk)

        backlog.reload()
        let snapshot = try XCTUnwrap(backlog.backlogFile)
        let item = try XCTUnwrap(snapshot.sections.flatMap(\.items).first { $0.id == "second-half" })
        XCTAssertEqual(item.needs, ["existing"])

        let withheld = DefinitionOfReady.evaluate(item: item, detail: backlog.loadDetail(for: item),
                                                  dependencies: .init(file: snapshot))
        XCTAssertFalse(withheld.isReady, "`existing` is still ready, so this one is not")
        XCTAssertTrue(withheld.reasons.contains { $0.contains("needs existing") }, withheld.summary)

        // And once the thing it waits for is done, it runs — the gate withholds,
        // it does not disqualify.
        var done = snapshot
        for sIdx in done.sections.indices {
            if let iIdx = done.sections[sIdx].items.firstIndex(where: { $0.id == "existing" }) {
                done.sections[sIdx].items[iIdx].status = .done
            }
        }
        let released = DefinitionOfReady.evaluate(item: item, detail: backlog.loadDetail(for: item),
                                                  dependencies: .init(file: done))
        XCTAssertTrue(released.isReady, released.summary)
    }

    /// Most items wait for nothing, and their line has to read exactly as it did
    /// before a draft could express sequencing.
    func testFilingWithNothingToWaitForWritesNoSequencingToken() throws {
        XCTAssertEqual(file(), .filed)
        let onDisk = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("needs:"), onDisk)
    }

    func testAnUnknownSectionIsCreatedRatherThanLosingTheItem() throws {
        XCTAssertEqual(file(section: "Coordinator"), .filed)
        XCTAssertTrue(backlog.backlogFile?.sections.contains { $0.name == "Coordinator" } ?? false)
        XCTAssertEqual(backlog.backlogFile?.sections.first { $0.name == "Coordinator" }?.items.map(\.id),
                       ["refill-one"])
    }

    // MARK: - Refusals

    func testADuplicateIDIsRefusedAndNothingIsWritten() throws {
        XCTAssertEqual(file(), .filed)
        let before = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)

        XCTAssertEqual(file(), .duplicateID,
                       "a second item under the same id would shadow the first")
        XCTAssertEqual(try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8), before)
        XCTAssertEqual(backlog.backlogFile?.sections.flatMap(\.items).filter { $0.id == "refill-one" }.count, 1)
    }

    func testAnIDColldingWithAnExistingItemIsRefused() {
        XCTAssertEqual(file(id: "existing"), .duplicateID)
    }

    func testFilingWithNoBacklogLoadedRefusesRatherThanCreatingOne() {
        let orphan = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        XCTAssertEqual(orphan.fileGroomedItem(sectionName: "Now", id: "x", title: "x", size: .s,
                                              verify: nil, status: .ready,
                                              detailMarkdown: detailMarkdown),
                       .noBacklogOpen)
    }

    // MARK: - Which refusal it was

    /// The distinction the callers exist on: an id already in the backlog is
    /// work that already exists, a detail file that wouldn't write is a disk
    /// problem. Told apart here, they can be answered differently upstream —
    /// where one `false` for both had a human being told the write failed when
    /// the item was already there.
    func testATakenIDAndAnUnwritableDetailAreDifferentRefusals() throws {
        XCTAssertEqual(file(), .filed)

        // `backlog/` is a directory the write needs; a *file* by that name is
        // one the filesystem will refuse to create it under.
        let blocked = try makeBacklogDirectoryUnwritable()
        let taken = blocked.fileGroomedItem(sectionName: "Now", id: "existing", title: "Taken",
                                            size: .s, verify: nil, status: .ready,
                                            detailMarkdown: detailMarkdown)
        let unwritable = blocked.fileGroomedItem(sectionName: "Now", id: "fresh-id", title: "Fresh",
                                                 size: .s, verify: nil, status: .ready,
                                                 detailMarkdown: detailMarkdown)

        XCTAssertEqual(taken, .duplicateID)
        guard case .detailWriteFailed = unwritable else {
            return XCTFail("an unwritable detail file read as \(unwritable)")
        }
        XCTAssertNotEqual(taken, unwritable)
    }

    /// A refusal has to be sayable. Each one carries the phrase whoever is being
    /// told reads — a filing that landed has nothing to say and says nothing.
    func testEveryRefusalCarriesAReasonAndAFilingCarriesNone() throws {
        let landed = file()
        XCTAssertTrue(landed.didFile)
        XCTAssertNil(landed.refusalReason)

        let duplicate = try XCTUnwrap(file(id: "existing").refusalReason)
        XCTAssertTrue(duplicate.contains("already in the backlog"), duplicate)

        let orphan = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        let noBacklog = try XCTUnwrap(
            orphan.fileGroomedItem(sectionName: "Now", id: "x", title: "x", size: .s,
                                   verify: nil, status: .ready,
                                   detailMarkdown: detailMarkdown).refusalReason)
        XCTAssertTrue(noBacklog.contains("no backlog"), noBacklog)

        let blocked = try makeBacklogDirectoryUnwritable()
        let failed = try XCTUnwrap(
            blocked.fileGroomedItem(sectionName: "Now", id: "fresh-id", title: "Fresh", size: .s,
                                    verify: nil, status: .ready,
                                    detailMarkdown: detailMarkdown).refusalReason)
        XCTAssertTrue(failed.contains("detail file couldn't be written"), failed)
    }

    /// A refused write leaves the backlog exactly as it was — the line is not
    /// appended for an item whose detail never landed, since one without the
    /// other fails the gate at pickup.
    func testADetailThatCouldNotBeWrittenAppendsNoLineEither() throws {
        let blocked = try makeBacklogDirectoryUnwritable()
        let before = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)

        _ = blocked.fileGroomedItem(sectionName: "Now", id: "fresh-id", title: "Fresh", size: .s,
                                    verify: nil, status: .ready, detailMarkdown: detailMarkdown)

        XCTAssertEqual(try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8),
                       before)
        XCTAssertNil(blocked.backlogFile?.sections.flatMap(\.items).first { $0.id == "fresh-id" })
    }

    /// The refusal this whole enum exists for, and the one that used to be
    /// reported as a filing: the detail file lands, `BACKLOG.md` doesn't, and the
    /// item is in no backlog anything can read. `didFile` is what the
    /// coordinator's refill loop guards its ledger entry and its event on, so a
    /// `.filed` here was a recorded filing for an item the queue never had.
    func testABacklogThatCouldNotBeWrittenIsNotReportedAsFiled() throws {
        let blocked = try makeBacklogFileUnwritable()

        let outcome = blocked.fileGroomedItem(sectionName: "Now", id: "fresh-id", title: "Fresh",
                                              size: .s, verify: nil, status: .ready,
                                              detailMarkdown: detailMarkdown)

        guard case .backlogWriteFailed = outcome else {
            return XCTFail("an unwritable BACKLOG.md read as \(outcome)")
        }
        XCTAssertFalse(outcome.didFile)
    }

    /// Two files, two failures, two phrases: whoever is told has to know which
    /// file wouldn't take the write, since the orphan one leaves behind and the
    /// fix for each are different.
    func testAnUnwritableBacklogAndAnUnwritableDetailAreDifferentRefusals() throws {
        let noBacklogWrite = try makeBacklogFileUnwritable().fileGroomedItem(
            sectionName: "Now", id: "fresh-id", title: "Fresh", size: .s, verify: nil,
            status: .ready, detailMarkdown: detailMarkdown)
        let noDetailWrite = try makeBacklogDirectoryUnwritable().fileGroomedItem(
            sectionName: "Now", id: "fresh-id", title: "Fresh", size: .s, verify: nil,
            status: .ready, detailMarkdown: detailMarkdown)

        XCTAssertNotEqual(noBacklogWrite, noDetailWrite)

        guard case .backlogWriteFailed(let said) = noBacklogWrite else {
            return XCTFail("an unwritable BACKLOG.md read as \(noBacklogWrite)")
        }
        XCTAssertFalse(said.isEmpty, "the refusal has to carry what the filesystem said")

        let reason = try XCTUnwrap(noBacklogWrite.refusalReason)
        XCTAssertTrue(reason.contains("backlog file couldn't be written"), reason)
        XCTAssertTrue(reason.contains(said), reason)
        XCTAssertNotEqual(reason, try XCTUnwrap(noDetailWrite.refusalReason))
    }

    /// The detail file the failed write leaves behind is not this item's
    /// business — but the line is: nothing may be reported as being in a backlog
    /// that never took it.
    func testABacklogThatCouldNotBeWrittenHasTheItemOnNoLineOnDisk() throws {
        let blocked = try makeBacklogFileUnwritable()

        _ = blocked.fileGroomedItem(sectionName: "Now", id: "fresh-id", title: "Fresh", size: .s,
                                    verify: nil, status: .ready, detailMarkdown: detailMarkdown)

        let url = try XCTUnwrap(blocked.backlogURL)
        // The write failed because a directory is sitting where the file was, so
        // there is no file to read the line out of — which is the point.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// A backlog in its own directory, with a regular file sitting where the
    /// `backlog/` directory would go — so creating it, and the detail inside it,
    /// both fail on a real filesystem rather than on a stub.
    /// A detail file that would not write is a refused *edit*: the backlog it
    /// was filed against is still loaded and still readable, so the message
    /// belongs beside the list rather than over it.
    func testADetailThatCouldNotBeWrittenReportsThroughTheOperationMessage() throws {
        let blocked = try makeBacklogDirectoryUnwritable()

        _ = blocked.fileGroomedItem(sectionName: "Now", id: "fresh-id", title: "Fresh", size: .s,
                                    verify: nil, status: .ready, detailMarkdown: detailMarkdown)

        let message = try XCTUnwrap(blocked.operationMessage)
        XCTAssertTrue(message.contains("backlog/fresh-id.md"), message)
        XCTAssertNil(blocked.errorMessage)
        XCTAssertNotNil(blocked.backlogFile)
    }

    /// The same for the other detail writer — `createDetail`, the Add Detail
    /// control behind an item that has no detail file yet.
    func testACreateDetailThatCouldNotWriteReportsThroughTheOperationMessage() throws {
        let blocked = try makeBacklogDirectoryUnwritable()
        let item = try XCTUnwrap(blocked.backlogFile?.sections.flatMap(\.items)
            .first { $0.id == "existing" })

        blocked.createDetail(for: item)

        let message = try XCTUnwrap(blocked.operationMessage)
        XCTAssertTrue(message.contains("Couldn't create detail file"), message)
        XCTAssertNil(blocked.errorMessage)
        XCTAssertNotNil(blocked.backlogFile)
    }

    private func makeBacklogDirectoryUnwritable() throws -> BacklogViewModel {
        let root = tempDir.appending(path: "blocked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Backlog\n\n## Now\n\n- [ ] existing | Already here | ready\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        try "not a directory".write(to: root.appending(path: "backlog"), atomically: true,
                                    encoding: .utf8)

        let vm = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        vm.loadForProject(repoPath: root.path(percentEncoded: false))
        return vm
    }

    /// A backlog that loaded and then stopped being writable: the file is read
    /// normally, and a directory is put in its place afterwards, so the rename
    /// `AtomicFileWriter` lands the new contents with fails on a real filesystem.
    /// `backlog/` is left alone, so the detail file writes and only the backlog
    /// write is the one that fails.
    private func makeBacklogFileUnwritable() throws -> BacklogViewModel {
        let root = tempDir.appending(path: "unwritable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backlogURL = root.appending(path: "BACKLOG.md")
        try "# Backlog\n\n## Now\n\n- [ ] existing | Already here | ready\n"
            .write(to: backlogURL, atomically: true, encoding: .utf8)

        let vm = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        vm.loadForProject(repoPath: root.path(percentEncoded: false))
        XCTAssertNotNil(vm.backlogFile, "the fixture has to load before it is broken")

        try FileManager.default.removeItem(at: backlogURL)
        try FileManager.default.createDirectory(at: backlogURL, withIntermediateDirectories: true)
        return vm
    }
}

/// `BacklogViewModel.addItem` — the other write that appends an item, and the
/// two id generators that feed it.
///
/// A backlog holding two items under one id is not a cosmetic problem:
/// `updateItem`, `updateItemStatus`, `updateItemSize`, `moveItem` and
/// `removeItem` all resolve an id with `firstIndex(where:)`, so the second copy
/// can never be edited, moved, sized or deleted again — it sits in the file
/// being nothing. These go to disk for the reason the ones above do: a refusal
/// has to leave `BACKLOG.md` exactly as it found it.
@MainActor
final class BacklogAddItemTests: XCTestCase {

    private var tempDir: URL!
    private var backlog: BacklogViewModel!
    private var backlogURL: URL { tempDir.appending(path: "BACKLOG.md") }

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "add-item")
        try """
        ---
        project: demo
        ---

        # Backlog

        ## Now

        - [ ] demo-001 | First | ready
        - [ ] demo-002 | Second | ready

        """.write(to: backlogURL, atomically: true, encoding: .utf8)

        backlog = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
    }

    override func tearDownWithError() throws {
        backlog = nil
    }

    private func ids() -> [String] {
        backlog.backlogFile?.sections.flatMap(\.items).map(\.id) ?? []
    }

    // MARK: - The guard

    func testAddingUnderATakenIDIsRefusedAndTheFileIsUnchanged() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        XCTAssertEqual(backlog.addItem(sectionName: "Now", id: "demo-002",
                                       title: "Second again", verify: nil),
                       .duplicateID)

        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before,
                       "a refused add must not touch the file")
        XCTAssertEqual(ids().filter { $0 == "demo-002" }.count, 1)
    }

    /// The Add Item control reads no return value, so the refusal has to reach a
    /// human through the surface the view model already uses for a write that
    /// did not happen — the operation message, beside the backlog rather than
    /// in place of it.
    func testARefusedAddNamesTheIDInTheOperationMessage() throws {
        _ = backlog.addItem(sectionName: "Now", id: "demo-002", title: "Second again", verify: nil)
        let message = try XCTUnwrap(backlog.operationMessage)
        XCTAssertTrue(message.contains("demo-002"), message)
        XCTAssertTrue(message.contains("already in the backlog"), message)
        XCTAssertNil(backlog.errorMessage,
                     "a refused add is not a backlog that failed to load")
        XCTAssertNotNil(backlog.backlogFile, "the epics stay readable through a refused add")
    }

    /// The message answers the last edit only — the add that lands next takes it
    /// back off the panel.
    func testAnAddThatLandsClearsTheRefusalFromTheOneBefore() throws {
        _ = backlog.addItem(sectionName: "Now", id: "demo-002", title: "Second again", verify: nil)
        XCTAssertNotNil(backlog.operationMessage)

        XCTAssertEqual(backlog.addItem(sectionName: "Now", id: "demo-010", title: "Tenth",
                                       verify: nil),
                       .filed)

        XCTAssertNil(backlog.operationMessage)
    }

    /// The id is what is taken, not the section it was filed under — the same
    /// item under a second epic is the same unreachable second copy.
    func testATakenIDIsRefusedFromAnyEpic() {
        XCTAssertEqual(backlog.addItem(sectionName: "Later", id: "demo-001",
                                       title: "First again", verify: nil),
                       .duplicateID)
        XCTAssertFalse(backlog.backlogFile?.sections.contains { $0.name == "Later" } ?? false,
                       "a refused add must not create the section it was aimed at")
    }

    func testAFreeIDStillLands() throws {
        XCTAssertEqual(backlog.addItem(sectionName: "Now", id: "demo-009",
                                       title: "Ninth", verify: nil),
                       .filed)
        XCTAssertTrue(try String(contentsOf: backlogURL, encoding: .utf8).contains("demo-009"))
    }

    func testAddingWithNoBacklogLoadedRefusesRatherThanCreatingOne() {
        let orphan = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
        XCTAssertEqual(orphan.addItem(sectionName: "Now", id: "x", title: "x", verify: nil),
                       .noBacklogOpen)
    }

    // MARK: - The generated id

    /// The regression the guard would otherwise turn into a broken Add Item
    /// button: two items minus one is one, so a count-derived id is `demo-002`
    /// — which `demo-002` is still holding.
    func testAGeneratedIDIsFreeAfterAnItemIsRemoved() throws {
        backlog.removeItem(itemID: "demo-001")

        let file = try XCTUnwrap(backlog.backlogFile)
        let generated = file.nextGeneratedItemID()
        XCTAssertFalse(file.sections.flatMap(\.items).contains { $0.id == generated }, generated)
        XCTAssertEqual(backlog.addItem(sectionName: "Now", id: generated, title: "Third",
                                       verify: nil),
                       .filed)
    }

    /// Generated twice in a row, with the first one filed in between — the id
    /// has to move on, which is what the ids-in-use reading gives and a count
    /// read before the loop does not.
    func testEachGeneratedIDDiffersFromTheOnesAlreadyFiled() throws {
        for title in ["Third", "Fourth", "Fifth"] {
            let file = try XCTUnwrap(backlog.backlogFile)
            let generated = file.nextGeneratedItemID()
            XCTAssertEqual(backlog.addItem(sectionName: "Now", id: generated, title: title,
                                           verify: nil),
                           .filed, generated)
        }
        XCTAssertEqual(ids().count, Set(ids()).count, ids().joined(separator: ", "))
        XCTAssertEqual(ids(), ["demo-001", "demo-002", "demo-003", "demo-004", "demo-005"])
    }

    /// Ids a human wrote are not all numbered, and the numbered ones need not be
    /// contiguous. Reading the highest number in use answers both.
    func testAGeneratedIDClearsUnnumberedAndSparseIDs() throws {
        XCTAssertEqual(backlog.addItem(sectionName: "Now", id: "a-hand-written-id",
                                       title: "Named", verify: nil), .filed)
        XCTAssertEqual(backlog.addItem(sectionName: "Now", id: "demo-014", title: "Later",
                                       verify: nil), .filed)

        XCTAssertEqual(try XCTUnwrap(backlog.backlogFile).nextGeneratedItemID(), "demo-015")
    }

    /// Removing the newest item leaves its detail file behind on purpose. The
    /// next id must not be the removed one, or filing it would open with — and
    /// its own detail file overwrite — the removed item's spec.
    func testAGeneratedIDSkipsARemovedItemsDetailFile() throws {
        let removed = try XCTUnwrap(backlog.backlogFile?.sections.flatMap(\.items).last)
        XCTAssertEqual(removed.id, "demo-002")
        backlog.createDetail(for: removed)
        let detailURL = tempDir.appending(path: "backlog/demo-002.md")
        let spec = try Data(contentsOf: detailURL)
        backlog.removeItem(itemID: "demo-002")

        let generated = backlog.nextGeneratedItemID()
        XCTAssertNotEqual(generated, "demo-002")
        XCTAssertEqual(backlog.addItem(sectionName: "Now", id: generated, title: "Third",
                                       verify: nil), .filed)
        let filed = try XCTUnwrap(backlog.backlogFile?.sections.flatMap(\.items).first { $0.id == generated })
        backlog.createDetail(for: filed)

        XCTAssertEqual(try Data(contentsOf: detailURL), spec)
    }

    /// A removed item's run history names its id too; a new item filed under it
    /// would open with those runs and their no-work streak.
    func testAGeneratedIDSkipsAnIDWithRunHistory() {
        let store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
            mergesURL: tempDir.appending(path: "task-merges.jsonl"))
        let projectPath = tempDir.path(percentEncoded: false)
        store.append(TaskMetricRecord(
            projectPath: projectPath, projectName: "demo", itemID: "demo-011", title: "Gone",
            epic: nil, declaredSize: nil, startedAt: Date(), completedAt: Date(), durationSeconds: 60,
            costUSD: 1, reviewerRetries: 0, outcome: "done",
            workerAgent: nil, reviewerAgent: nil, executionID: "exec-1", toolErrors: nil))
        backlog.configureMergeOutcomeRecording(store: store, projectPath: projectPath, projectName: "demo")

        XCTAssertEqual(backlog.nextGeneratedItemID(), "demo-012")
    }

    // MARK: - Through the AI editor

    /// The `.addItem` op carries an id the model chose, which can be one the
    /// backlog already holds. Refused, and named — its sibling `.stampItem`
    /// already reports its refusals this way, and a caller reporting what it
    /// filed cannot tell a silent drop from a success.
    func testTheEditorReportsAnExplicitIDThatIsAlreadyTaken() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        let failures = BacklogAIEditor.apply(
            [.addItem(epic: "Now", title: "Second again", id: "demo-002")], to: backlog)

        XCTAssertEqual(failures.count, 1, failures.joined(separator: "; "))
        XCTAssertTrue(try XCTUnwrap(failures.first).contains("demo-002"),
                      failures.joined(separator: "; "))
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    /// And the ordinary path stays quiet: ids the editor generates are free by
    /// construction, including after a delete, so the guard costs it nothing.
    func testTheEditorGeneratesIDsThatLandAfterADelete() throws {
        backlog.removeItem(itemID: "demo-001")

        let failures = BacklogAIEditor.apply(
            [.addItem(epic: "Now", title: "Third"), .addItem(epic: "Now", title: "Fourth")],
            to: backlog)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(ids(), ["demo-002", "demo-003", "demo-004"])
    }

    /// An op addressed to an id nothing holds used to do nothing and say
    /// nothing. Each is named now, and the file is left exactly as it was.
    func testTheEditorNamesEveryOpWhoseIDNoItemHolds() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        let ops: [BacklogEditOp] = [
            .removeItem(id: "demo-091"),
            .updateItem(id: "demo-092", title: "Renamed"),
            .setStatus(id: "demo-093", status: .blocked),
            .moveItem(id: "demo-094", toEpic: "Now"),
            .moveItemBefore(id: "demo-095", before: "demo-001"),
        ]

        let failures = BacklogAIEditor.apply(ops, to: backlog)

        XCTAssertEqual(failures.count, 5, failures.joined(separator: "; "))
        for (index, id) in ["demo-091", "demo-092", "demo-093", "demo-094", "demo-095"].enumerated() {
            XCTAssertTrue(failures[index].contains(id), failures[index])
        }
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    func testTheEditorNamesAnEpicItCannotRemove() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)

        let failures = BacklogAIEditor.apply([.removeEpic(name: "Later")], to: backlog)

        XCTAssertEqual(failures.count, 1, failures.joined(separator: "; "))
        XCTAssertTrue(try XCTUnwrap(failures.first).contains("Later"), failures.joined(separator: "; "))
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    /// Adding an epic under a taken name used to go on and describe it anyway,
    /// overwriting the description the existing epic already had.
    func testAnEpicWhoseNameIsTakenKeepsItsDescription() throws {
        backlog.updateEpicDescription(name: "Now", text: "The original description")

        let failures = BacklogAIEditor.apply(
            [.addEpic(name: "Now", description: "A replacement")], to: backlog)

        XCTAssertEqual(failures.count, 1, failures.joined(separator: "; "))
        XCTAssertTrue(try XCTUnwrap(failures.first).contains("Now"), failures.joined(separator: "; "))
        let onDisk = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("The original description"), onDisk)
        XCTAssertFalse(onDisk.contains("A replacement"), onDisk)
    }

    /// The bar's editor: a refused op leaves an error naming it, and the ops
    /// around it still land.
    func testAMixedApplyLandsTheValidItemAndLeavesAnErrorNamingTheRefusedOne() {
        let editor = makeEditor()

        editor.apply([.addItem(epic: "Now", title: "Second again", id: "demo-002"),
                      .addItem(epic: "Now", title: "Third", id: "demo-003")], to: backlog)

        XCTAssertEqual(ids(), ["demo-001", "demo-002", "demo-003"])
        guard case .error(let message) = editor.phase else {
            return XCTFail("expected an error naming the refused op, got \(editor.phase)")
        }
        XCTAssertTrue(message.contains("demo-002"), message)
        XCTAssertFalse(message.contains("demo-003"), message)
    }

    func testAnApplyWhereEveryOpLandsLeavesTheEditorIdle() {
        let editor = makeEditor()

        editor.apply([.addEpic(name: "Later", description: "Afterwards"),
                      .addItem(epic: "Later", title: "Third"),
                      .moveItemBefore(id: "demo-002", before: "demo-001")], to: backlog)

        guard case .idle = editor.phase else {
            return XCTFail("expected idle, got \(editor.phase)")
        }
        XCTAssertEqual(ids(), ["demo-002", "demo-001", "demo-003"])
    }

    private func makeEditor() -> BacklogAIEditor {
        BacklogAIEditor(runtimeFactory: { MockAgentRuntime() },
                        globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global.json")))
    }
}
