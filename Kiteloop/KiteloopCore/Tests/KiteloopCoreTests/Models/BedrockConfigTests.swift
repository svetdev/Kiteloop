import XCTest
@testable import KiteloopCore

final class BedrockConfigTests: XCTestCase {
    func testEnvironmentVariables() {
        let config = BedrockConfig(
            region: "us-west-2",
            profile: "team-dev",
            roleARN: "arn:aws:iam::123456789:role/claude-role",
            modelMappings: BedrockConfig.default.modelMappings
        )

        let env = config.environmentVariables()
        XCTAssertEqual(env["AWS_REGION"], "us-west-2")
        XCTAssertEqual(env["AWS_PROFILE"], "team-dev")
        XCTAssertEqual(env["AWS_ROLE_ARN"], "arn:aws:iam::123456789:role/claude-role")
        XCTAssertEqual(env["CLAUDE_CODE_USE_BEDROCK"], "1")
    }

    func testEnvironmentWithoutRoleARN() {
        let config = BedrockConfig(
            region: "us-east-1",
            profile: "default",
            roleARN: nil,
            modelMappings: [:]
        )

        let env = config.environmentVariables()
        XCTAssertNil(env["AWS_ROLE_ARN"])
        XCTAssertEqual(env["AWS_REGION"], "us-east-1")
    }

    func testModelResolution() {
        let config = BedrockConfig.default

        let resolved = config.resolveModel("sonnet")
        XCTAssertTrue(resolved.contains("claude-sonnet"))

        let passthrough = config.resolveModel("custom-model-arn")
        XCTAssertEqual(passthrough, "custom-model-arn")
    }

    // MARK: - ModelCatalog

    func testDefaultModelIsOpus() {
        XCTAssertEqual(ModelCatalog.defaultModelID, "opus")
        XCTAssertTrue(ModelCatalog.all.contains { $0.id == ModelCatalog.defaultModelID })
    }

    func testNormalizeCollapsesLegacyStoredValuesToAliases() {
        // Values previously written by Bedrock-era configs must map back to a
        // picker-selectable family alias.
        XCTAssertEqual(ModelCatalog.normalize("us.anthropic.claude-opus-4-8"), "opus")
        XCTAssertEqual(ModelCatalog.normalize("us.anthropic.claude-sonnet-4-5-20250929-v1:0"), "sonnet")
        XCTAssertEqual(ModelCatalog.normalize("us.anthropic.claude-haiku-4-5-20251001-v1:0"), "haiku")
        XCTAssertEqual(ModelCatalog.normalize("claude-opus-4-6"), "opus")
        XCTAssertEqual(ModelCatalog.normalize("claude-sonnet-4-6-max"), "sonnet")
    }

    func testNormalizeIsIdentityForCatalogIDs() {
        for option in ModelCatalog.all {
            XCTAssertEqual(ModelCatalog.normalize(option.id), option.id)
        }
    }

    func testNormalizePassesThroughUnknownModel() {
        // Copilot / arbitrary models must not be rewritten.
        XCTAssertEqual(ModelCatalog.normalize("copilot-gpt-4o"), "copilot-gpt-4o")
    }

    func testPickerOptionsIsTheCatalogForAListedModel() {
        XCTAssertEqual(ModelCatalog.pickerOptions(including: "opus"), ModelCatalog.all)
        XCTAssertEqual(ModelCatalog.pickerOptions(including: "us.anthropic.claude-opus-4-8"), ModelCatalog.all)
    }

    func testPickerOptionsAppendsAnUnlistedModelLast() {
        let options = ModelCatalog.pickerOptions(including: "qwen3:8b")
        XCTAssertEqual(options.count, ModelCatalog.all.count + 1)
        XCTAssertEqual(Array(options.dropLast()), ModelCatalog.all)
        XCTAssertEqual(options.last?.id, "qwen3:8b")
        XCTAssertEqual(options.last?.detail, "not in the list")
    }

    func testPickerOptionsAddsNothingForAnEmptyModel() {
        XCTAssertEqual(ModelCatalog.pickerOptions(including: ""), ModelCatalog.all)
    }

