import XCTest
@testable import Kiteloop

/// A project tab and its Portfolio card name only the folder, so the hover text
/// is what tells two projects called "app" apart — the full path, with the home
/// folder shortened to `~`.
final class ProjectFolderHoverTextTests: XCTestCase {

    private let home = "/Users/alex"

    func testAPathUnderTheHomeFolderShortensToTilde() {
        XCTAssertEqual(MainWindow.projectFolderHoverText(forPath: "/Users/alex/work/app", home: home), "~/work/app")
    }

    func testTheHomeFolderItselfIsTilde() {
        XCTAssertEqual(MainWindow.projectFolderHoverText(forPath: "/Users/alex", home: home + "/"), "~")
    }

    func testAPathOutsideTheHomeFolderComesBackUnchanged() {
        XCTAssertEqual(MainWindow.projectFolderHoverText(forPath: "/Volumes/Code/app", home: home), "/Volumes/Code/app")
        // A sibling whose name starts with the home folder's is not under it.
        XCTAssertEqual(MainWindow.projectFolderHoverText(forPath: "/Users/alexa/app", home: home), "/Users/alexa/app")
    }

    func testTwoFoldersWithTheSameNameReadDifferently() {
        let work = MainWindow.projectFolderHoverText(forPath: "/Users/alex/work/app", home: home)
        let oss = MainWindow.projectFolderHoverText(forPath: "/Users/alex/oss/app", home: home)
        XCTAssertNotEqual(work, oss)
    }

    func testTheDefaultHomeIsTheCurrentUsersHomeFolder() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: "work/app").path
        XCTAssertEqual(MainWindow.projectFolderHoverText(forPath: path), "~/work/app")
    }
}
