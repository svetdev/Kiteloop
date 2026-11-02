import XCTest
@testable import Kiteloop

/// Uploading an avatar installs the image you picked: a name already taken in
/// the project's avatar folder gets a free one rather than leaving the old
/// image in place, a copy that could not be made says so, and an upload with
/// no project open says there is nowhere to install rather than discarding the
/// image the file panel picked.
final class AvatarUploadInstallTests: XCTestCase {

    func testAnImageWhoseNameIsTakenIsInstalledUnderAFreeName() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let first = root.appending(path: "one/avatar.png")
        try write("first image", to: first)
        let installed = try AvatarGridPicker.installCustomImage(from: first, intoProjectAt: project)
        XCTAssertEqual(installed, "avatar.png")

        let second = root.appending(path: "two/avatar.png")
        try write("second image", to: second)
        let renamed = try AvatarGridPicker.installCustomImage(from: second, intoProjectAt: project)

        XCTAssertNotEqual(renamed, installed, "the second image gets a name of its own")
        XCTAssertEqual(renamed, "avatar-2.png")
        // The selection the picker sets is what install answered, and it names
        // a file that is really there.
        XCTAssertEqual(try contents(of: avatarFolder(project).appending(path: renamed)), "second image")
        XCTAssertEqual(try contents(of: avatarFolder(project).appending(path: installed)), "first image",
                       "the image already installed under that name is untouched")
    }

    func testEveryInstalledNameAppearsInTheFolderExactlyOnce() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        var installed: [String] = []
        for index in 1...3 {
            let source = root.appending(path: "pick-\(index)/avatar.png")
            try write("image \(index)", to: source)
            installed.append(try AvatarGridPicker.installCustomImage(from: source, intoProjectAt: project))
        }

        // The grid re-reads the folder after an install and keys its ForEach on
        // the name, so a name repeated here would be a duplicate in the grid.
        XCTAssertEqual(Set(installed).count, installed.count)
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: avatarFolder(project).path).sorted()
        XCTAssertEqual(onDisk, installed.sorted())
    }

    func testAFreeNameIsTheNameItselfWhenNothingHoldsIt() throws {
        let folder = try makeTemporaryDirectory()
        XCTAssertEqual(AvatarGridPicker.availableName(for: "owl.png", in: folder), "owl.png")

        try write("taken", to: folder.appending(path: "owl"))
        XCTAssertEqual(AvatarGridPicker.availableName(for: "owl", in: folder), "owl-2",
                       "a name with no extension is suffixed too")
    }

    func testACopyThatCannotBeMadeInstallsNothingAndSaysWhy() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // A file where the avatar folder belongs: the directory cannot be made.
        try write("not a directory", to: project.appending(path: ".kiteloop"))

        let source = root.appending(path: "pick/avatar.png")
        try write("image", to: source)

        XCTAssertThrowsError(try AvatarGridPicker.installCustomImage(from: source, intoProjectAt: project)) { error in
            let message = AvatarGridPicker.uploadErrorMessage(for: error)
            XCTAssertTrue(message.hasPrefix("Couldn't add that image:"), "the picker says what failed: \(message)")
            XCTAssertTrue(message.contains(error.localizedDescription))
        }
        // install threw before answering a name, so the picker selects nothing.
        XCTAssertFalse(FileManager.default.fileExists(atPath: avatarFolder(project).path))
    }

    func testAnUploadWithAProjectInstallsIntoThatProjectsAvatarFolder() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        XCTAssertEqual(AvatarGridPicker.uploadDestination(forProjectAt: project), .project(project),
                       "a project root is somewhere to install into")

        let source = root.appending(path: "pick/owl.png")
        try write("image", to: source)
        let filename = try AvatarGridPicker.installCustomImage(from: source, intoProjectAt: project)

        // The selection the picker sets names a file in the folder the grid
        // reads, so the Custom section lists it and draws the image.
        let installed = avatarFolder(project).appending(path: filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(try contents(of: installed), "image")
    }

    func testAnUploadWithNoProjectSaysThereIsNowhereToInstall() throws {
        let destination = AvatarGridPicker.uploadDestination(forProjectAt: nil)

        guard case .nowhere(let message) = destination else {
            return XCTFail("with no project root there is nowhere to install: \(destination)")
        }
        XCTAssertEqual(message, AvatarGridPicker.UploadDestination.noProjectMessage)
        XCTAssertTrue(message.contains("nowhere to install an avatar"),
                      "the picker says why nothing was added: \(message)")
    }

    // MARK: - Helpers

    private func avatarFolder(_ project: URL) -> URL {
        project.appending(path: ".kiteloop/avatars")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
