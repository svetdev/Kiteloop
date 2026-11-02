import Foundation
import Testing
@testable import KiteloopCore

@Suite("SkillRegistry")
struct SkillRegistryTests {

    private func makeTempDir() throws -> URL {
        try TemporaryDirectory.make(prefix: "SkillRegistryTests")
    }

    private func writeSkill(
        in baseDir: URL,
        subdirectory: String,
        name: String,
        description: String = "A test skill",
        userInvocable: Bool = false
    ) throws {
        let skillDir = baseDir.appending(path: subdirectory)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = """
        ---
        name: \(name)
        description: \(description)
        user-invocable: \(userInvocable)
        ---

        Body of \(name).
        """
        try content.write(to: skillDir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test("Discovers skills from a directory containing valid SKILL.md files")
    func discoversSkills() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "alpha", name: "alpha-skill")
        try writeSkill(in: tempDir, subdirectory: "beta", name: "beta-skill")

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.count == 2)
        #expect(all[0].name == "alpha-skill")
        #expect(all[1].name == "beta-skill")
    }

    @Test("Filters user-invocable skills correctly")
    func filtersUserInvocable() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "invocable", name: "invocable-skill", userInvocable: true)
        try writeSkill(in: tempDir, subdirectory: "internal", name: "internal-skill", userInvocable: false)

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let invocable = await registry.userInvocableSkills()
        #expect(invocable.count == 1)
        #expect(invocable[0].name == "invocable-skill")
    }

    @Test("Looks up skill by name — found")
    func lookupByNameFound() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "target", name: "target-skill", description: "The one we want")

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let found = await registry.skill(named: "target-skill")
        #expect(found != nil)
        #expect(found?.description == "The one we want")
    }

    @Test("Looks up skill by name — not found")
    func lookupByNameNotFound() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "other", name: "other-skill")

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let found = await registry.skill(named: "nonexistent")
        #expect(found == nil)
    }

    @Test("Handles empty directories gracefully")
    func handlesEmptyDirectory() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create empty subdirectory (no SKILL.md)
        let emptySubdir = tempDir.appending(path: "empty-subdir")
        try FileManager.default.createDirectory(at: emptySubdir, withIntermediateDirectories: true)

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.isEmpty)
    }

    @Test("Handles non-existent scan paths gracefully")
    func handlesNonExistentPaths() async throws {
        let bogusPath = URL(filePath: "/tmp/nonexistent-\(UUID().uuidString)")

        let registry = SkillRegistry(scanPaths: [bogusPath])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.isEmpty)
    }

    @Test("skillsMatching(prefix:) returns correct matches")
    func prefixMatching() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "run-tests", name: "run-tests", userInvocable: true)
        try writeSkill(in: tempDir, subdirectory: "run-server", name: "run-server", userInvocable: true)
        try writeSkill(in: tempDir, subdirectory: "build", name: "build", userInvocable: true)

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let matches = await registry.skillsMatching(prefix: "run")
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.name.hasPrefix("run") })

        let noMatches = await registry.skillsMatching(prefix: "deploy")
        #expect(noMatches.isEmpty)
    }

    @Test("Prefix matching is case-insensitive")
    func prefixMatchingCaseInsensitive() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "Run-Tests", name: "Run-Tests", userInvocable: true)

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let matches = await registry.skillsMatching(prefix: "run")
        #expect(matches.count == 1)
        #expect(matches[0].name == "Run-Tests")
    }

    @Test("skillsMatching(prefix:) leaves out skills that are not user-invocable")
    func prefixMatchingSkipsNonInvocableSkills() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "run-tests", name: "run-tests", userInvocable: true)
        try writeSkill(in: tempDir, subdirectory: "run-server", name: "run-server")

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let matches = await registry.skillsMatching(prefix: "run")
        #expect(matches.map(\.name) == ["run-tests"])
    }

    @Test("skillsMatching(prefix:) still returns a command")
    func prefixMatchingReturnsCommands() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let commandPath = tempDir.appending(path: "commands")
        try writeCommand(in: commandPath, name: "deploy")

        let registry = SkillRegistry(scanPaths: [], commandPaths: [commandPath])
        await registry.reload()

        let matches = await registry.skillsMatching(prefix: "dep")
        #expect(matches.map(\.name) == ["deploy"])
    }

    @Test("Scans multiple scan paths")
    func multipleScanPaths() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        try writeSkill(in: dir1, subdirectory: "skill-a", name: "skill-a")
        try writeSkill(in: dir2, subdirectory: "skill-b", name: "skill-b")

        let registry = SkillRegistry(scanPaths: [dir1, dir2])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.count == 2)
    }

    @Test("Skips malformed SKILL.md files gracefully")
    func skipsMalformedFiles() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Valid skill
        try writeSkill(in: tempDir, subdirectory: "good", name: "good-skill")

        // Malformed skill (no frontmatter)
        let badDir = tempDir.appending(path: "bad")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try "# No frontmatter here".write(to: badDir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.count == 1)
        #expect(all[0].name == "good-skill")
    }

    // MARK: - newestVersionDirectory

    @Test("Newest version orders dotted-numeric names numerically, not as text")
    func newestVersionOrdersNumerically() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let older = tempDir.appending(path: "5.9.0")
        let newer = tempDir.appending(path: "5.10.0")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)

        let versions = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let latest = SkillRegistry.newestVersionDirectory(among: versions)
        #expect(latest?.lastPathComponent == "5.10.0")
    }

    @Test("A stray file beside version directories is never chosen as the newest version")
    func newestVersionIgnoresStrayFile() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let versionDir = tempDir.appending(path: "1.0.0")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try "not a version".write(to: tempDir.appending(path: "zzz-not-a-version"), atomically: true, encoding: .utf8)

        let versions = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let latest = SkillRegistry.newestVersionDirectory(among: versions)
        #expect(latest?.lastPathComponent == "1.0.0")
    }

    @Test("No directories among the version entries yields no newest version")
    func newestVersionNilWhenNoDirectories() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "not a version".write(to: tempDir.appending(path: "stray-file"), atomically: true, encoding: .utf8)

        let versions = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        #expect(SkillRegistry.newestVersionDirectory(among: versions) == nil)
    }

    @Test("A non-dotted-numeric version name still orders instead of crashing or being dropped")
    func newestVersionFallsBackToTextOrderForNonNumericNames() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let alpha = tempDir.appending(path: "alpha")
        let beta = tempDir.appending(path: "beta")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

        let versions = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let latest = SkillRegistry.newestVersionDirectory(among: versions)
        #expect(latest?.lastPathComponent == "beta")
    }

    // MARK: - Paths handed to the file system unencoded

    private func writeCommand(in commandDir: URL, name: String, body: String = "Run the thing.") throws {
        try FileManager.default.createDirectory(at: commandDir, withIntermediateDirectories: true)
        try body.write(to: commandDir.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
    }

    /// Every path is checked with `fileExists(atPath:)` as a plain path, not a
    /// percent-encoded one: a folder called `with space` exists on disk, and
    /// `with%20space` does not, so an encoded spelling would skip the whole tree.
    @Test("A scan path containing a space is still scanned")
    func scanPathWithSpaceIsScanned() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scanPath = tempDir.appending(path: "with space")
        try writeSkill(in: scanPath, subdirectory: "alpha", name: "alpha-skill")

        let registry = SkillRegistry(scanPaths: [scanPath])
        await registry.reload()

        let names = await registry.allSkills().map(\.name)
        #expect(names == ["alpha-skill"])
    }

    @Test("A skill directory containing a space is still discovered")
    func skillSubdirectoryWithSpaceIsDiscovered() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeSkill(in: tempDir, subdirectory: "my skill", name: "spaced-skill")

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let names = await registry.allSkills().map(\.name)
        #expect(names == ["spaced-skill"])
    }

    @Test("A command path containing a space is still scanned")
    func commandPathWithSpaceIsScanned() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let commandPath = tempDir.appending(path: "commands dir")
        try writeCommand(in: commandPath, name: "deploy")

        let registry = SkillRegistry(scanPaths: [], commandPaths: [commandPath])
        await registry.reload()

        let names = await registry.allSkills().map(\.name)
        #expect(names == ["deploy"])
    }

    // MARK: - Command directories

    /// A command is a `.md` file named for the slash command; anything else in
    /// the directory — a README, a stray text file — is not one.
    @Test("Only .md files in a command directory become commands")
    func commandDirectoryOnlyReadsMarkdownFiles() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let commandPath = tempDir.appending(path: "commands")
        try writeCommand(in: commandPath, name: "deploy")
        try "not a command".write(to: commandPath.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let registry = SkillRegistry(scanPaths: [], commandPaths: [commandPath])
        await registry.reload()

        let names = await registry.allSkills().map(\.name)
        #expect(names == ["deploy"])
    }

    /// Skills win over legacy commands of the same name: the command is added
    /// only when nothing discovered so far carries its name, so a clash neither
    /// duplicates the entry nor replaces the SKILL.md one — and a command whose
    /// name is new is still added.
    @Test("A command is added unless a skill of the same name was already discovered")
    func commandDoesNotShadowASkillOfTheSameName() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let skillsPath = tempDir.appending(path: "skills")
        let commandPath = tempDir.appending(path: "commands")
        try writeSkill(in: skillsPath, subdirectory: "alpha", name: "alpha", description: "From SKILL.md")
        try writeCommand(in: commandPath, name: "alpha", body: "From alpha.md")
        try writeCommand(in: commandPath, name: "beta", body: "From beta.md")

        let registry = SkillRegistry(scanPaths: [skillsPath], commandPaths: [commandPath])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.map(\.name) == ["alpha", "beta"])
        #expect(all.first?.description == "From SKILL.md")
    }

    // MARK: - A byte that is not UTF-8

    /// `prefix`, then byte 0xFF, then `suffix` — a file no strict UTF-8 decode accepts.
    private func writeBytes(_ prefix: String, badByteThen suffix: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data(prefix.utf8) + Data([0xFF]) + Data(suffix.utf8)).write(to: url)
    }

    @Test("A SKILL.md with a byte that is not UTF-8 is still registered, keeping the body after the bad byte")
    func skillWithBadByteIsStillRegistered() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let frontmatter = "---\nname: alpha-skill\ndescription: A test skill\n---\n\nBefore the byte "
        try writeBytes(frontmatter, badByteThen: " after the byte.", to: tempDir.appending(path: "alpha/SKILL.md"))
        try FileManager.default.createDirectory(at: tempDir.appending(path: "no-skill"), withIntermediateDirectories: true)

        let registry = SkillRegistry(scanPaths: [tempDir])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.map(\.name) == ["alpha-skill"])
        #expect(all.first?.body.contains("Before the byte") == true)
        #expect(all.first?.body.contains("after the byte.") == true)
    }

    @Test("A command .md with a byte that is not UTF-8 is still found by name")
    func commandWithBadByteIsStillFound() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let commandPath = tempDir.appending(path: "commands")
        try writeBytes("Run the thing ", badByteThen: " then stop.", to: commandPath.appending(path: "deploy.md"))

        let registry = SkillRegistry(scanPaths: [], commandPaths: [commandPath])
        await registry.reload()

        let found = await registry.skill(named: "deploy")
        #expect(found != nil)
        #expect(found?.body.contains("then stop.") == true)
    }

    // MARK: - Lookup by qualified name

    /// A plugin skill answers to both spellings: the bare name the user types
    /// and the `plugin:name` form that disambiguates it. Requiring both to match
    /// at once would find neither.
    @Test("A plugin skill is found by its bare name and by its plugin-qualified name")
    func lookupMatchesEitherNameOrQualifiedName() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginSkills = tempDir.appending(path: ".claude/plugins/cache/registry/myplugin/1.0.0/skills")
        try writeSkill(in: pluginSkills, subdirectory: "fmt", name: "fmt")

        let registry = SkillRegistry(scanPaths: [pluginSkills])
        await registry.reload()

        let byName = await registry.skill(named: "fmt")
        #expect(byName?.qualifiedName == "myplugin:fmt")
        let byQualifiedName = await registry.skill(named: "myplugin:fmt")
        #expect(byQualifiedName?.name == "fmt")
    }

    // MARK: - Same-name collision between a project and a personal skill

    /// A project skill and a personal skill sharing a bare name resolve to one
    /// entry — the project's — no matter which scan path is handed first.
    @Test("A project skill shadows a personal skill of the same name, in either scan order")
    func projectSkillShadowsUserSkillOfSameName() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let userSkills = tempDir.appending(path: ".claude/skills")
        let projectSkills = tempDir.appending(path: "project/.kiteloop/skills")
        try writeSkill(in: userSkills, subdirectory: "deploy", name: "deploy", description: "Personal", userInvocable: true)
        try writeSkill(in: projectSkills, subdirectory: "deploy", name: "deploy", description: "Project", userInvocable: true)

        for scanPaths in [[userSkills, projectSkills], [projectSkills, userSkills]] {
            let registry = SkillRegistry(scanPaths: scanPaths)
            await registry.reload()

            let all = await registry.allSkills()
            #expect(all.count == 1)
            #expect(all.first?.description == "Project")
            #expect(all.first?.source == .project)

            let invocable = await registry.userInvocableSkills()
            #expect(invocable.count == 1)

            let found = await registry.skill(named: "deploy")
            #expect(found?.description == "Project")
        }
    }

    /// A plugin skill's qualified name is `plugin:name`, distinct from a
    /// personal skill's bare `name`, so the two never collide and both survive.
    @Test("A plugin skill and a user skill sharing a bare name both survive")
    func pluginAndUserSkillSharingBareNameBothSurvive() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let userSkills = tempDir.appending(path: ".claude/skills")
        let pluginSkills = tempDir.appending(path: ".claude/plugins/cache/registry/myplugin/1.0.0/skills")
        try writeSkill(in: userSkills, subdirectory: "fmt", name: "fmt", description: "Personal")
        try writeSkill(in: pluginSkills, subdirectory: "fmt", name: "fmt", description: "Plugin")

        let registry = SkillRegistry(scanPaths: [userSkills, pluginSkills])
        await registry.reload()

        let all = await registry.allSkills()
        #expect(all.count == 2)
        #expect(Set(all.map(\.qualifiedName)) == ["fmt", "myplugin:fmt"])
    }

    // MARK: - newestVersionDirectory: the stat fallback

    /// A version entry whose resource values cannot be read — here a URL whose
    /// scheme is not `file`, for which `resourceValues(forKeys:)` reports no
    /// `isDirectory` — is classified by `stat` on its path instead.
    private func unreadableResourceURL(forPathOf url: URL) throws -> URL {
        var components = URLComponents()
        components.scheme = "kiteloop-test"
        components.path = url.path(percentEncoded: false)
        return try #require(components.url)
    }

    @Test("The stat fallback hands the path over unencoded, so a space in it still resolves")
    func newestVersionFallbackReadsUnencodedPath() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let versionDir = tempDir.appending(path: "with space/1.0.0")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let entry = try unreadableResourceURL(forPathOf: versionDir)
        #expect(SkillRegistry.newestVersionDirectory(among: [entry])?.lastPathComponent == "1.0.0")
    }

    @Test("The stat fallback still discards a file that merely exists")
    func newestVersionFallbackStillDiscardsFiles() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let versionDir = tempDir.appending(path: "1.0.0")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let strayFile = tempDir.appending(path: "zzz-not-a-version")
        try "not a version".write(to: strayFile, atomically: true, encoding: .utf8)

        let entries = [
            try unreadableResourceURL(forPathOf: versionDir),
            try unreadableResourceURL(forPathOf: strayFile)
        ]
        #expect(SkillRegistry.newestVersionDirectory(among: entries)?.lastPathComponent == "1.0.0")
    }

    /// Dotted-numeric means every component is a number: `5.10.` has an empty
    /// one, so it is not read as `[5, 10]` and the pair falls back to text
    /// order, where `1` sorts before `9`.
    @Test("A dotted name with an empty component is not read as a numeric version")
    func newestVersionTreatsEmptyComponentAsText() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for name in ["5.9", "5.10."] {
            try FileManager.default.createDirectory(at: tempDir.appending(path: name), withIntermediateDirectories: true)
        }
        let versions = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        #expect(SkillRegistry.newestVersionDirectory(among: versions)?.lastPathComponent == "5.9")
    }
}
