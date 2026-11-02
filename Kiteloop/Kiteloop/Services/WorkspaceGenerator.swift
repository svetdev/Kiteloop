import Foundation
import KiteloopCore

struct WorkspaceGenerator: Sendable {
    let project: KiteloopProject
    let sharedImportsURL: URL?
    /// Where a file that could not be linked into the workspace is reported.
    /// Defaults to the `workspace` category of the app log; tests read it here
    /// rather than out of the shared ring buffer.
    var log: @Sendable (String) -> Void = { kiteloopLog($0, category: "workspace") }

    func generate(agent: ResolvedAgent, sessionID: String) throws -> URL {
        let handle = agent.effectiveHandle
        let workspaceDir = project.workspacesURL
            .appending(path: sessionID)
            .appending(path: handle)

        let fm = FileManager.default
        try fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let knowledgeDir = workspaceDir.appending(path: "knowledge")
        let sharedDir = workspaceDir.appending(path: "shared")
        try fm.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        // The CLAUDE.md lists what these two actually linked, not what the
        // package asked for: a path the agent cannot read costs it a turn to
        // find out, and it is the generator that already knows.
        let linkedFiles = symlinkKnowledgeFiles(agent: agent, knowledgeDir: knowledgeDir)
        let linkedImports = symlinkSharedImports(agent: agent, sharedDir: sharedDir)

        let claudeMD = generateClaudeMD(
            agent: agent,
            knowledgeFiles: linkedFiles,
            sharedImports: linkedImports
        )
        let claudeMDURL = workspaceDir.appending(path: "CLAUDE.md")
        try claudeMD.write(to: claudeMDURL, atomically: true, encoding: .utf8)

        return workspaceDir
    }

    func cleanup(sessionID: String) throws {
        let sessionDir = project.workspacesURL.appending(path: sessionID)
        let fm = FileManager.default
        if fm.fileExists(atPath: sessionDir.path(percentEncoded: false)) {
            try fm.removeItem(at: sessionDir)
        }
    }

