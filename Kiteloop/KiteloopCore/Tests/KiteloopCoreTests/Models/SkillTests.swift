import Foundation
import Testing
@testable import KiteloopCore

@Suite("Skill Parsing")
struct SkillTests {

    @Test("Parses valid frontmatter with all fields")
    func parseAllFields() throws {
        let content = """
        ---
        name: test-driven-development
        description: Use when implementing any feature or bugfix
        user-invocable: true
        argument-hint: [feature-name]
        ---

        # TDD Workflow

        Write tests first, then implement.
        """
        let url = URL(filePath: "/project/skills/tdd/SKILL.md")
        let skill = try Skill.parse(content: content, sourceURL: url)

        #expect(skill.name == "test-driven-development")
        #expect(skill.description == "Use when implementing any feature or bugfix")
        #expect(skill.isUserInvocable == true)
        #expect(skill.argumentHint == "[feature-name]")
        #expect(skill.body.contains("# TDD Workflow"))
        #expect(skill.body.contains("Write tests first, then implement."))
        #expect(skill.sourceURL == url)
        #expect(skill.id == url.path())
    }

    @Test("Parses minimal frontmatter with just name and description")
    func parseMinimalFields() throws {
        let content = """
        ---
        name: simple-skill
        description: A minimal skill
        ---

        Body content here.
        """
        let url = URL(filePath: "/project/skills/simple/SKILL.md")
        let skill = try Skill.parse(content: content, sourceURL: url)

        #expect(skill.name == "simple-skill")
        #expect(skill.description == "A minimal skill")
        #expect(skill.isUserInvocable == false)
        #expect(skill.argumentHint == nil)
        #expect(skill.body.contains("Body content here."))
    }