    func testPickerOptionsWithoutAPulledListIsUnchanged() {
        for stored in ["opus", "qwen3:8b", ""] {
            XCTAssertEqual(ModelCatalog.pickerOptions(including: stored, pulled: nil),
                           ModelCatalog.pickerOptions(including: stored))
        }
    }

    func testPickerOptionsListsPulledModelsTheCatalogLacks() {
        let options = ModelCatalog.pickerOptions(including: "opus", pulled: ["qwen3:8b", "llama3.1:latest"])
        XCTAssertEqual(options.filter { $0.id == "qwen3:8b" }.map(\.detail), ["local"])
        XCTAssertFalse(options.contains { $0.id == "llama3.1:latest" })
        let llama = options.first { $0.id == "llama3.1" }
        XCTAssertEqual(llama?.detail, "local")
        XCTAssertEqual(options.count, ModelCatalog.all.count + 1)
        // Claude, catalog Ollama, pulled extras, then Copilot.
        XCTAssertEqual(options.last?.id, "copilot")
        XCTAssertEqual(options.dropLast().last?.id, "qwen3:8b")
    }

    func testPickerOptionsMarksEveryCatalogOllamaRowNotPulledWhenNothingIs() {
        let options = ModelCatalog.pickerOptions(including: "opus", pulled: [])
        XCTAssertEqual(options.map(\.id), ModelCatalog.all.map(\.id))
        let ollamaIDs: Set = ["llama3.1", "llama3.2", "qwen2.5-coder", "llama3.1:70b"]
        for (option, original) in zip(options, ModelCatalog.all) {
            if ollamaIDs.contains(option.id) {
                XCTAssertTrue(option.detail.contains("not pulled"), option.id)
            } else {
                XCTAssertEqual(option, original)
            }
        }
    }

    func testPickerOptionsDoesNotRepeatAPulledStoredModel() {
        let options = ModelCatalog.pickerOptions(including: "qwen3:8b", pulled: ["qwen3:8b"])
        XCTAssertEqual(options.filter { $0.id == "qwen3:8b" }.map(\.detail), ["local"])
    }

    func testLaunchModelResolvesAliasPerAuthMethod() {
        let bedrockAuth = ClaudeAuthConfig(method: .bedrock, bedrock: .default)
        XCTAssertTrue(ModelCatalog.launchModel(for: "opus", auth: bedrockAuth).hasPrefix("us.anthropic."))

        // API key and subscription pass the alias through so the CLI tracks the
        // latest release — no model version is hardcoded anywhere.
        for method in [ClaudeAuthMethod.apiKey, .subscription] {
            let auth = ClaudeAuthConfig(method: method, bedrock: nil)
            XCTAssertEqual(ModelCatalog.launchModel(for: "opus", auth: auth), "opus")
            XCTAssertEqual(ModelCatalog.launchModel(for: "us.anthropic.claude-opus-4-8", auth: auth), "opus")
            // Fable too: pinning it to `claude-fable-5` kept agents on the
            // previous Fable once the CLI's `fable` alias moved to Fable 5.1.
            XCTAssertEqual(ModelCatalog.launchModel(for: "fable", auth: auth), "fable")
        }
    }

    func testLaunchModelRespectsCustomBedrockMappings() {
        var bedrock = BedrockConfig.default
        bedrock.modelMappings["opus"] = "eu.anthropic.claude-opus-custom"
        let auth = ClaudeAuthConfig(method: .bedrock, bedrock: bedrock)
        XCTAssertEqual(ModelCatalog.launchModel(for: "opus", auth: auth), "eu.anthropic.claude-opus-custom")
    }

    func testLaunchModelPassesThroughNonClaudeModels() {
        let auth = ClaudeAuthConfig(method: .bedrock, bedrock: .default)
        XCTAssertEqual(ModelCatalog.launchModel(for: "llama3.1", auth: auth), "llama3.1")
        XCTAssertEqual(ModelCatalog.launchModel(for: "copilot", auth: auth), "copilot")
    }

