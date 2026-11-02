import XCTest
@testable import KiteloopCore

final class ProjectStoreTests: XCTestCase {
    private var tempDir: URL!
    private var recentsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try redirectSharedLoggerToTemporaryDirectory(prefix: "project-store-log")
        tempDir = try makeTemporaryDirectory(prefix: "project-store")
        recentsURL = tempDir.appending(path: "recent-projects.json")
    }

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func testUndecodableRecentsFileIsPreservedReportedAndNotOverwritten() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let original = Data(#"[{"id": "x", "name": "x", "path"#.utf8)
        try original.write(to: recentsURL)

        let store = ProjectStore(recentsURL: recentsURL, reporter: reporter)
        let recents = await store.recentProjects()
        await reporter.drain()

        XCTAssertEqual(recents.count, 0)

        // The point of the whole thing: the next open must not overwrite the
        // bytes the decoder refused.
        let projectURL = tempDir.appending(path: "myproject")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        _ = try await store.open(projectURL)

        // Preserved *beside* the path, not by leaving the path empty. Quarantine
        // moves the refused bytes aside and `open` then writes a fresh list
        // where they were — which is the store doing its job, so asserting the
        // file is gone asserts against `addToRecents`. What must hold is that
        // the bytes the decoder refused are no longer the live file.
        let liveNow = try? Data(contentsOf: recentsURL)
        XCTAssertNotEqual(liveNow, original,
                          "the refused bytes must not still be the live recents file")

        let aside = try quarantined(besides: recentsURL)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original)

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not read \(ProjectStore.storeName)")
    }

    func testFailedSaveReportsAWriteItCouldNotMakeAndKeepsTheOpenProject() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        // A regular file where the recents file's directory should be: the
        // durable writer creates that directory first, and cannot.
        let blocker = tempDir.appending(path: "blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let unwritableRecentsURL = blocker.appending(path: "recent-projects.json")

        let store = ProjectStore(recentsURL: unwritableRecentsURL, reporter: reporter)
        let projectURL = tempDir.appending(path: "myproject")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = try await store.open(projectURL)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not write \(ProjectStore.storeName)")
        XCTAssertEqual(pending.first?.body.contains(unwritableRecentsURL.path(percentEncoded: false)), true)

        // The failure costs the file, not the session: the project just
        // opened is still in the in-memory recents list.
        let recents = await store.recentProjects()
        XCTAssertEqual(recents.map(\.id), [project.id])
    }

    func testSuccessfulSaveLeavesOnlyTheRecentsFileBehind() async throws {
        let store = ProjectStore(recentsURL: recentsURL)
        let projectURL = tempDir.appending(path: "myproject")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        _ = try await store.open(projectURL)

        let entries = try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertEqual(entries.filter { $0 != "myproject" }, [recentsURL.lastPathComponent])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([RecentProject].self, from: Data(contentsOf: recentsURL))
        let recents = await store.recentProjects()
        XCTAssertEqual(decoded.map(\.id), recents.map(\.id))
    }

    func testOpenProject() async throws {
        let projectURL = tempDir.appending(path: "myproject")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let store = ProjectStore(recentsURL: recentsURL)
        let project = try await store.open(projectURL)

        XCTAssertEqual(project.rootURL, projectURL)
        let projects = await store.openProjects()
        XCTAssertEqual(projects.count, 1)
    }

    func testOpeningAMissingFolderIsRefusedAndCreatesNothing() async throws {
        let missing = tempDir.appending(path: "gone/deeper/project")
        let store = ProjectStore(recentsURL: recentsURL)

        do {
            _ = try await store.open(missing)
            XCTFail("opening a missing folder should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(missing.path), error.localizedDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appending(path: "gone").path))
        let projects = await store.openProjects()
        XCTAssertTrue(projects.isEmpty)
        let recents = await store.recentProjects()
        XCTAssertTrue(recents.isEmpty)
    }

    func testOpeningARegularFileIsRefusedAndCreatesNothing() async throws {
        let file = tempDir.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: file)
        let store = ProjectStore(recentsURL: recentsURL)

        do {
            _ = try await store.open(file)
            XCTFail("opening a regular file should throw")
        } catch {
            XCTAssertEqual(error as? ProjectFolderMissingError, ProjectFolderMissingError(path: file.path))
        }

        var isDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appending(path: ".kiteloop").path))
        let projects = await store.openProjects()
        XCTAssertTrue(projects.isEmpty)
        let recents = await store.recentProjects()
        XCTAssertTrue(recents.isEmpty)
    }

    func testReopeningAnOpenProjectWhoseFolderWasRemovedReturnsIt() async throws {
        let url = tempDir.appending(path: "myproject")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = ProjectStore(recentsURL: recentsURL)
        let project = try await store.open(url)

        try FileManager.default.removeItem(at: url)
        let reopened = try await store.open(url)

        XCTAssertEqual(reopened.id, project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testActiveProject() async throws {
        let url1 = tempDir.appending(path: "proj1")
        let url2 = tempDir.appending(path: "proj2")
        try FileManager.default.createDirectory(at: url1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url2, withIntermediateDirectories: true)

        let store = ProjectStore(recentsURL: recentsURL)
        _ = try await store.open(url1)
        let p2 = try await store.open(url2)

        let active = await store.activeProject()
        XCTAssertEqual(active?.id, p2.id)
    }

    func testCloseProject() async throws {
        let url1 = tempDir.appending(path: "proj1")
        let url2 = tempDir.appending(path: "proj2")
        try FileManager.default.createDirectory(at: url1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url2, withIntermediateDirectories: true)

        let store = ProjectStore(recentsURL: recentsURL)
        let p1 = try await store.open(url1)
        _ = try await store.open(url2)

        await store.close(p1.id)
        let projects = await store.openProjects()
        XCTAssertEqual(projects.count, 1)
    }

    func testSortOpenRestoresSavedOrder() async throws {
        let urls = try (0..<4).map { i -> URL in
            let url = tempDir.appending(path: "proj-\(i)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let store = ProjectStore(recentsURL: recentsURL)
        // Open in a scrambled order, as concurrent restore might.
        for i in [2, 0, 3, 1] { _ = try await store.open(urls[i]) }

        // Restore the saved left-to-right order.
        await store.sortOpen(byURLOrder: urls)

        let ordered = await store.openProjects().map { $0.rootURL.lastPathComponent }
        XCTAssertEqual(ordered, ["proj-0", "proj-1", "proj-2", "proj-3"])
    }

    func testSortOpenKeepsUnrankedProjectsAtEnd() async throws {
        let urls = try (0..<3).map { i -> URL in
            let url = tempDir.appending(path: "proj-\(i)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let store = ProjectStore(recentsURL: recentsURL)
        for url in urls { _ = try await store.open(url) }

        // Only proj-2 and proj-0 are in the saved order; proj-1 wasn't persisted.
        await store.sortOpen(byURLOrder: [urls[2], urls[0]])

        let ordered = await store.openProjects().map { $0.rootURL.lastPathComponent }
        XCTAssertEqual(ordered, ["proj-2", "proj-0", "proj-1"])
    }

    func testRecentsPersistAcrossInstances() async throws {
        let url = tempDir.appending(path: "myproject")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let store1 = ProjectStore(recentsURL: recentsURL)
        _ = try await store1.open(url)

        let store2 = ProjectStore(recentsURL: recentsURL)
        let recents = await store2.recentProjects()
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.name, "myproject")
    }

    func testMaxRecentsLimit() async throws {
        let store = ProjectStore(recentsURL: recentsURL)
        for i in 0..<15 {
            let url = tempDir.appending(path: "proj-\(i)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try await store.open(url)
        }

        let recents = await store.recentProjects()
        XCTAssertEqual(recents.count, ProjectStore.maxRecents)
    }

    func testOpenSameProjectTwice() async throws {
        let url = tempDir.appending(path: "myproject")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let store = ProjectStore(recentsURL: recentsURL)
        _ = try await store.open(url)
        _ = try await store.open(url)

        let projects = await store.openProjects()
        XCTAssertEqual(projects.count, 1)
    }

    func testSwitchActive() async throws {
        let url1 = tempDir.appending(path: "proj1")
        let url2 = tempDir.appending(path: "proj2")
        try FileManager.default.createDirectory(at: url1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url2, withIntermediateDirectories: true)

        let store = ProjectStore(recentsURL: recentsURL)
        let p1 = try await store.open(url1)
        _ = try await store.open(url2)

        await store.setActive(p1)
        let active = await store.activeProject()
        XCTAssertEqual(active?.id, p1.id)
    }
}
