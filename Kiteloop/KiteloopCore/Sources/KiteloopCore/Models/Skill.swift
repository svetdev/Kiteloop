import Foundation

// MARK: - Errors

package enum SkillParseError: Error, Equatable {
    case missingFrontmatter
    case missingRequiredField(String)
}

// MARK: - Source

package enum SkillSource: Equatable, Codable, Hashable {
    case plugin(name: String)
    case user
    case project
}

// MARK: - Skill

package struct Skill: Identifiable, Equatable, Hashable {
    package let id: String
    package let name: String
    package let description: String
    package let isUserInvocable: Bool
    package let argumentHint: String?
    package let body: String
    package let sourceURL: URL
    package let source: SkillSource

    package var qualifiedName: String {
        switch source {
        case .plugin(let plugin): return "\(plugin):\(name)"
        case .user, .project: return name
        }
    }

    // MARK: - Parsing

    package static func parse(content: String, sourceURL: URL) throws -> Skill {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("---") else {
            throw SkillParseError.missingFrontmatter
        }

        // Find the closing --- (skip the opening one)
        let afterOpening = trimmed.index(trimmed.startIndex, offsetBy: 3)
        let rest = String(trimmed[afterOpening...]).trimmingCharacters(in: .newlines)

        guard let closingRange = rest.range(of: "\n---") else {
            throw SkillParseError.missingFrontmatter
        }

        let yamlBlock = String(rest[rest.startIndex..<closingRange.lowerBound])
        let body = String(rest[closingRange.upperBound...])
            .trimmingCharacters(in: .newlines)

        // Parse YAML key-value pairs
        var fields: [String: String] = [:]
        for line in yamlBlock.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            guard let colonIndex = trimmedLine.firstIndex(of: ":") else { continue }

            let key = String(trimmedLine[trimmedLine.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmedLine[trimmedLine.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
                .stripQuotes()

            fields[key] = value
        }

        // Validate required fields
        guard let name = fields["name"], !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw SkillParseError.missingRequiredField("description")
        }

        let isUserInvocable = fields["user-invocable"]?.lowercased() == "true"
        let argumentHint = fields["argument-hint"]
        let source = detectSource(from: sourceURL)

        return Skill(
            id: sourceURL.path(),
            name: name,
            description: description,
            isUserInvocable: isUserInvocable,
            argumentHint: argumentHint,
            body: body,
            sourceURL: sourceURL,
            source: source
        )
    }

    /// Parse a Claude Code slash-command file (`~/.claude/commands/{name}.md`).
    /// Uses filename as the slash-command name and first paragraph as description.
    package static func parseCommand(content: String, sourceURL: URL) -> Skill? {
        let name = sourceURL.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }

        let lines = content.components(separatedBy: .newlines)
        var description = name
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            description = String(trimmed.prefix(120))
            break
        }

        let source = detectSource(from: sourceURL)
        return Skill(
            id: sourceURL.path(),
            name: name,
            description: description,
            isUserInvocable: true,
            argumentHint: nil,
            body: content,
            sourceURL: sourceURL,
            source: source
        )
    }

    // MARK: - Source Detection

    private static func detectSource(from url: URL) -> SkillSource {
        let pathComponents = url.pathComponents

        // Plugin: path contains /.claude/plugins/cache/
        // Structure: .../.claude/plugins/cache/REGISTRY_NAME/PLUGIN_NAME/VERSION/skills/...
        if let cacheIndex = pathComponents.firstIndex(of: "cache"),
           pathComponents[0..<cacheIndex].contains("plugins") {
            // Skip registry name (e.g. "claude-plugins-official"), then plugin name is next
            let pluginNameIndex = cacheIndex + 2
            if pluginNameIndex < pathComponents.count {
                return .plugin(name: pathComponents[pluginNameIndex])
            }
        }

        // User: path contains /.claude/skills/
        if let claudeIndex = pathComponents.firstIndex(of: ".claude"),
           claudeIndex + 1 < pathComponents.count,
           pathComponents[claudeIndex + 1] == "skills" {
            return .user
        }

        // Fallback: project
        return .project
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, name: String, description: String, isUserInvocable: Bool, argumentHint: String?, body: String, sourceURL: URL, source: SkillSource) {
        self.id = id
        self.name = name
        self.description = description
        self.isUserInvocable = isUserInvocable
        self.argumentHint = argumentHint
        self.body = body
        self.sourceURL = sourceURL
        self.source = source
    }
}

// MARK: - String Helpers

private extension String {
    func stripQuotes() -> String {
        if count >= 2,
           (hasPrefix("\"") && hasSuffix("\"")) || (hasPrefix("'") && hasSuffix("'")) {
            return String(dropFirst().dropLast())
        }
        return self
    }
}