    func testAuthMethodResolutionFromConfig() {
        var config = GlobalConfig()
        XCTAssertEqual(ClaudeAuthConfig.resolve(from: config).method, .subscription)

        // The method is whatever claudeAuth says — a bedrock block alone does
        // not switch backends; Settings always writes claudeAuth explicitly.
        config.bedrock = .default
        XCTAssertEqual(ClaudeAuthConfig.resolve(from: config).method, .subscription)

        config.claudeAuth = "bedrock"
        XCTAssertEqual(ClaudeAuthConfig.resolve(from: config).method, .bedrock)

        config.claudeAuth = "apiKey"
        XCTAssertEqual(ClaudeAuthConfig.resolve(from: config).method, .apiKey)
    }

    func testProcessEnvironmentStripsForeignAuthVariables() {
        let subscription = ClaudeAuthConfig(method: .subscription, bedrock: nil)
        let env = subscription.processEnvironment()
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["CLAUDE_CODE_USE_BEDROCK"])

        let bedrock = ClaudeAuthConfig(method: .bedrock, bedrock: .default)
        let bedrockEnv = bedrock.processEnvironment()
        XCTAssertEqual(bedrockEnv["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertEqual(bedrockEnv["AWS_REGION"], "us-east-1")
        XCTAssertNil(bedrockEnv["ANTHROPIC_API_KEY"])
    }

    func testCodableRoundtrip() throws {
        let config = BedrockConfig(
            region: "eu-west-1",
            profile: "prod",
            roleARN: "arn:aws:iam::111:role/test",
            modelMappings: ["sonnet": "custom-arn"]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BedrockConfig.self, from: data)

        XCTAssertEqual(decoded.region, "eu-west-1")
        XCTAssertEqual(decoded.profile, "prod")
        XCTAssertEqual(decoded.roleARN, "arn:aws:iam::111:role/test")
        XCTAssertEqual(decoded.modelMappings["sonnet"], "custom-arn")
    }

    // MARK: - SpawnTimeConfigRead
    //
    // `ClaudeAuthConfig.loadCurrent()` and `ClaudeCodeCLIRuntime.loadOperatorToolsGrant()`
    // both delegate to `SpawnTimeConfigRead.load()`, so its own coverage of the
    // absent/undecodable/valid cases stands in for both call sites: neither adds
    // any logic of its own beyond mapping a nil to its particular fallback.

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try redirectSharedLoggerToTemporaryDirectory(prefix: "spawn-time-config-read-log")
        tempDir = try makeTemporaryDirectory(prefix: "spawn-time-config-read")
    }

    private func makeInbox() -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "inbox.log"))
    }

    /// First launch: every one of these stores is created by its first save, so
    /// a missing file is silent, not a problem.
    func testSpawnTimeConfigReadIsSilentWhenNoFileExists() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")

        let config = SpawnTimeConfigRead.load(from: url, reporter: reporter)
        await reporter.drain()

        XCTAssertNil(config)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    /// A file the decoder refuses is reported and the caller still gets nil —
    /// the same fallback it gets today — rather than silently substituting
    /// defaults with nothing said anywhere.
    func testSpawnTimeConfigReadReportsAnUndecodableFileAndReturnsNil() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        try Data("not json at all".utf8).write(to: url)

        let config = SpawnTimeConfigRead.load(from: url, reporter: reporter)
        await reporter.drain()

        XCTAssertNil(config)
        // Untouched: quarantining this file belongs to `GlobalConfigStore` alone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read Settings")
        XCTAssertEqual(pending.first?.body.contains(url.path(percentEncoded: false)), true)
    }

    /// A file that cannot be read at all — a directory sitting where the file
    /// belongs — is reported the same way as one the decoder refuses.
    func testSpawnTimeConfigReadReportsAFileThatCannotBeReadAndReturnsNil() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let config = SpawnTimeConfigRead.load(from: url, reporter: reporter)
        await reporter.drain()

        XCTAssertNil(config)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read Settings")
    }

    /// A readable, valid file resolves exactly as it does today, and nothing is
    /// reported.
    func testSpawnTimeConfigReadDecodesAValidFileAndReportsNothing() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        var written = GlobalConfig()
        written.claudeAuth = "bedrock"
        written.controlServerPort = 4517
        try JSONEncoder().encode(written).write(to: url)

        let config = SpawnTimeConfigRead.load(from: url, reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(config?.claudeAuth, "bedrock")
        XCTAssertEqual(config?.controlServerPort, 4517)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }
}
