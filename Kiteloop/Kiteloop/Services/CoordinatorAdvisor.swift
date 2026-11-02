import Foundation

/// The Coordinator's voice and its judgment, in the pieces every caller shares:
/// the persona resolution (`composeSystemPrompt`) and the end-of-run distiller
/// that compounds a repo's `coordinator-knowledge.md`.
///
/// It used to *make* a recommendation too, once per signalling item, for the
/// per-project run supervisor, replying with a bounded action from a closed
/// whitelist that a parser turned into an applied effect. That seam was retired
/// (see `CHANGELOG.md`) along with its parser; the persona and the distiller
/// outlived it because the portfolio Coordinator's grooming loop, its chat and
/// `RunKnowledgeDistiller` all go through them.
@MainActor
struct CoordinatorAdvisor {
    let runtimeFactory: () -> any AgentRuntime
    let globalConfigStore: GlobalConfigStore

    // MARK: - Persona (coordinator-agent-persona)

    /// Who the coordinator is. This half is replaceable: a selected coordinator
    /// agent's system prompt, or a project's `coordinator-persona.md`, stands in
    /// for it so the coordinator can reason with a voice you chose.
    static let personaPrompt = """
    You are the Coordinator — the supervisor of Kiteloop's autonomous backlog run.
    You own the RUN, not any single item. The worker builds; the reviewer checks;
    you keep the loop moving and are the calm, human-like judgment when something
    goes sideways. You do NOT write code or review diffs.
    """

    /// General judgment framing, appended after the persona and before
    /// whatever task-specific contract the caller adds (e.g.
    /// `CoordinatorQueueRefill.drafterContract`, which supplies its own
    /// "respond with this JSON shape" instruction and the parser that reads
    /// it back). This half asks for no format of its own: the per-project run
    /// supervisor that once turned a bounded-action reply into an applied
    /// effect was retired, along with the parser that read it, so nothing here
    /// requests JSON nothing can parse.
    static let responseContract = """
    Given the run's health signals and the last item, say plainly what you think
    should happen and why — this is judgment, not a command: nothing here turns
    your words directly into an action, whatever the task asks you to also
    produce.

    Flag rather than stay quiet about: an app bug, a build/verify that can't pass
    for a code reason, the app process dying, an OS permission prompt, a
    tracked-source dirty tree, a merge conflict, or anything ambiguous. Bias
    toward flagging.
    """

    /// The default prompt: the built-in persona plus the contract.
    static let systemPrompt = personaPrompt + "\n\n" + responseContract

    /// The coordinator agent you picked, reduced to what a headless call needs.
    /// Nil `systemPrompt`/`model` mean "the agent didn't specify one" — fall back
    /// rather than sending an empty prompt.
    struct AgentPersona: Sendable, Equatable {
        let name: String
        let model: String?
        let systemPrompt: String?
    }

    /// Persona resolution, most specific first: the coordinator agent you picked,
    /// then the project's `coordinator-persona.md`, then the built-in persona.
    /// The response contract is appended in every case.
    static func composeSystemPrompt(agent: AgentPersona?, projectPersona: String?) -> String {
        resolvePersona(agent: agent, projectPersona: projectPersona) + "\n\n" + responseContract
    }

    /// Just the "who you are" half, most specific first. Split out because the
    /// coordinator is asked for more than one kind of answer — a recommendation,
    /// a draft, a reply in the chat — and each appends its own contract, but all
    /// of them must resolve the persona the same way.
    static func resolvePersona(agent: AgentPersona?, projectPersona: String?) -> String {
        [agent?.systemPrompt, projectPersona, personaPrompt]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? personaPrompt
    }

    // MARK: - Distillation (the WRITE loop)

    static let distillerPrompt = """
    You maintain a coordinator's private notes about how to work on a specific repo.
    Given the existing notes and a log of what happened during one autopilot run,
    output 0–3 NEW, durable learnings worth remembering next time — a recurring
    gotcha, a verify quirk, a cost/throughput pattern. Skip anything already covered
    by the notes, and skip one-off noise (a single clean item, "queue drained").
    Prefer specific and actionable ("X fails because Y → do Z") over vague.
    Respond with ONE JSON object only — no prose, no code fences:
    {"learnings": ["...", "..."]}   (empty array if nothing new is worth keeping)
    """