    /// Removes every session directory under `workspacesURL` except `sessionID` —
    /// the workspaces every earlier boot minted and this boot no longer needs.
    /// Static and unconditional: a project on inline templates never builds a
    /// generator, so this cannot live behind `generate`. A missing workspaces
    /// directory, or one holding only non-directory entries, is left alone.
    static func sweep(workspacesURL: URL, keeping sessionID: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: workspacesURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries where entry.lastPathComponent != sessionID {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Private

    /// `knowledgeFiles` and `sharedImports` are the names that linked, in package
    /// order — everything listed here is a path the agent can read.
    private func generateClaudeMD(
        agent: ResolvedAgent,
        knowledgeFiles: [String],
        sharedImports: [String]
    ) -> String {
        var sections: [String] = []

        let name = agent.package.template.name
        let handle = agent.package.handle
        sections.append("# Agent: \(name) (\(handle))")
        sections.append("")

        let systemPrompt = loadSystemPrompt(agent: agent)
        if !systemPrompt.isEmpty {
            sections.append(systemPrompt)
            sections.append("")
        }

        sections.append("## Knowledge")
        sections.append("")
        sections.append("Your knowledge base is available at:")
        sections.append("")
        sections.append("- `./knowledge/`")

        let hasImports = !sharedImports.isEmpty
        if hasImports {
            sections.append("- `./shared/`")
        }
        sections.append("")
        sections.append("Use these files when relevant. Do not assume all knowledge is loaded into context.")
        sections.append("")

        if !knowledgeFiles.isEmpty {
            sections.append("Important files:")
            for file in knowledgeFiles {
                sections.append("- `./knowledge/\(file)`")
            }
            sections.append("")
        }

        if hasImports {
            sections.append("Shared references:")
            for name in sharedImports {
                sections.append("- `./shared/\(name).md`")
            }
            sections.append("")
        }

        let criticalContent = loadCriticalFacts(agent: agent)
        if !criticalContent.isEmpty {
            sections.append("## Critical Facts")
            sections.append("")
            sections.append(criticalContent)
        }

        return sections.joined(separator: "\n")
    }

    private func loadSystemPrompt(agent: ResolvedAgent) -> String {
        let promptFile = agent.package.template.systemPrompt
        let promptURL = agent.packageURL.appending(path: promptFile)
        guard let data = try? Data(contentsOf: promptURL) else { return "" }
        return stripFrontmatter(String(decoding: data, as: UTF8.self))
    }

    private func loadCriticalFacts(agent: ResolvedAgent) -> String {
        var facts: [String] = []
        for filename in agent.package.knowledge.critical {
            let fileURL = agent.packageURL.appending(path: "knowledge").appending(path: filename)
            guard let data = try? Data(contentsOf: fileURL) else {
                log("\(agent.effectiveHandle): critical knowledge file \(filename) could not be read — left out of Critical Facts")
                continue
            }
            facts.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return facts.joined(separator: "\n\n---\n\n")
    }

    /// The knowledge filenames now readable under the workspace's `knowledge/`,
    /// in package order. A package that names no files links whatever the source
    /// directory holds and returns nothing — that shape has never been listed.
    private func symlinkKnowledgeFiles(agent: ResolvedAgent, knowledgeDir: URL) -> [String] {
        let fm = FileManager.default
        let sourceKnowledgeDir = agent.packageURL.appending(path: "knowledge")
        let files = agent.package.knowledge.files

        guard fm.fileExists(atPath: sourceKnowledgeDir.path(percentEncoded: false)) else {
            for file in files { logUnlinkedKnowledge(file, agent: agent) }
            return []
        }

        if files.isEmpty {
            let entries = (try? fm.contentsOfDirectory(
                at: sourceKnowledgeDir,
                includingPropertiesForKeys: nil
            )) ?? []
            for entry in entries where entry.pathExtension == "md" {
                let dest = knowledgeDir.appending(path: entry.lastPathComponent)
                _ = link(entry, to: dest)
            }
            return []
        }

        var linked: [String] = []
        for file in files {
            let source = sourceKnowledgeDir.appending(path: file)
            let dest = knowledgeDir.appending(path: file)
            guard fm.fileExists(atPath: source.path(percentEncoded: false)),
                  link(source, to: dest) else {
                logUnlinkedKnowledge(file, agent: agent)
                continue
            }
            linked.append(file)
        }
        return linked
    }

    /// The import names now readable under the workspace's `shared/`, in package
    /// order and without the `shared:` prefix or the `.md` suffix.
    private func symlinkSharedImports(agent: ResolvedAgent, sharedDir: URL) -> [String] {
        let fm = FileManager.default

        let sharedSourceDir: URL
        if let importsURL = sharedImportsURL {
            sharedSourceDir = importsURL
        } else {
            let parentDir = agent.packageURL.deletingLastPathComponent().deletingLastPathComponent()
            sharedSourceDir = parentDir.appending(path: "shared")
        }

        var linked: [String] = []
        for imp in agent.package.knowledge.imports {
            let name = imp.hasPrefix("shared:") ? String(imp.dropFirst("shared:".count)) : imp
            let source = sharedSourceDir.appending(path: "\(name).md")
            let dest = sharedDir.appending(path: "\(name).md")
            guard fm.fileExists(atPath: source.path(percentEncoded: false)),
                  link(source, to: dest) else {
                log("\(agent.effectiveHandle): shared import \(name).md could not be linked — left out of CLAUDE.md")
                continue
            }
            linked.append(name)
        }
        return linked
    }

    private func logUnlinkedKnowledge(_ file: String, agent: ResolvedAgent) {
        log("\(agent.effectiveHandle): knowledge file \(file) could not be linked — left out of CLAUDE.md")
    }

    /// Links one source into the workspace and says whether the agent will find
    /// it there. A `dest` that is already a readable file is a second pass over
    /// the same session directory, not a failure.
    private func link(_ source: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createSymbolicLink(at: dest, withDestinationURL: source)
            return true
        } catch {
            return fm.fileExists(atPath: dest.path(percentEncoded: false))
        }
    }

    private func stripFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        let lines = content.components(separatedBy: "\n")
        var endIndex = -1
        for (i, line) in lines.enumerated() where i > 0 {
            if line == "---" {
                endIndex = i
                break
            }
        }
        guard endIndex > 0 else { return content }
        let body = lines[(endIndex + 1)...].joined(separator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
