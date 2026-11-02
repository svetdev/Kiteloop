import Foundation
import os.log

private let log = Logger(subsystem: "ai.kasatkin.kiteloop", category: "repo-clone")

@Observable
@MainActor
package class RepoCloneService {
    package enum CloneStatus: Equatable {
        case notCloned
        case cloning(bytesOnDisk: Int64)
        case cloned(sizeOnDisk: Int64)
        case pulling
        case failed(String)
    }

    package private(set) var statuses: [String: CloneStatus] = [:]
    package private(set) var repoSizes: [String: Int64] = [:]

    package var orgName: String?

    /// How long a git subprocess may run before it's killed. Generous — a real
    /// blobless clone of a large repo can legitimately take minutes — but
    /// bounded, so a `git` that stops to ask a question it will never get an
    /// answer to (an unknown host key, a passphrase) cannot hang the wizard
    /// forever.
    package static let gitTimeout: TimeInterval = 600

    private var baseDir: URL {
        KiteloopProject.workspacesDir(orgName: orgName)
    }

    package func repoDir(for repo: String) -> URL {
        baseDir.appending(path: repo)
    }

    package func isCloned(_ repo: String) -> Bool {
        let gitDir = repoDir(for: repo).appending(path: ".git")
        return FileManager.default.fileExists(atPath: gitDir.path(percentEncoded: false))
    }

    package func refreshStatuses(repos: [String]) {
        for repo in repos {
            if isCloned(repo) {
                let size = directorySize(repoDir(for: repo))
                statuses[repo] = .cloned(sizeOnDisk: size)
            } else if statuses[repo] == nil {
                statuses[repo] = .notCloned
            }
        }
    }

    package func fetchRepoSizes(repos: [String], org: String) async {
        for repo in repos where repoSizes[repo] == nil {
            if let size = await fetchGitHubRepoSize(org: org, repo: repo) {
                repoSizes[repo] = size
            }
        }
    }

    package func cloneIfNeeded(repos: [String], org: String) async {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
        for repo in repos where !isCloned(repo) {
            await clone(repo: repo, org: org)
        }
    }

    /// `gitExecutable` and `timeout` exist for tests: a real clone always uses
    /// the defaults, but a test can point `gitExecutable` at a process that
    /// hangs and `timeout` at a fraction of a second to drive the failing path
    /// without waiting on a real clone.
    package func clone(
        repo: String,
        org: String,
        gitExecutable: String = "/usr/bin/git",
        timeout: TimeInterval = RepoCloneService.gitTimeout
    ) async {
        statuses[repo] = .cloning(bytesOnDisk: 0)
        log.info("[clone] starting blobless clone: \(org)/\(repo)")

        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }

        let url = "git@github.com:\(org)/\(repo).git"
        let dest = repoDir(for: repo)
        let destPath = dest.path(percentEncoded: false)

        let progressTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let size = self.gitDirSize(dest)
                await MainActor.run { self.statuses[repo] = .cloning(bytesOnDisk: size) }
            }
        }

        let outcome = await runGit(
            arguments: ["clone", "--filter=blob:none", url, destPath],
            executable: gitExecutable,
            timeout: timeout
        )
        progressTask.cancel()

        switch outcome {
        case .success:
            let finalSize = directorySize(dest)
            statuses[repo] = .cloned(sizeOnDisk: finalSize)
            log.info("[clone] completed: \(repo) (\(finalSize / 1024 / 1024) MB)")
        case .failed:
            statuses[repo] = .failed("Clone failed")
            log.error("[clone] failed: \(repo)")
        case .timedOut:
            statuses[repo] = .failed("Clone timed out after \(Int(timeout))s")
            log.error("[clone] timed out: \(repo)")
        }
    }

    package func pullAll() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir.path(percentEncoded: false)),
              let contents = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for dir in contents {
            let gitDir = dir.appending(path: ".git")
            guard fm.fileExists(atPath: gitDir.path(percentEncoded: false)) else { continue }
            let repo = dir.lastPathComponent
            statuses[repo] = .pulling
            let outcome = await runGit(arguments: ["-C", dir.path(percentEncoded: false), "pull", "--ff-only"])
            let size = directorySize(dir)
            statuses[repo] = outcome == .success ? .cloned(sizeOnDisk: size) : .failed("Pull failed")
        }
    }

    package func cloneFull(repo: String, org: String) async {
        let dir = repoDir(for: repo)
        if isCloned(repo) {
            statuses[repo] = .cloning(bytesOnDisk: directorySize(dir))
            let outcome = await runGit(arguments: ["-C", dir.path(percentEncoded: false), "fetch", "--unshallow"])
            let size = directorySize(dir)
            statuses[repo] = outcome == .success ? .cloned(sizeOnDisk: size) : .failed("Fetch unshallow failed")
        } else {
            await clone(repo: repo, org: org)
        }
    }

    // MARK: - Git subprocess

    /// What a `runGit` call came to. Split from a bare `Bool` so a caller can
    /// tell a `git` that refused (a bad remote, an auth failure) from one that
    /// had to be killed past `timeout` — the distinction `clone(repo:org:)`
    /// needs to put a truthful message in front of the wizard.
    package enum GitOutcome: Equatable {
        case success
        case failed
        case timedOut
    }

    /// `executable` and `timeout` are injectable so a test can drive a process
    /// that hangs (`/bin/sleep`, say) against a short deadline instead of a
    /// real `git`. The spawn, the null-device stdin and the kill past the
    /// deadline — descendants included — are `SubprocessOutput.runWithDeadline`;
    /// this used to carry its own copy of each.
    package func runGit(
        arguments: [String],
        executable: String = "/usr/bin/git",
        timeout: TimeInterval = RepoCloneService.gitTimeout
    ) async -> GitOutcome {
        await Task.detached(priority: .utility) {
            // A git that stopped to ask a question — an unknown host key, a
            // passphrase — would otherwise hang until the deadline killed it;
            // the runner gives it EOF on stdin, and this keeps it from asking.
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            let result = SubprocessOutput.runWithDeadline(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                discardStandardError: true
            )
            if result.timedOut { return .timedOut }
            return result.status == 0 ? .success : .failed
        }.value
    }

    // MARK: - Private

    nonisolated private func gitDirSize(_ repoURL: URL) -> Int64 {
        let packDir = repoURL.appending(path: ".git/objects/pack")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: packDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return directorySize(repoURL.appending(path: ".git"))
        }
        var total: Int64 = 0
        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    nonisolated private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        guard fm.fileExists(atPath: path) else { return 0 }
        // Include .git/ — for blobless clones, most data is in .git/objects/pack/
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func fetchGitHubRepoSize(org: String, repo: String) async -> Int64? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let result = try? SubprocessOutput.run(
                    executable: "/usr/bin/env",
                    arguments: ["gh", "api", "repos/\(org)/\(repo)", "--jq", ".size"],
                    environment: RunEnvironment.environment(projectRoot: nil)
                ), result.status == 0,
                      // GitHub API returns size in KB
                      let kb = Int64(result.trimmedOutput) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: kb * 1024)
            }
        }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(statuses: [String: CloneStatus] = [:], repoSizes: [String: Int64] = [:], orgName: String? = nil) {
        self.statuses = statuses
        self.repoSizes = repoSizes
        self.orgName = orgName
    }
}
