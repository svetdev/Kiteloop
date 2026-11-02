import Foundation
import KiteloopCore

/// Puts the bundled demo project on disk and wires it up as a ready-to-run
/// sample: a git repo carrying a pre-groomed `BACKLOG.md`, with
/// `.kiteloop/team.json` and `.kiteloop/autopilot-config.json` pre-assigning
/// the two bundled example agents as worker and reviewer.
///
/// Autopilot's done gates (`RunWorkEvidence`) read git — a run's branch, its
/// diff against `HEAD` — so a sample that is not a real repository would fail
/// review on its very first item for reasons that have nothing to do with the
/// work. `install` makes it one.
enum SampleProjectService {
    enum InstallError: Error, Equatable {
        /// The bundled `examples/sample-project` folder could not be found —
        /// an unpackaged debug run outside the repo checkout, or a release
        /// build whose bundle is missing the resource.
        case bundledSampleNotFound
        case gitInitFailed
    }

    /// Fixed rather than user-chosen: the "one click" promise is that the same
    /// click always lands on the same project, so a second click reopens the
    /// user's own run history instead of minting a copy beside it.
    static var defaultDestinationURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/sample-project")
    }

    /// Copies the bundled sample into place the first time it's asked for and
    /// returns its URL. A destination that already exists is left completely
    /// alone — including its `team.json` and autopilot config — because by
    /// then it may hold the user's own run history, and a re-click must not
    /// discard it.
    ///
    /// `bundledSource` and `destination` are parameters, not the defaults
    /// baked in, so a test can point both at temporary directories instead of
    /// touching `~/.kiteloop` or depending on the app bundle being built.
    @discardableResult
    static func install(
        destination: URL = defaultDestinationURL,
        bundledSource: URL? = nil
    ) throws -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path(percentEncoded: false)) else {
            return destination
        }

        guard let source = bundledSource ?? KnowledgePathResolver.resolveBuiltInPath()?.appending(path: "sample-project"),
              fm.fileExists(atPath: source.appending(path: "BACKLOG.md").path(percentEncoded: false)) else {
            throw InstallError.bundledSampleNotFound
        }

        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.copyItem(at: source, to: destination)
        // The configs are part of the sample, so they land before the initial
        // commit — install leaves a clean tree, not two stray files.
        try writeTeamConfig(at: destination)
        try writeAutopilotConfig(at: destination)
        try initializeGitRepository(at: destination)
        return destination
    }

    // MARK: - Private

    private static func initializeGitRepository(at dest: URL) throws {
        let root = dest.path(percentEncoded: false)
        let steps: [[String]] = [
            ["-C", root, "init", "-q"],
            ["-C", root, "add", "-A"],
            ["-C", root,
             "-c", "user.name=Kiteloop",
             "-c", "user.email=kiteloop@localhost",
             "commit", "-q", "-m", "Initial commit"],
        ]
        for arguments in steps {
            guard SubprocessOutput.git(arguments).status == 0 else {
                throw InstallError.gitInitFailed
            }
        }
    }

    private static func writeTeamConfig(at dest: URL) throws {
        let project = KiteloopProject(rootURL: dest)
        try project.ensureKiteloopDirectory()
        let refs = [
            PackageAgentRef(id: "example-coder", ref: "builtin:example-coder", version: nil, overrides: nil),
            PackageAgentRef(id: "example-reviewer", ref: "builtin:example-reviewer", version: nil, overrides: nil),
        ]
        let data = try encoded(PackageTeamConfig(agents: refs))
        try AtomicFileWriter.write(data, to: project.teamConfigURL)
    }

    /// The same shape `BacklogAutopilot`'s own `AutopilotConfig` reads —
    /// `workerAgentID` and `reviewerAgentID` are the only fields it needs, and
    /// every other field there is optional, so a file carrying just these two
    /// keys loads exactly as if the rest had been left at their defaults.
    private struct AutopilotSeedConfig: Codable {
        var workerAgentID: String?
        var reviewerAgentID: String?
    }

    private static func writeAutopilotConfig(at dest: URL) throws {
        let project = KiteloopProject(rootURL: dest)
        let config = AutopilotSeedConfig(workerAgentID: "example-coder", reviewerAgentID: "example-reviewer")
        let data = try encoded(config)
        try AtomicFileWriter.write(data, to: project.autopilotConfigURL)
    }

    private static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
