import KiteloopCore
import SwiftUI

struct GitIntegrationView: View {
    /// How long a single git command gets before it is killed. A repo behind a
    /// held index lock, a stalled network mount, or a hook that stops to ask
    /// would otherwise park the caller for ever — see `runGit` below.
    ///
    /// `nonisolated`: it is the default value of a `nonisolated` function's
    /// parameter, and a `View`'s static members are main-actor-isolated by
    /// default, which a nonisolated context cannot reference.
    nonisolated static let gitTimeout: TimeInterval = 10

    let projectPath: String
    @State private var branchReading: GitBranchReading = .notARepository
    @State private var statusLines: [GitStatusLine] = []
    @State private var recentCommits: [GitCommitLine] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Git")
                    .font(.headline)
                Spacer()
                Button(action: { Task { await refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            if branchReading == .notARepository && !isLoading {
                ContentUnavailableView("Not a Git Repository", systemImage: "exclamationmark.triangle", description: Text("No git repository found at project path."))
                    .frame(maxHeight: .infinity)
            } else {
                branchSection
                Divider()
                statusSection
                Divider()
                commitsSection
            }
        }
        .padding()
        .onAppear { Task { await refresh() } }
    }

    private var branchSection: some View {
        HStack {
            Image(systemName: branchReading.symbolName)
                .foregroundStyle(.secondary)
            Text(branchReading.label)
                .font(.body.monospaced())
                .fontWeight(.medium)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Working Tree")
                .font(.subheadline.bold())

            if statusLines.isEmpty {
                Text("Clean")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(statusLines) { line in
                            HStack(spacing: 6) {
                                Text(line.status)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(line.statusColor)
                                    .frame(width: 20, alignment: .leading)
                                Text(line.file)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Commits")
                .font(.subheadline.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recentCommits) { commit in
                        HStack(spacing: 8) {
                            Text(commit.shortHash)
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                            Text(commit.message)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(commit.relativeDate)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private func refresh() async {
        guard !projectPath.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let path = projectPath
        branchReading = Self.classifyBranch(
            branch: await Self.readGit(["branch", "--show-current"], at: path),
            insideWorkTree: await Self.readGit(["rev-parse", "--is-inside-work-tree"], at: path),
            shortCommit: await Self.readGit(["rev-parse", "--short", "HEAD"], at: path)
        )

        statusLines = Self.parseStatus(await Self.runGit(["status", "--porcelain", "-z"], at: path))
        recentCommits = Self.parseLog(
            await Self.runGit(["log", "--oneline", "--format=\(Self.logFormat)", "-10"], at: path)
        )
    }

    /// `git status --porcelain -z` records, as the rows the panel lists.
    ///
    /// `-z` because the plain porcelain quotes and C-escapes any path that is
    /// not plain ASCII — `"na\303\257ve file.txt"` for a name the panel is
    /// meant to show as `naïve file.txt`. The NUL-separated form prints the
    /// path verbatim, at the cost of renames and copies spending a second
    /// record on the old path: that record is consumed here rather than
    /// listed as a file of its own, so a rename is one row naming the new
    /// path.
    nonisolated static func parseStatus(_ output: String) -> [GitStatusLine] {
        var lines: [GitStatusLine] = []
        var records = output.split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
            .makeIterator()

        while let record = records.next() {
            let code = String(record.prefix(2))
            if code.hasPrefix("R") || code.hasPrefix("C") { _ = records.next() }
            let status = code.trimmingCharacters(in: .whitespaces)
            lines.append(GitStatusLine(status: status.isEmpty ? "?" : status,
                                       file: String(record.dropFirst(3))))
        }
        return lines
    }

    /// The fields `logFormat` asks for, as the rows the panel lists.
    ///
    /// The separator is US (`%x1f`), not `|`: a commit subject may hold a
    /// pipe — `fix: handle a|b in parser` — and splitting on one truncated the
    /// subject at it and spilled the rest into the date cell. A subject cannot
    /// hold a control character, so no subject splits here.
    nonisolated static func parseLog(_ output: String) -> [GitCommitLine] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: logSeparator, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return GitCommitLine(shortHash: String(parts[0]), message: String(parts[1]), relativeDate: String(parts[2]))
        }
    }

    nonisolated static let logSeparator: Character = "\u{1f}"
    nonisolated static let logFormat = "%h%x1f%s%x1f%cr"

    /// Runs a git command in `path` on a deadline, off the cooperative pool.
    ///
    /// `SubprocessOutput.runWithDeadline` blocks until the child exits or the
    /// deadline fires, so the call is hopped onto `Task.detached` rather than
    /// awaited directly from a `nonisolated` context — the same shape
    /// `BacklogAutopilot.runDiffStat` already uses for a blocking git call off
    /// its actor. `executable` exists so a test can point this at a stub that
    /// never exits, to drive the deadline arm without waiting out a real
    /// timeout; nothing in the app passes it.
    nonisolated static func runGit(
        _ args: [String],
        at path: String,
        executable: String = "/usr/bin/git",
        timeout: TimeInterval = gitTimeout
    ) async -> String {
        let reading = await readGit(args, at: path, executable: executable, timeout: timeout)
        guard reading.status == 0 else { return "" }
        return reading.output
    }

    /// The same run as `runGit`, reporting what actually happened instead of
    /// collapsing every failure into `""`. The branch read needs the whole
    /// triple: `git branch --show-current` prints nothing on a detached HEAD
    /// and exits 0, which is a different state from a git that exited non-zero
    /// and from one killed at its deadline, and the panel spells all three the
    /// same way when it only has the output text.
    nonisolated static func readGit(
        _ args: [String],
        at path: String,
        executable: String = "/usr/bin/git",
        timeout: TimeInterval = gitTimeout
    ) async -> (status: Int32, output: String, timedOut: Bool) {
        await Task.detached(priority: .userInitiated) {
            SubprocessOutput.runWithDeadline(
                executable: executable,
                arguments: args,
                directory: URL(fileURLWithPath: path),
                timeout: timeout,
                // The output is parsed as an answer, not read as a log — a
                // chatty stderr must not end up mixed into it.
                discardStandardError: true
            )
        }.value
    }

    /// What the three readings say about HEAD, as a pure function of them.
    ///
    /// The order matters: a named branch answers on its own, and everything
    /// below it is about *why* there was no name. A repository is only claimed
    /// on `--is-inside-work-tree` actually printing `true`, so a git that could
    /// not answer is never reported as a missing repository.
    nonisolated static func classifyBranch(
        branch: (status: Int32, output: String, timedOut: Bool),
        insideWorkTree: (status: Int32, output: String, timedOut: Bool),
        shortCommit: (status: Int32, output: String, timedOut: Bool)
    ) -> GitBranchReading {
        if let name = answer(branch) { return .branch(name) }
        if branch.timedOut || insideWorkTree.timedOut { return .unavailable(timedOut: true) }
        guard answer(insideWorkTree) == "true" else { return .notARepository }
        guard branch.status == 0 else { return .unavailable(timedOut: false) }
        guard let commit = answer(shortCommit) else {
            return .unavailable(timedOut: shortCommit.timedOut)
        }
        return .detached(commit: commit)
    }

    /// What a reading said, or `nil` when it said nothing usable — a non-zero
    /// status, a deadline kill (which `runWithDeadline` reports as `-1`), or an
    /// empty line, which is what a detached HEAD prints.
    private nonisolated static func answer(
        _ reading: (status: Int32, output: String, timedOut: Bool)
    ) -> String? {
        guard reading.status == 0 else { return nil }
        let text = reading.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// What Project Settings → Git found when it resolved HEAD. The panel used to
/// hold an empty `String` for all four of these and show the
/// "Not a Git Repository" empty state for any of them.
enum GitBranchReading: Equatable {
    /// HEAD is on a branch, named here.
    case branch(String)
    /// A repository checked out at a commit rather than a branch — the state
    /// of every worktree the autopilot checks out.
    case detached(commit: String)
    /// The project path is not inside a git work tree.
    case notARepository
    /// Git did not answer: a non-zero exit — an index lock held by another
    /// process, a broken repository — or a kill at the deadline.
    case unavailable(timedOut: Bool)

    var label: String {
        switch self {
        case .branch(let name): return name
        case .detached(let commit): return "detached at \(commit)"
        case .notARepository: return "Not a Git Repository"
        case .unavailable(let timedOut):
            return timedOut
                ? "git did not answer within \(Int(GitIntegrationView.gitTimeout))s"
                : "git could not answer"
        }
    }

    var symbolName: String {
        switch self {
        case .branch: return "arrow.triangle.branch"
        case .detached: return "point.topleft.down.curvedto.point.bottomright.up"
        case .notARepository, .unavailable: return "exclamationmark.triangle"
        }
    }
}

struct GitStatusLine: Identifiable {
    let id = UUID()
    let status: String
    let file: String

    var statusColor: Color {
        switch status {
        case "M": return .yellow
        case "A": return .green
        case "D": return .red
        case "?": return .gray
        case "U": return .purple
        default: return .secondary
        }
    }
}

struct GitCommitLine: Identifiable {
    let id = UUID()
    let shortHash: String
    let message: String
    let relativeDate: String
}