    /// One-shot: distill 0–3 durable learnings from this run's events, given the
    /// existing notes. Empty when there's nothing worth remembering.
    func distill(events: [String], existingKnowledge: String, projectPath: String) async -> [String] {
        var prompt = "## Existing notes\n\(existingKnowledge.isEmpty ? "(none yet)" : existingKnowledge)\n\n## This run\n"
        prompt += events.prefix(30).map { "- \($0)" }.joined(separator: "\n")
        guard let response = try? await HeadlessAgentRunner.run(
            prompt: prompt,
            cwd: URL(fileURLWithPath: projectPath),
            systemPrompt: Self.distillerPrompt,
            agentName: "Coordinator",
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore
        ) else { return [] }
        return Self.parseLearnings(response)
    }

    nonisolated static func parseLearnings(_ text: String) -> [String] {
        guard let json = RunQualityJudge.firstJSONObject(in: text),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["learnings"] as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { truncateAtWordBoundary($0) }
    }

    /// Caps a learning at `budget` characters without severing a word — what gets
    /// written here lands in `coordinator-knowledge.md` for good, so a hard cut
    /// leaves a half-word in the notes for ever. Within budget: returned as-is.
    /// Over: cut back to the last whitespace, with an ellipsis standing in for the
    /// rest. A single token with no whitespace to cut at still gets the hard cut.
    nonisolated static func truncateAtWordBoundary(_ text: String, budget: Int = 240) -> String {
        guard text.count > budget else { return text }
        let hardCut = String(text.prefix(budget))
        // One character of the budget belongs to the ellipsis.
        let head = text.prefix(budget - 1)
        guard let lastSpace = head.lastIndex(where: { $0.isWhitespace }) else { return hardCut }
        let word = head[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? hardCut : word + "…"
    }

    /// How much of a knowledge file's text the advisor's prompt carries.
    nonisolated static let readBudget = 6000

    /// Reads `<repo>/.kiteloop/<name>` (machine-local, git-ignored). Trimmed,
    /// nothing dropped. nil when absent/empty.
    ///
    /// A caller that only reads to fold this into a prompt wants
    /// ``loadKiteloopFile(projectPath:name:)`` instead — this one is for a
    /// caller that reads the file to merge new content into it and write it
    /// back, where a capped read would silently drop whatever it cut on the
    /// next write.
    nonisolated static func loadKiteloopFileRaw(projectPath: String, name: String) -> String? {
        let url = URL(fileURLWithPath: projectPath).appending(path: ".kiteloop").appending(path: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Lossy, so one bad byte costs only itself — a strict decode returned nil and the next distill wrote over the whole file.
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads `<repo>/.kiteloop/<name>` (machine-local, git-ignored). Trimmed, and
    /// capped so it can't blow up the prompt. nil when absent/empty.
    nonisolated static func loadKiteloopFile(projectPath: String, name: String) -> String? {
        loadKiteloopFileRaw(projectPath: projectPath, name: name).map { capToReadBudget($0) }
    }

    /// Trims `text` to `budget` characters. When it holds a
    /// `CoordinatorKnowledge.autoHeader` auto section, the head and header are
    /// kept intact and whole `- ` bullets are dropped from the *oldest* end of
    /// that section — the section appends newest-last, so the oldest sit right
    /// after the header — until the result fits; a bullet is kept whole or
    /// dropped, never severed, and at least the newest one always survives.
    /// Without an auto header (e.g. the persona file), falls back to a plain
    /// prefix, today's behaviour.
    nonisolated static func capToReadBudget(_ text: String, budget: Int = readBudget) -> String {
        guard text.count > budget else { return text }
        guard text.contains(CoordinatorKnowledge.autoHeader) else { return String(text.prefix(budget)) }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == CoordinatorKnowledge.autoHeader
        }) else { return String(text.prefix(budget)) }

        var bulletsEnd = headerIndex + 1
        while bulletsEnd < lines.count, lines[bulletsEnd].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
            bulletsEnd += 1
        }
        var bullets = Array(lines[(headerIndex + 1)..<bulletsEnd])
        let head = lines[0...headerIndex].joined(separator: "\n")
        let tail = bulletsEnd < lines.count ? "\n" + lines[bulletsEnd...].joined(separator: "\n") : ""

        while bullets.count > 1, (head + "\n" + bullets.joined(separator: "\n") + tail).count > budget {
            bullets.removeFirst()
        }
        return head + "\n" + bullets.joined(separator: "\n") + tail
    }
}
