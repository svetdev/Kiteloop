import Foundation

package struct ProjectContextSeeder {
    package let project: KiteloopProject

    /// How much of the README the seeded context carries.
    private static let readmeCharacterLimit = 1500

    /// How many root entries the Structure listing carries.
    private static let structureEntryLimit = 20

    package func seedIfNeeded() {
        let fm = FileManager.default
        let contextPath = project.contextURL.path(percentEncoded: false)
        guard !fm.fileExists(atPath: contextPath) else { return }

        let content = generateContext()
        try? project.ensureKiteloopDirectory()
        fm.createFile(atPath: contextPath, contents: content.data(using: .utf8))
    }

    private func generateContext() -> String {
        var sections: [String] = []

        let name = project.rootURL.lastPathComponent
        sections.append("# \(name)")
        sections.append("<!-- Edit this file to give your agents shared project context. -->")
        sections.append("<!-- All agents receive this as part of their system prompt. -->")

        if let readme = detectReadme() {
            sections.append("## From README\n\n\(excerpt(of: readme.content, from: readme.name))")
        }

        if let stack = detectStack() {
            sections.append("## Tech Stack\n\n\(stack)")
        }

        if let structure = detectStructure() {
            sections.append("## Structure\n\n\(structure)")
        }

        sections.append("""
        ## Conventions

        <!-- Add project conventions here, e.g.: -->
        <!-- - Branch naming: feature/JIRA-123-description -->
        <!-- - PR workflow: draft → review → squash merge -->
        <!-- - Testing: unit tests required for all business logic -->
        """)

        return sections.joined(separator: "\n\n")
    }

    /// The README as the seeded context carries it: whole when it fits under the
    /// cap, otherwise cut on a whitespace boundary and followed by a line naming
    /// the file the rest is still in. This file rides into every agent's system
    /// prompt for the project, where a section that stops mid-word reads as the
    /// whole of what the README said.
    private func excerpt(of content: String, from name: String) -> String {
        let limit = Self.readmeCharacterLimit
        guard content.count > limit else { return content }

        let cut = content.index(content.startIndex, offsetBy: limit)
        var head = String(content[content.startIndex..<cut])
        // Only back off to the previous boundary when the cut lands inside a word;
        // if the next character is whitespace the last word is already whole.
        if !content[cut].isWhitespace,
           let boundary = head.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards) {
            head = String(head[head.startIndex..<boundary.lowerBound])
        }
        head = head.trimmingCharacters(in: .whitespacesAndNewlines)

        return "\(head)…\n\n(Cut here — the rest of the README is in \(name).)"
    }

    private func detectReadme() -> (name: String, content: String)? {
        let candidates = ["README.md", "README.rst", "README.txt", "README"]
        let fm = FileManager.default
        for candidate in candidates {
            let url = project.rootURL.appending(path: candidate)
            if fm.fileExists(atPath: url.path(percentEncoded: false)),
               let content = (try? Data(contentsOf: url)).map({ String(decoding: $0, as: UTF8.self) }) {
                return (candidate, content)
            }
        }
        return nil
    }

    private func detectStack() -> String? {
        let fm = FileManager.default
        var indicators: [String] = []

        let checks: [(String, String)] = [
            ("Package.swift", "Swift Package Manager"),
            ("project.yml", "XcodeGen"),
            ("Podfile", "CocoaPods"),
            ("package.json", "Node.js"),
            ("Cargo.toml", "Rust"),
            ("go.mod", "Go"),
            ("requirements.txt", "Python"),
            ("build.gradle", "Gradle (Android/JVM)"),
            ("Gemfile", "Ruby"),
            ("docker-compose.yml", "Docker Compose"),
            ("Dockerfile", "Docker"),
            (".github/workflows", "GitHub Actions"),
        ]

        for (file, label) in checks {
            let url = project.rootURL.appending(path: file)
            if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                indicators.append("- \(label)")
            }
        }

        return indicators.isEmpty ? nil : indicators.joined(separator: "\n")
    }

    private func detectStructure() -> String? {
        let fm = FileManager.default
        let rootPath = project.rootURL.path(percentEncoded: false)
        guard let entries = try? fm.contentsOfDirectory(atPath: rootPath) else { return nil }

        let listable = entries
            .filter { !$0.hasPrefix(".") && $0 != "node_modules" && $0 != ".build" }
            .sorted()
        let shown = listable.prefix(Self.structureEntryLimit)

        guard !shown.isEmpty else { return nil }

        var lines: [String] = ["```"]
        for entry in shown {
            let fullPath = project.rootURL.appending(path: entry).path(percentEncoded: false)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            lines.append(isDir.boolValue ? "\(entry)/" : entry)
        }
        lines.append("```")

        // A listing that silently stops at the cap reads as the whole root.
        let hidden = listable.count - shown.count
        if hidden > 0 {
            lines.append("")
            lines.append("(\(hidden) more entr\(hidden == 1 ? "y is" : "ies are")"
                + " in the project root but not shown here.)")
        }
        return lines.joined(separator: "\n")
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(project: KiteloopProject) {
        self.project = project
    }
}
