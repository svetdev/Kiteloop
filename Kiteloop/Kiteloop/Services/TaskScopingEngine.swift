import Foundation
import KiteloopCore
import os.log

private let scopingLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "task-scoping")

/// Hybrid scoping: an LLM assigns a size/complexity from the item's content,
/// then historical actuals for that size map it to an expected duration/cost.
/// The LLM's rough guess is the fallback when history is thin; `confidence`
/// reflects how much real data backs the number.
@Observable
@MainActor
final class TaskScopingEngine {
    /// The item currently being scoped, for a per-row spinner.
    private(set) var scopingItemID: String?
    private(set) var lastError: String?

    private let runtimeFactory: () -> any AgentRuntime
    private let globalConfigStore: GlobalConfigStore
    private let store: TaskMetricStore

    /// Below this many size-matched samples, the empirical average isn't trusted
    /// and the LLM's rough estimate is used instead.
    private let minSamplesForEmpirical = 3

    init(
        runtimeFactory: @escaping () -> any AgentRuntime,
        globalConfigStore: GlobalConfigStore,
        store: TaskMetricStore
    ) {
        self.runtimeFactory = runtimeFactory
        self.globalConfigStore = globalConfigStore
        self.store = store
    }

    /// Scopes an item and persists the estimate. Reads back via
    /// `TaskMetricStore.latestEstimate(itemID:)`.
    func scope(item: BacklogItem, detail: BacklogItemDetail?, epic: String?, projectPath: String) async {
        scopingItemID = item.id
        lastError = nil
        defer { scopingItemID = nil }
        do {
            let estimate = try await estimate(item: item, detail: detail, epic: epic, projectPath: projectPath)
            store.appendEstimate(estimate)
        } catch {
            scopingLog.error("Scoping failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func estimate(item: BacklogItem, detail: BacklogItemDetail?, epic: String?, projectPath: String) async throws -> TaskEstimate {
        let prompt = buildPrompt(item: item, detail: detail, epic: epic, projectPath: projectPath)
        let response = try await HeadlessAgentRunner.run(
            prompt: prompt,
            cwd: URL(fileURLWithPath: projectPath),
            systemPrompt: "You estimate software task effort. Respond with a single JSON object only — no prose, no code fences.",
            agentName: "Task Scoper",
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore
        )
        let raw = try Self.decode(response)

        let size = (raw.size.flatMap { ItemSize(rawValue: $0.uppercased()) } ?? .m)
        let llmConfidence = min(max(raw.confidence ?? 0.3, 0), 1)
        let summary = store.summary(forSize: size.rawValue, projectPath: projectPath, minProjectSamples: minSamplesForEmpirical)
        let resolved = Self.resolve(
            llmConfidence: llmConfidence,
            roughMinutes: raw.roughMinutes,
            llmRetries: raw.predictedRetries,
            summary: summary,
            minSamples: minSamplesForEmpirical
        )

        return TaskEstimate(
            itemID: item.id,
            projectPath: projectPath,
            createdAt: Date(),
            estimatedSize: size.rawValue,
            predictedDurationSeconds: resolved.duration,
            predictedCostUSD: resolved.cost,
            predictedRetries: resolved.retries,
            confidence: resolved.confidence,
            source: "hybrid",
            rationale: raw.rationale ?? ""
        )
    }

    struct Resolved: Equatable {
        let duration: Double
        let cost: Double?
        let retries: Int?
        let confidence: Double
    }

    /// The hybrid blend, pure and testable: empirical average when enough
    /// size-matched history exists, otherwise the LLM's rough guess at reduced
    /// confidence.
    static func resolve(
        llmConfidence: Double,
        roughMinutes: Double?,
        llmRetries: Int?,
        summary: TaskMetricSummary?,
        minSamples: Int
    ) -> Resolved {
        if let summary, summary.sampleCount >= minSamples {
            let sampleConfidence = min(1.0, Double(summary.sampleCount) / 8.0)
            return Resolved(
                duration: summary.avgDurationSeconds,
                cost: summary.avgCostUSD,
                retries: Int(summary.avgReviewerRetries.rounded()),
                confidence: (sampleConfidence + llmConfidence) / 2.0
            )
        }
        return Resolved(
            duration: max(60, (roughMinutes ?? 15) * 60),
            cost: nil,
            retries: llmRetries,
            confidence: llmConfidence * 0.4
        )
    }

    // MARK: - Prompt + decoding

    private func buildPrompt(item: BacklogItem, detail: BacklogItemDetail?, epic: String?, projectPath: String) -> String {
        var content = "Item: \(item.title)"
        if let epic { content += "\nEpic: \(epic)" }
        if let what = detail?.what, !what.isEmpty { content += "\n\nWhat:\n\(what)" }
        if let ac = detail?.acceptanceCriteria, !ac.isEmpty {
            content += "\n\nAcceptance criteria:\n" + ac.map { "- \($0)" }.joined(separator: "\n")
        }
        if let oos = detail?.outOfScope, !oos.isEmpty {
            content += "\n\nOut of scope:\n" + oos.map { "- \($0)" }.joined(separator: "\n")
        }

        let history = store.summariesBySize(projectPath: projectPath)
        let historyText: String
        if history.isEmpty {
            historyText = "No historical data yet."
        } else {
            historyText = history.map { size, s in
                "\(size): avg \(Int(s.avgDurationSeconds / 60))m, $\(String(format: "%.2f", s.avgCostUSD)), \(s.avgReviewerRetries.rounded(.toNearestOrEven) == 0 ? "0" : String(format: "%.1f", s.avgReviewerRetries)) retries (n=\(s.sampleCount))"
            }.joined(separator: "\n")
        }

        return """
        Estimate the effort for this backlog item.

        \(content)

        Historical actuals for this project by size (XS–XL), if any:
        \(historyText)

        Return ONLY a JSON object:
        {"size":"XS|S|M|L|XL","roughMinutes":<number>,"predictedRetries":<integer>,"confidence":<0..1>,"rationale":"one sentence"}

        Pick the size from the item's scope and content. `roughMinutes` is your
        own estimate of wall-clock agent time; it's used only when there's little
        historical data for the chosen size. `confidence` is how sure you are.
        """
    }

    struct EstimateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct RawScope: Decodable {
        let size: String?
        let roughMinutes: Double?
        let predictedRetries: Int?
        let confidence: Double?
        let rationale: String?
    }

    private static func decode(_ response: String) throws -> RawScope {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8) else {
            throw EstimateError(message: "Couldn't find a JSON estimate in the assistant's reply.")
        }
        return try JSONDecoder().decode(RawScope.self, from: data)
    }
}