    @Test("Throws on missing frontmatter")
    func missingFrontmatter() {
        let content = """
        # No frontmatter here

        Just a markdown file.
        """
        let url = URL(filePath: "/project/skills/bad/SKILL.md")

        #expect(throws: SkillParseError.missingFrontmatter) {
            try Skill.parse(content: content, sourceURL: url)
        }
    }

    @Test("Throws on missing required field")
    func missingRequiredField() {
        let content = """
        ---
        name: incomplete-skill
        ---

        Body without description field.
        """
        let url = URL(filePath: "/project/skills/bad/SKILL.md")

        #expect(throws: SkillParseError.missingRequiredField("description")) {
            try Skill.parse(content: content, sourceURL: url)
        }
    }

    @Test("Detects plugin source from path")
    func detectPluginSource() throws {
        let content = """
        ---
        name: using-git-worktrees
        description: Use when working in a worktree
        ---

        Worktree instructions.
        """
        let url = URL(filePath: "/Users/dev/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/using-git-worktrees/SKILL.md")
        let skill = try Skill.parse(content: content, sourceURL: url)

        #expect(skill.source == .plugin(name: "superpowers"))
        #expect(skill.qualifiedName == "superpowers:using-git-worktrees")
    }

    @Test("Detects user source from path")
    func detectUserSource() throws {
        let content = """
        ---
        name: my-custom-skill
        description: A user skill
        ---

        Custom workflow.
        """
        let url = URL(filePath: "/Users/dev/.claude/skills/my-custom-skill/SKILL.md")
        let skill = try Skill.parse(content: content, sourceURL: url)

        #expect(skill.source == .user)
        #expect(skill.qualifiedName == "my-custom-skill")
    }

    @Test("Detects project source from path (fallback)")
    func detectProjectSource() throws {
        let content = """
        ---
        name: project-workflow
        description: A project-specific skill
        ---

        Project workflow details.
        """
        let url = URL(filePath: "/Users/dev/code/my-project/.claude/commands/project-workflow/SKILL.md")
        let skill = try Skill.parse(content: content, sourceURL: url)

        #expect(skill.source == .project)
        #expect(skill.qualifiedName == "project-workflow")
    }

    @Test("Strips quotes from values")
    func stripsQuotesFromValues() throws {
        let content = """
        ---
        name: "quoted-skill"
        description: "A skill with quoted values"
        argument-hint: "[arg]"
        ---

        Body.
        """
        let url = URL(filePath: "/project/skills/quoted/SKILL.md")
        let skill = try Skill.parse(content: content, sourceURL: url)

        #expect(skill.name == "quoted-skill")
        #expect(skill.description == "A skill with quoted values")
        #expect(skill.argumentHint == "[arg]")
    }

    // MARK: - Slash-command files

    @Test("A command file is named by its filename and is user-invocable")
    func parseCommandNamesItselfAfterTheFile() throws {
        let content = "Reviews the open pull request.\n"
        let url = URL(filePath: "/Users/dev/.claude/commands/review.md")
        let skill = try #require(Skill.parseCommand(content: content, sourceURL: url))

        #expect(skill.name == "review")
        #expect(skill.qualifiedName == "review")
        #expect(skill.isUserInvocable == true, "a slash command exists to be invoked")
        #expect(skill.argumentHint == nil)
        #expect(skill.description == "Reviews the open pull request.")
        #expect(skill.body == content)
        #expect(skill.id == url.path())
    }

    @Test("A command's description is its first line that is neither blank nor a heading")
    func parseCommandDescriptionSkipsBlankLinesAndHeadings() throws {
        let url = URL(filePath: "/Users/dev/.claude/commands/review.md")

        let afterBlankAndHeading = try #require(Skill.parseCommand(
            content: "\n# Review\n   \nReviews the open pull request.\nMore detail.\n",
            sourceURL: url))
        #expect(afterBlankAndHeading.description == "Reviews the open pull request.")

        let headingFirst = try #require(Skill.parseCommand(content: "# Review\nReviews it.\n", sourceURL: url))
        #expect(headingFirst.description == "Reviews it.")

        let headingOnly = try #require(Skill.parseCommand(content: "# Review\n", sourceURL: url))
        #expect(headingOnly.description == "review", "with nothing but a heading, the name stands in")
    }

    // MARK: - Source detection at the end of a path

    @Test("A plugin cache path with nothing past the registry has no plugin name")
    func pluginCachePathEndingAtTheRegistryIsNotAPlugin() throws {
        let content = "---\nname: s\ndescription: d\n---\nBody.\n"

        // Registry, then plugin: the plugin name is the component two past `cache`.
        let plugin = try Skill.parse(
            content: content,
            sourceURL: URL(filePath: "/Users/dev/.claude/plugins/cache/claude-plugins-official/superpowers"))
        #expect(plugin.source == .plugin(name: "superpowers"))

        // One component shorter, the path ends at the registry: there is no
        // plugin name to read, and nothing past the end is read for one.
        let registryOnly = try Skill.parse(
            content: content,
            sourceURL: URL(filePath: "/Users/dev/.claude/plugins/cache/claude-plugins-official"))
        #expect(registryOnly.source == .project)
    }

    @Test("A path ending at .claude is neither a user skill nor read past its end")
    func dotClaudeAsTheLastComponentIsProject() throws {
        let content = "---\nname: s\ndescription: d\n---\nBody.\n"

        let skills = try Skill.parse(content: content, sourceURL: URL(filePath: "/Users/dev/.claude/skills"))
        #expect(skills.source == .user)

        // Nothing follows `.claude`, so there is no component to compare with "skills".
        let bare = try Skill.parse(content: content, sourceURL: URL(filePath: "/Users/dev/.claude"))
        #expect(bare.source == .project)
    }

    // MARK: - Quote stripping at its edges

    @Test("An empty quoted value strips to nothing")
    func emptyQuotedValueStripsToEmpty() throws {
        let url = URL(filePath: "/project/skills/quoted/SKILL.md")
        let hinted = """
        ---
        name: quoted-skill
        description: A skill
        argument-hint: ""
        ---

        Body.
        """
        let skill = try Skill.parse(content: hinted, sourceURL: url)
        #expect(skill.argumentHint == "", "two quotes around nothing are an empty value, not a two-character one")

        // The same two characters as a description are an empty description —
        // a missing required field, not a value.
        let described = """
        ---
        name: quoted-skill
        description: ""
        ---

        Body.
        """
        #expect(throws: SkillParseError.missingRequiredField("description")) {
            try Skill.parse(content: described, sourceURL: url)
        }
    }

    @Test("A value quoted on only one end is kept whole")
    func lopsidedQuotesAreKept() throws {
        let url = URL(filePath: "/project/skills/quoted/SKILL.md")
        for raw in ["\"open", "close\"", "'open", "close'"] {
            let content = "---\nname: s\ndescription: d\nargument-hint: \(raw)\n---\nBody.\n"
            let skill = try Skill.parse(content: content, sourceURL: url)
            #expect(skill.argumentHint == raw, "\(raw) has no matching pair to strip")
        }
    }
}
