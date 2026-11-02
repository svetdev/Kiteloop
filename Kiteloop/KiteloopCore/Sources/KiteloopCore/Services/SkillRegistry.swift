import Foundation

/// Discovers and indexes skills from disk — the Grimoire Index of the Kiteloop.
///
/// Scans configured directories for `SKILL.md` files in subdirectories,
/// parses them into `Skill` instances, and provides lookup/filtering APIs.
package actor SkillRegistry {
    private let scanPaths: [URL]
    private let commandPaths: [URL]
    private var skills: [Skill] = []
    private var watcher: DirectoryWatcher?

    package init(scanPaths: [URL], commandPaths: [URL] = []) {
        self.scanPaths = scanPaths
        self.commandPaths = commandPaths
    }

    /// Start watching scan directories for changes and auto-reload.
    package func startWatching() {
        let allPaths = scanPaths + commandPaths
        watcher = DirectoryWatcher(directories: allPaths) { [weak self] in
            guard let self else { return }
            Task { await self.reload() }
        }
    }

    package func stopWatching() {
        watcher = nil
    }

    // MARK: - Scanning

    /// Scans all configured paths, discovers SKILL.md in subdirectories and command .md files, and rebuilds the index.
    ///
    /// A `SKILL.md` is de-duplicated by `qualifiedName`: a plugin skill is
    /// already qualified as `plugin:name`, so only a `.user` and a `.project`
    /// skill sharing a bare name can collide, and `.project` wins regardless
    /// of scan order.
    package func reload() {
        var discovered = discoverSkillFiles()
        appendCommandFiles(into: &discovered)
        skills = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func discoverSkillFiles() -> [Skill] {
        let fileManager = FileManager.default
        var discovered: [Skill] = []

        for scanPath in scanPaths {
            guard fileManager.fileExists(atPath: scanPath.path(percentEncoded: false)) else {
                continue
            }

            guard let subdirs = try? fileManager.contentsOfDirectory(
                at: scanPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for subdir in subdirs {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: subdir.path(percentEncoded: false), isDirectory: &isDir),
                      isDir.boolValue else {
                    continue
                }

                let skillFile = subdir.appending(path: "SKILL.md")
                guard let data = try? Data(contentsOf: skillFile) else {
                    continue
                }
                let content = String(decoding: data, as: UTF8.self)

                guard let skill = try? Skill.parse(content: content, sourceURL: skillFile) else {
                    continue
                }

                insert(skill, into: &discovered)
            }
        }

        return discovered
    }

    /// De-duplicates by `qualifiedName`, letting a `.project` skill overwrite
    /// whichever copy was discovered first.
    private func insert(_ skill: Skill, into discovered: inout [Skill]) {
        guard let existingIndex = discovered.firstIndex(where: { $0.qualifiedName == skill.qualifiedName }) else {
            discovered.append(skill)
            return
        }
        if skill.source == .project {
            discovered[existingIndex] = skill
        }
    }

    private func appendCommandFiles(into discovered: inout [Skill]) {
        let fileManager = FileManager.default

        for commandPath in commandPaths {
            guard fileManager.fileExists(atPath: commandPath.path(percentEncoded: false)) else {
                continue
            }

            guard let files = try? fileManager.contentsOfDirectory(
                at: commandPath,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files {
                guard file.pathExtension == "md" else { continue }
                guard let data = try? Data(contentsOf: file) else { continue }
                guard let skill = Skill.parseCommand(content: String(decoding: data, as: UTF8.self), sourceURL: file) else { continue }
                if !discovered.contains(where: { $0.name == skill.name }) {
                    discovered.append(skill)
                }
            }
        }
    }

    // MARK: - Queries

    /// All discovered skills sorted by name.
    package func allSkills() -> [Skill] {
        skills
    }

    /// Only user-invocable skills.
    package func userInvocableSkills() -> [Skill] {
        skills.filter { $0.isUserInvocable }
    }

    /// Look up by name or qualifiedName.
    package func skill(named name: String) -> Skill? {
        skills.first { $0.name == name || $0.qualifiedName == name }
    }

    /// User-invocable skills whose name or qualifiedName starts with prefix
    /// (case-insensitive) — only those sending `/name` would expand.
    package func skillsMatching(prefix: String) -> [Skill] {
        let lowered = prefix.lowercased()
        return skills.filter {
            $0.isUserInvocable && (
                $0.name.lowercased().hasPrefix(lowered) ||
                $0.qualifiedName.lowercased().hasPrefix(lowered)
            )
        }
    }

    // MARK: - Default Paths

    /// Default scan paths for the current system.
    ///
    /// Resolves:
    /// 1. User skills at `~/.claude/skills/`
    /// 2. Plugin skills from `~/.claude/plugins/cache/` (latest version per plugin)
    /// 3. Project skills from the provided URL (if non-nil)
    package static func defaultScanPaths(projectSkillsURL: URL?,
                                         home: URL = KiteloopHome.url) -> [URL] {
        let fileManager = FileManager.default
        var paths: [URL] = []

        // 1. User skills
        let userSkills = home.appending(path: ".claude/skills")
        paths.append(userSkills)

        // 2. Plugin skills — scan each registry, each plugin, find latest version
        let pluginCache = home.appending(path: ".claude/plugins/cache")
        if let registries = try? fileManager.contentsOfDirectory(
            at: pluginCache,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for registry in registries {
                guard let plugins = try? fileManager.contentsOfDirectory(
                    at: registry,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for plugin in plugins {
                    guard let versions = try? fileManager.contentsOfDirectory(
                        at: plugin,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    guard let latest = newestVersionDirectory(among: versions) else { continue }

                    let skillsDir = latest.appending(path: "skills")
                    paths.append(skillsDir)
                }
            }
        }

        // 3. Project skills
        if let projectSkillsURL {
            paths.append(projectSkillsURL)
        }

        return paths
    }

    /// Picks the newest version directory among a plugin's version entries.
    ///
    /// Non-directories (a stray file dropped beside the version directories) are
    /// discarded first. Dotted all-numeric names (`5.9.0`, `5.10.0`) order by
    /// component as numbers, so `5.10.0` beats `5.9.0`; a name that isn't of that
    /// shape falls back to case-insensitive text order.
    package static func newestVersionDirectory(among versions: [URL]) -> URL? {
        let fileManager = FileManager.default
        let directories = versions.filter { url in
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
               let isDirectory = values.isDirectory {
                return isDirectory
            }
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
        }
        return directories.max { lhs, rhs in
            versionName(lhs.lastPathComponent, isOrderedBefore: rhs.lastPathComponent)
        }
    }

    private static func versionName(_ lhs: String, isOrderedBefore rhs: String) -> Bool {
        if let lhsComponents = numericVersionComponents(of: lhs),
           let rhsComponents = numericVersionComponents(of: rhs) {
            return lhsComponents.lexicographicallyPrecedes(rhsComponents)
        }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func numericVersionComponents(of name: String) -> [Int]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            components.append(value)
        }
        return components
    }

    /// Default command paths (legacy `~/.claude/commands/` and project `.claude/commands/`).
    package static func defaultCommandPaths(projectURL: URL?) -> [URL] {
        let home = KiteloopHome.url
        var paths: [URL] = [home.appending(path: ".claude/commands")]
        if let projectURL {
            paths.append(projectURL.appending(path: ".claude/commands"))
        }
        return paths
    }
}
