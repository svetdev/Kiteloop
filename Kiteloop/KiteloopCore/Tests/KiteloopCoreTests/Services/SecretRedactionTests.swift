import XCTest
@testable import KiteloopCore

/// What looks like a credential in a command line or a URL is replaced with
/// the marker; everything else is shown as written.
final class SecretRedactionTests: XCTestCase {

    private let marker = SecretRedaction.marker

    // MARK: A command line

    func testTheValueOfASecretNamedFlagWrittenWithEqualsIsReplaced() {
        XCTAssertEqual(SecretRedaction.commandLine(["-y", "server", "--token=abc123", "--api-key=k-9", "--port=8080"]),
                       ["-y", "server", "--token=\(marker)", "--api-key=\(marker)", "--port=8080"])
    }

    func testTheArgumentAfterASecretNamedFlagIsReplacedWhole() {
        XCTAssertEqual(SecretRedaction.commandLine(["--api-key", "k 9 with spaces", "--password", "hunter2", "--name", "ada"]),
                       ["--api-key", marker, "--password", marker, "--name", "ada"])
    }

    func testAFlagAfterASecretNamedFlagIsNotTakenForItsValue() {
        XCTAssertEqual(SecretRedaction.commandLine(["--use-token", "--verbose", "run"]),
                       ["--use-token", "--verbose", "run"])
    }

    func testTheValueOfASecretNamedAssignmentIsReplaced() {
        XCTAssertEqual(SecretRedaction.commandLine(["env", "GITHUB_TOKEN=ghp_abc", "CLIENT_SECRET=s", "REGION=eu"]),
                       ["env", "GITHUB_TOKEN=\(marker)", "CLIENT_SECRET=\(marker)", "REGION=eu"])
    }

    func testWhatFollowsBearerIsReplaced() {
        XCTAssertEqual(SecretRedaction.commandLine(["-H", "Authorization: Bearer sk-live-1", "bearer", "sk-live-2"]),
                       ["-H", "Authorization: Bearer \(marker)", "bearer", marker])
    }

    func testACommandLineInOneStringIsReadTheSameWay() {
        XCTAssertEqual(SecretRedaction.text("npx  tracker --token abc --api-key=k-9 SECRET=s https://u:p@example.com/x"),
                       "npx  tracker --token \(marker) --api-key=\(marker) SECRET=\(marker) https://\(marker)@example.com/x")
    }

    func testAURLGivenToAnOrdinaryFlagIsStillRead() {
        XCTAssertEqual(SecretRedaction.commandLine(["--endpoint=https://example.com/mcp?api_key=k-9&v=2"]),
                       ["--endpoint=https://example.com/mcp?api_key=\(marker)&v=2"])
    }

    // MARK: A URL

    func testTheUserAndPasswordOfAURLAreReplaced() {
        XCTAssertEqual(SecretRedaction.url("https://ada:pw@example.com/mcp"), "https://\(marker)@example.com/mcp")
        XCTAssertEqual(SecretRedaction.url("postgres://svc:p%40ss@db.internal:5432/app"),
                       "postgres://\(marker)@db.internal:5432/app")
    }

    func testOnlySecretNamedQueryValuesAreReplaced() {
        XCTAssertEqual(SecretRedaction.url("https://example.com/sse?page=2&access_token=abc&apiKey=k#token=frag"),
                       "https://example.com/sse?page=2&access_token=\(marker)&apiKey=\(marker)#token=frag")
    }

    func testAnAtSignInThePathIsNotACredential() {
        XCTAssertEqual(SecretRedaction.url("https://example.com/users/ada@example.com"),
                       "https://example.com/users/ada@example.com")
    }

    // MARK: What is left as written

    func testOrdinaryArgumentsAndPathsAreNotMangled() {
        let arguments = ["npx", "-y", "tracker-mcp", "/opt/token-store/bin/run", "--token-file=/etc/tracker/token.txt",
                         "--config", "./secrets/app.json", "token", "a=b=c", "KEY=", "https://example.com/token/list?page=1",
                         "ada@example.com", ""]

        XCTAssertEqual(SecretRedaction.commandLine(arguments), arguments)
        XCTAssertEqual(SecretRedaction.text(arguments.joined(separator: " ")), arguments.joined(separator: " "))
    }

    func testTextThatIsNotAURLIsLeftAlone() {
        XCTAssertEqual(SecretRedaction.url("see https://u:p@example.com"), "see https://u:p@example.com")
        XCTAssertEqual(SecretRedaction.url("token=abc"), "token=abc")
    }

    func testTheNameRuleIsTheOneTheSummaryUses() {
        for name in ["token", "apiKey", "API_KEY", "client-secret", "Password", "Authorization", "credentials"] {
            XCTAssertTrue(SecretRedaction.isSecretName(name), name)
        }
        for name in ["tokens", "token-file", "keychain", "model", "url"] {
            XCTAssertFalse(SecretRedaction.isSecretName(name), name)
        }
        XCTAssertEqual(ConfigChangeSummary.redacted, marker)
    }

    // MARK: An MCP server's summary

    func testAServersSummaryHidesTheSecretsInItsCommandLine() {
        let entry = ClaudeMCPServerEntry(command: "npx", args: ["-y", "tracker-mcp", "--token", "abc123"],
                                         env: ["TRACKER_TOKEN": "t"])

        XCTAssertEqual(entry.redactedSummary, "npx -y tracker-mcp --token \(marker)")
        XCTAssertEqual(entry.displaySummary, "npx -y tracker-mcp --token abc123", "the editor still shows what was written")
    }

    func testARemoteServersSummaryHidesTheCredentialsInItsURL() {
        let entry = ClaudeMCPServerEntry(extras: ["type": .string("http"),
                                                  "url": .string("https://ada:pw@example.com/mcp?key=k-9&v=2")])

        XCTAssertEqual(entry.redactedSummary, "http: https://\(marker)@example.com/mcp?key=\(marker)&v=2")
        XCTAssertEqual(ClaudeMCPServerEntry(extras: ["type": .string("sse")]).redactedSummary, "sse")
        XCTAssertEqual(ClaudeMCPServerEntry().redactedSummary, "")
    }
}
