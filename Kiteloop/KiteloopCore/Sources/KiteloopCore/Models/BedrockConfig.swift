import Foundation

/// The spawn-time reader of `~/.kiteloop/global-config.json`, shared by
/// `ClaudeAuthConfig.loadCurrent()` and
/// `ClaudeCodeCLIRuntime.loadOperatorToolsGrant()`. Both need the file fresh at
/// every spawn — a Settings change must apply to the next session without an
/// app restart — so neither goes through `GlobalConfigStore`, which loads once
/// at launch and is `@MainActor`.
///
/// Distinguishes the three cases `QuarantiningJSONFile.load` documents, but
/// never quarantines: `GlobalConfigStore` owns this file's lifecycle, and
/// moving it aside from a spawn path would race the store's own reads and
/// writes. No file is the ordinary first-launch state and stays silent; a file
/// that cannot be read, and one the decoder refuses, are both reported through
/// `StoreProblemReporter` naming the settings store and the read — the caller
/// then falls back exactly as it always has.
package enum SpawnTimeConfigRead {
    /// `~/.kiteloop/global-config.json`, inlined rather than reached through
    /// `GlobalConfigStore.defaultURL` — that property is `@MainActor`, and both
    /// callers read here specifically to avoid a main-actor hop.
    package static let settingsURL = KiteloopHome.url
        .appending(path: ".kiteloop/global-config.json")

    /// `GlobalConfigStore.storeName`, duplicated rather than referenced for the
    /// same reason as `settingsURL` above — that property is `@MainActor` too.
    package static let settingsStoreName = "Settings"

    package static func load(from url: URL = settingsURL,
                      reporter: StoreProblemReporter = .shared) -> GlobalConfig? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            reporter.report(store: settingsStoreName, operation: .read, url: url, error: error)
            return nil
        }
        do {
            return try JSONDecoder().decode(GlobalConfig.self, from: data)
        } catch {
            reporter.report(store: settingsStoreName, operation: .read, url: url, error: error)
            return nil
        }
    }
}

/// How spawned `claude` processes authenticate to Claude.
package enum ClaudeAuthMethod: String, Codable, CaseIterable, Sendable {
    /// Claude account login (subscription) — the `claude` CLI's own stored credentials.
    case subscription
    /// ANTHROPIC_API_KEY from the token store.
    case apiKey
    /// AWS Bedrock via SSO profile.
    case bedrock

    package var displayName: String {
        switch self {
        case .subscription: return "Claude account (subscription)"
        case .apiKey: return "Anthropic API key"
        case .bedrock: return "AWS Bedrock"
        }
    }
}

/// Snapshot of everything a spawned `claude` process needs for the selected auth
/// method. Built from GlobalConfig (or read off disk at spawn time), so it is safe
/// to consume from any thread.
package struct ClaudeAuthConfig: Sendable {
    package let method: ClaudeAuthMethod
    package let bedrock: BedrockConfig?

    /// TokenStore key holding the Anthropic API key.
    package static let anthropicTokenKey = "anthropic"

    package static func resolve(from config: GlobalConfig) -> ClaudeAuthConfig {
        let method = ClaudeAuthMethod(rawValue: config.claudeAuth ?? "") ?? .subscription
        return ClaudeAuthConfig(method: method, bedrock: config.bedrock)
    }

    /// Reads the current global config off disk. Used at process-spawn time so each
    /// new session picks up settings changes without a main-actor hop.
    package static func loadCurrent() -> ClaudeAuthConfig {
        guard let config = SpawnTimeConfigRead.load() else {
            return ClaudeAuthConfig(method: .subscription, bedrock: nil)
        }
        return resolve(from: config)
    }

    /// Environment for a spawned `claude` process. Starts from the app's environment,
    /// strips auth variables belonging to other methods so the CLI can't silently pick
    /// up a stale backend, then applies the selected method's variables.
    package func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDE_CODE_USE_BEDROCK")
        switch method {
        case .subscription:
            break
        case .apiKey:
            if let key = TokenStore.get(Self.anthropicTokenKey), !key.isEmpty {
                env["ANTHROPIC_API_KEY"] = key
            }
        case .bedrock:
            for (name, value) in (bedrock ?? .default).environmentVariables() {
                env[name] = value
            }
        }
        return env
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(method: ClaudeAuthMethod, bedrock: BedrockConfig?) {
        self.method = method
        self.bedrock = bedrock
    }
}

