import Foundation

/// How a project's QA agent brings the app up, drives it and takes its
/// screenshots — the onboarding an item needs before it can run with
/// `flow:qa`.
///
/// Read from `kiteloop-qa.json` at the repository root, a tracked file, so the
/// commands that judge a UI feature are reviewed like any other code and a
/// fresh worktree has them. A project without the file runs no QA flow: the
/// Definition-of-Ready refuses a `flow:qa` item there and says why.
package struct QAProfile: Codable, Equatable, Sendable {
    /// Runs one flow from the repository root and leaves its storyboard behind.
    /// `{spec}` is replaced with the item's spec path.
    package var run: String
    /// Proves the harness works at all — brings the app up, opens it, takes a
    /// screenshot, tears down. What onboarding checks before the first QA run.
    package var smoke: String
    /// Where an item's flow is written, relative to the root. `{id}` is
    /// replaced with the item's id.
    package var spec: String
    /// Where the run leaves its storyboard — the screenshots the QA agent
    /// judges — relative to the root. `{id}` is replaced as in `spec`.
    package var storyboard: String
    /// The cleaner's command: complexity, CRAP, whatever this project's quality
    /// gates are. Omitted, the run has no clean stage.
    package var clean: String?
    /// The hardener's command: mutation testing over the run's changes.
    /// Omitted, the run has no harden stage.
    package var harden: String?
    /// How to write a flow in this project — the helpers to use, the accounts
    /// to sign in with — handed to the worker beside the QA procedure.
    package var guide: String?

    package static let fileName = "kiteloop-qa.json"

    package init(run: String, smoke: String, spec: String, storyboard: String,
                 clean: String? = nil, harden: String? = nil, guide: String? = nil) {
        self.run = run
        self.smoke = smoke
        self.spec = spec
        self.storyboard = storyboard
        self.clean = clean
        self.harden = harden
        self.guide = guide
    }

    /// What reading a project's profile found.
    package enum Load: Equatable, Sendable {
        /// No `kiteloop-qa.json` at the root: the project is not onboarded.
        case absent
        /// A file is there and cannot be used, with the reason.
        case unreadable(String)
        case profile(QAProfile)

        package var profile: QAProfile? {
            if case .profile(let profile) = self { return profile }
            return nil
        }
    }

    /// The profile at `projectRoot`, or why there is none.
    package static func load(projectRoot: URL) -> Load {
        let url = projectRoot.appending(path: fileName)
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                ? .unreadable("\(fileName) could not be read") : .absent
        }
        let profile: QAProfile
        do {
            profile = try JSONDecoder().decode(QAProfile.self, from: data)
        } catch {
            return .unreadable("\(fileName) is not a QA profile: \(error.localizedDescription)")
        }
        if let problem = profile.problem { return .unreadable("\(fileName): \(problem)") }
        return .profile(profile)
    }

    /// Why this profile cannot drive a run, or nil when it can.
    package var problem: String? {
        if !run.contains("{spec}") { return "`run` must name the flow it runs with {spec}" }
        if !spec.contains("{id}") { return "`spec` must name the item's file with {id}" }
        if !storyboard.contains("{id}") { return "`storyboard` must name the item's storyboard with {id}" }
        for (field, value) in [("smoke", smoke), ("spec", spec), ("storyboard", storyboard)]
        where value.trimmingCharacters(in: .whitespaces).isEmpty {
            return "`\(field)` is empty"
        }
        if spec.hasPrefix("/") || storyboard.hasPrefix("/") { return "`spec` and `storyboard` are relative to the root" }
        return nil
    }

    /// The item's flow, relative to the root.
    package func specPath(itemID: String) -> String { spec.replacingOccurrences(of: "{id}", with: itemID) }

    /// The item's storyboard, relative to the root.
    package func storyboardPath(itemID: String) -> String {
        storyboard.replacingOccurrences(of: "{id}", with: itemID)
    }

    /// The command that runs the item's flow.
    package func runCommand(itemID: String) -> String {
        run.replacingOccurrences(of: "{spec}", with: specPath(itemID: itemID))
    }
}
