import XCTest
@testable import Kiteloop

/// The MCP panel's environment field, as it is parsed on Save.
///
/// The field is free text — one `KEY=VALUE` per line — and the dictionary it
/// maps to is what lands in `.claude/settings.json`. A line the parse drops is
/// a variable the operator typed and the server never sees, with no word about
/// it in the panel, so what survives a Save is worth pinning line by line.
final class MCPServerEnvironmentParseTests: XCTestCase {

    /// A variable with an empty value is a variable: `TOKEN=` sets it to the
    /// empty string. The split kept no empty subsequence once, so the line came
    /// back as one part and was dropped — opening the panel on a server that
    /// had one and pressing Save deleted it.
    func testEmptyValueIsKept() {
        XCTAssertEqual(MCPServerConfigView.environment(from: "A=1\nB="),
                       ["A": "1", "B": ""])
    }

    /// Spaces around the `=` are how a person writes it, not part of the name.
    func testNameAndValueAreTrimmed() {
        XCTAssertEqual(MCPServerConfigView.environment(from: " KEY = value "),
                       ["KEY": "value"])
    }

    /// No `=` means no variable — there is nothing to call it or set it to.
    func testLineWithoutSeparatorIsSkipped() {
        XCTAssertEqual(MCPServerConfigView.environment(from: "KEY\njust some words"), [:])
    }

    /// A blank name is the same: `=value` and ` =value` name nothing.
    func testBlankNameIsSkipped() {
        XCTAssertEqual(MCPServerConfigView.environment(from: "=value\n  =other"), [:])
    }

    /// An `=` in the value is the value's: only the first one separates.
    func testOnlyTheFirstSeparatorSplits() {
        XCTAssertEqual(MCPServerConfigView.environment(from: "URL=https://x/?a=1&b=2"),
                       ["URL": "https://x/?a=1&b=2"])
    }

    /// An empty field is an empty environment, not an `env` entry of nothing.
    func testEmptyTextIsEmptyEnvironment() {
        XCTAssertTrue(MCPServerConfigView.environment(from: "").isEmpty)
    }
}