package struct BedrockConfig: Codable, Sendable {
    package var region: String
    package var profile: String
    package var roleARN: String?
    /// Family alias → Bedrock inference-profile ID. User-editable so new model
    /// releases or non-default regions don't require an app update.
    package var modelMappings: [String: String]

    package static let `default` = BedrockConfig(
        region: "us-east-1",
        profile: "default",
        roleARN: nil,
        modelMappings: [
            "sonnet": "us.anthropic.claude-sonnet-4-6",
            "opus": "us.anthropic.claude-opus-4-8",
            "haiku": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
            "fable": "us.anthropic.claude-fable-5",
        ]
    )

    package func environmentVariables() -> [String: String] {
        var env: [String: String] = [
            "AWS_REGION": region,
            "AWS_PROFILE": profile,
            "CLAUDE_CODE_USE_BEDROCK": "1",
        ]
        if let arn = roleARN, !arn.isEmpty {
            env["AWS_ROLE_ARN"] = arn
        }
        return env
    }

    package func resolveModel(_ alias: String) -> String {
        modelMappings[alias] ?? Self.default.modelMappings[alias] ?? alias
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(region: String, profile: String, roleARN: String? = nil, modelMappings: [String: String]) {
        self.region = region
        self.profile = profile
        self.roleARN = roleARN
        self.modelMappings = modelMappings
    }
}

/// A selectable model in pickers. `id` is what gets stored on agents and templates.
package struct ModelOption: Identifiable, Hashable, Sendable {
    package let id: String
    package let displayName: String
    package let detail: String

    package var pickerLabel: String { "\(displayName) · \(detail)" }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, displayName: String, detail: String) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

/// Single source of truth for selectable models. Claude models are stored as family
/// aliases ("opus", "sonnet", "haiku") — never concrete IDs, because those differ per
/// auth method (Bedrock inference profiles vs Anthropic API model names). The alias is
/// resolved at spawn time by `launchModel(for:auth:)`; anything that isn't a known
/// alias (a pinned full ID, an Ollama model, "copilot") passes through untouched.
package enum ModelCatalog {
    /// The model assigned to new agents, templates, and projects by default.
    package static let defaultModelID = "opus"

    private static let claudeFamilies = ["opus", "sonnet", "haiku", "fable"]

    /// Ordered most → least capable, Opus first (the default family).
    package static let all: [ModelOption] = [
        // Claude (any auth method)
        ModelOption(id: "opus", displayName: "Opus", detail: "most capable"),
        ModelOption(id: "sonnet", displayName: "Sonnet", detail: "balanced"),
        ModelOption(id: "fable", displayName: "Fable", detail: "Claude 5"),
        ModelOption(id: "haiku", displayName: "Haiku", detail: "fast, low cost"),
        // Ollama (local)
        ModelOption(id: "llama3.1", displayName: "Llama 3.1", detail: "local"),
        ModelOption(id: "llama3.2", displayName: "Llama 3.2", detail: "local"),
        ModelOption(id: "qwen2.5-coder", displayName: "Qwen 2.5 Coder", detail: "local"),
        ModelOption(id: "llama3.1:70b", displayName: "Llama 3.1 70B", detail: "local"),
        // Copilot (VS Code bridge)
        ModelOption(id: "copilot", displayName: "GitHub Copilot", detail: "experimental"),
    ]

    /// Family alias for any Claude model spelling ("us.anthropic.claude-opus-4-8",
    /// "claude-opus-4-6-v1", "opus"), nil for non-Claude models.
    package static func familyAlias(of model: String) -> String? {
        let lower = model.lowercased()
        guard lower.contains("claude") || claudeFamilies.contains(lower) else { return nil }
        return claudeFamilies.first { lower.contains($0) }
    }

    /// Maps any stored model value to a picker-selectable ID. A config may name a
    /// concrete Bedrock inference-profile ID; those collapse to their family alias.
    package static func normalize(_ model: String) -> String {
        if all.contains(where: { $0.id == model }) { return model }
        return familyAlias(of: model) ?? model
    }

    /// The picker's rows for a stored model value: `all`, plus one row for the
    /// value itself when it normalises to nothing the list has (an Ollama tag set
    /// with `/model`, a hand-edited config), so the selection is never blank.
    /// `pulled` is what Ollama reports it has pulled, nil when it was not reached:
    /// a list adds each pulled model the catalog lacks, labelled "local", after
    /// the catalog's Ollama rows, and marks those rows that are not pulled.
    package static func pickerOptions(including stored: String, pulled: [String]? = nil) -> [ModelOption] {
        let options = pulled.map(catalogOptions(pulled:)) ?? all
        let model = normalize(stored)
        guard !model.isEmpty, !options.contains(where: { $0.id == model }) else { return options }
        return options + [ModelOption(id: model, displayName: model, detail: "not in the list")]
    }

    /// `all` against a pulled list: catalog Ollama rows missing from it marked
    /// not pulled, and the pulled models the catalog lacks inserted before Copilot.
    private static func catalogOptions(pulled: [String]) -> [ModelOption] {
        let pulledIDs = Set(pulled.map(droppingLatestTag))
        let marked = all.map { option in
            guard isCatalogOllama(option), !pulledIDs.contains(option.id) else { return option }
            return ModelOption(id: option.id, displayName: option.displayName, detail: "local, not pulled")
        }
        var seen = Set(all.map(\.id))
        let extras = pulled.filter { seen.insert(droppingLatestTag($0)).inserted }
            .map { ModelOption(id: $0, displayName: $0, detail: "local") }
        return marked.filter { $0.id != "copilot" } + extras + marked.filter { $0.id == "copilot" }
    }

    /// An Ollama name without a trailing ":latest", which Ollama treats as the bare name.
    private static func droppingLatestTag(_ name: String) -> String {
        name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name
    }

    private static func isCatalogOllama(_ option: ModelOption) -> Bool {
        familyAlias(of: option.id) == nil && option.id != "copilot"
    }

    /// What `claude --model` should receive for a stored model value under the given
    /// auth method. Family aliases resolve per-backend: Bedrock needs a concrete
    /// inference-profile ID (from user-editable mappings); the Anthropic API and
    /// subscription auth accept the alias directly and track the latest release.
    package static func launchModel(for stored: String, auth: ClaudeAuthConfig) -> String {
        let model = normalize(stored)
        guard claudeFamilies.contains(model) else { return model }
        switch auth.method {
        case .bedrock:
            return (auth.bedrock ?? .default).resolveModel(model)
        case .subscription, .apiKey:
            // Every family alias, `fable` included, is accepted by the CLI directly
            // and tracks the latest release (CLI 2.1.281: `fable` launches Fable 5.1).
            return model
        }
    }

    /// Human-readable name for a stored model value, for display outside the picker.
    package static func displayName(for model: String) -> String {
        let normalized = normalize(model)
        return all.first(where: { $0.id == normalized })?.displayName ?? model
    }
}
