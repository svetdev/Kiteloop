import KiteloopCore
import AppKit
import SwiftUI

struct RepoResolutionPopover: View {
    let agentName: String
    let missingRepos: [String]
    let cloneService: RepoCloneService
    let repoStatusStore: RepoStatusStore
    let org: String

    @Environment(\.dismiss) private var dismiss

    /// Why the folder the human last picked could not be linked, held so the
    /// panel closing is not the whole of the answer. Cleared by a link that
    /// works.
    @State private var linkRefusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Missing Repos")
                .font(.headline)
            Text("\(agentName) needs these repos to work at full capacity:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(missingRepos, id: \.self) { repo in
                repoEntry(repo)
            }

            if let linkRefusal {
                Text(linkRefusal)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(width: 300)
        .onChange(of: missingRepos.count) { _, newCount in
            if newCount == 0 { dismiss() }
        }
    }

    /// The row and, under it, whatever the last clone attempt has to say.
    @ViewBuilder
    private func repoEntry(_ repo: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            repoRow(repo)
            if let reason = Self.failureReason(for: cloneService.statuses[repo]) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The reason a clone gave up, or nil for every status that is not a
    /// failure — a repo that was never cloned, one being cloned or pulled and
    /// one that is there says nothing here.
    static func failureReason(for status: RepoCloneService.CloneStatus?) -> String? {
        guard case .failed(let reason) = status else { return nil }
        return reason
    }

    /// Clones `repo`, then refreshes the store — in that order, in one task.
    /// The refresh used to be its own task that slept a second first, so it
    /// read the status while the clone was still `.cloning` (a blobless clone
    /// runs for minutes) and nothing looked again once the clone settled: the
    /// repo stayed listed as missing until the human reopened the sidebar.
    ///
    /// `gitExecutable` and `timeout` are passed straight through to
    /// `RepoCloneService.clone`, which exposes them for tests.
    @MainActor
    static func cloneThenRefresh(
        repo: String,
        org: String,
        cloneService: RepoCloneService,
        repoStatusStore: RepoStatusStore,
        gitExecutable: String = "/usr/bin/git",
        timeout: TimeInterval = RepoCloneService.gitTimeout
    ) async {
        await cloneService.clone(repo: repo, org: org, gitExecutable: gitExecutable, timeout: timeout)
        repoStatusStore.refresh()
    }

    /// Why `url` cannot stand in for `repo`, or nil when it can. A local clone
    /// is a directory with a `.git` inside it; anything else is refused by
    /// name, rather than by the panel simply closing.
    static func linkRefusal(forFolder url: URL, repo: String) -> String? {
        let gitDir = url.appending(path: ".git")
        guard !FileManager.default.fileExists(atPath: gitDir.path(percentEncoded: false)) else { return nil }
        return "\(url.lastPathComponent) is not a git clone — it has no .git inside, so \(repo) was not linked."
    }

    @ViewBuilder
    private func repoRow(_ repo: String) -> some View {
        HStack {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.orange)
            Text(repo)
                .font(.system(.body, design: .monospaced))

            Spacer()

            if case .cloning = cloneService.statuses[repo] {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Clone") {
                    Task {
                        await Self.cloneThenRefresh(
                            repo: repo,
                            org: org,
                            cloneService: cloneService,
                            repoStatusStore: repoStatusStore
                        )
                    }
                }
                .controlSize(.small)

                Button("Link...") {
                    linkFolder(repo)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func linkFolder(_ repo: String) {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "link local repo: \(repo)")
        let panel = NSOpenPanel()
        panel.title = "Select local \(repo) repo"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the root of your local '\(repo)' git clone"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let refusal = Self.linkRefusal(forFolder: url, repo: repo) {
            linkRefusal = refusal
            return
        }
        linkRefusal = nil
        repoStatusStore.linkRepo(repo, to: url)
    }
}
