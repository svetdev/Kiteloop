import XCTest
@testable import KiteloopCore

/// An argument list held as one line of text: which spaces separate arguments,
/// which are part of one, and that the line → array → line round trip settles
/// rather than growing the array on every save.
final class ShellArgumentsTests: XCTestCase {

    func testAQuotedArgumentWithASpaceStaysOneArgument() {
        let arguments = ShellArguments.tokenize("-y @scope/server --root \"/Users/me/My Project\"")
        XCTAssertEqual(arguments, ["-y", "@scope/server", "--root", "/Users/me/My Project"])
        XCTAssertFalse(arguments[3].contains("\""), "the quotes group, they are not part of the argument")
    }

    func testASingleQuotedArgumentStaysOneArgument() {
        XCTAssertEqual(
            ShellArguments.tokenize("--root '/Users/me/My Project'"),
            ["--root", "/Users/me/My Project"]
        )
    }

    func testABackslashEscapedSpaceStaysOneArgument() {
        XCTAssertEqual(
            ShellArguments.tokenize("--root /Users/me/My\\ Project"),
            ["--root", "/Users/me/My Project"]
        )
    }

    func testAnUnterminatedQuoteYieldsTheRestOfTheLine() {
        XCTAssertEqual(
            ShellArguments.tokenize("--root \"/Users/me/My Project"),
            ["--root", "/Users/me/My Project"],
            "a half-typed quote must not drop what follows it"
        )
    }

    func testAnEmptyOrWhitespaceOnlyLineYieldsNoArguments() {
        XCTAssertEqual(ShellArguments.tokenize(""), [])
        XCTAssertEqual(ShellArguments.tokenize("   \t "), [])
    }

    func testRunsOfWhitespaceSeparateJustOnce() {
        XCTAssertEqual(ShellArguments.tokenize("  -y   @scope/server  "), ["-y", "@scope/server"])
    }

    func testAnEmptyQuotedArgumentSurvives() {
        XCTAssertEqual(ShellArguments.tokenize("--name \"\""), ["--name", ""])
    }

    func testTheLineQuotesOnlyWhatNeedsIt() {
        XCTAssertEqual(
            ShellArguments.line(from: ["-y", "@scope/server", "--root", "/Users/me/My Project"]),
            "-y @scope/server --root \"/Users/me/My Project\""
        )
    }

    func testTheLineQuotesAnArgumentCarryingAQuoteOrABackslash() {
        XCTAssertEqual(ShellArguments.line(from: ["say \"hi\""]), "\"say \\\"hi\\\"\"")
        XCTAssertEqual(ShellArguments.line(from: ["C:\\tmp"]), "\"C:\\\\tmp\"")
        XCTAssertEqual(ShellArguments.line(from: [""]), "\"\"")
    }

    func testTheRoundTripIsAFixedPoint() {
        let arguments = ["-y", "@scope/server", "--root", "/Users/me/My Project", "say \"hi\"", "C:\\tmp", ""]
        let line = ShellArguments.line(from: arguments)
        XCTAssertEqual(ShellArguments.tokenize(line), arguments)
        XCTAssertEqual(ShellArguments.line(from: ShellArguments.tokenize(line)), line)
    }
}
