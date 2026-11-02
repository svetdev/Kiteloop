import XCTest
@testable import Kiteloop

/// Coverage for the path a tool call row draws: it shortens a path only against a
/// folder that really contains it, so a sibling whose name merely starts with the
/// project folder's name is shown whole instead of cut mid-name.
final class ToolCallPathDisplayTests: XCTestCase {

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private func rendered(_ path: String, projectRoot: String) -> String {
        let display = PathDisplay(path: path, projectRoot: projectRoot)
        return display.directory + display.filename
    }

    /// The defect: a project at `…/kite` used to eat the first characters of a file
    /// under `…/kiteloop`, drawing `loop/App.swift` — a path that exists nowhere.
    func testSiblingFolderSharingThePrefixIsNotRelativised() {
        let drawn = rendered("\(home)/kiteloop/App.swift", projectRoot: "\(home)/kite")

        XCTAssertEqual(drawn, "~/kiteloop/App.swift")
    }

    /// The same boundary on the home branch: `/Users/me` does not contain
    /// `/Users/menu`, so that path stays absolute rather than reading `~nu/…`.
    func testSiblingOfTheHomeFolderStaysAbsolute() {
        let path = "\(home)nu/App.swift"

        XCTAssertEqual(rendered(path, projectRoot: ""), path)
    }

    /// What the row is for: a file genuinely under the project root is drawn
    /// relative to it.
    func testPathUnderTheProjectRootRelativises() {
        let drawn = rendered("/tmp/kite/Sources/App.swift", projectRoot: "/tmp/kite")

        XCTAssertEqual(drawn, "Sources/App.swift")
    }

    /// A root stored with a trailing separator names the same folder, so it
    /// relativises identically.
    func testProjectRootWithATrailingSeparatorRelativisesTheSame() {
        let withSlash = rendered("/tmp/kite/Sources/App.swift", projectRoot: "/tmp/kite/")

        XCTAssertEqual(withSlash, "Sources/App.swift")
    }

    /// The root itself still names something: relativising it to nothing would
    /// leave the row's filename — the part a person reads — empty.
    func testProjectRootItselfKeepsItsName() {
        let display = PathDisplay(path: "/tmp/kite", projectRoot: "/tmp/kite")

        XCTAssertEqual(display.filename, "kite")
        XCTAssertEqual(display.directory, "")
    }
}
