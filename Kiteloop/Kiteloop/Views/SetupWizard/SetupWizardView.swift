import KiteloopCore
import SwiftUI

struct SetupWizardView: View {
    @State private var viewModel: SetupWizardViewModel
    let onDismiss: () -> Void
    let onComplete: () -> Void

    init(packageResolver: PackageResolver?, repoCloneService: RepoCloneService, globalConfig: GlobalConfigStore, onDismiss: @escaping () -> Void, onComplete: @escaping () -> Void) {
        _viewModel = State(initialValue: SetupWizardViewModel(
            packageResolver: packageResolver,
            repoCloneService: repoCloneService,
            globalConfig: globalConfig
        ))
        self.onDismiss = onDismiss
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                checklistPanel
                Divider()
                agentPanel
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .task { await viewModel.runChecks() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "building.2")
                .font(.title2)
            Text("Kiteloop Setup")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding()
    }

    // MARK: - Left Panel: Checklist

    private var checklistPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Required")
                checkRow("Claude Code CLI", status: viewModel.claudeStatus)
                checkRow("Node.js", status: viewModel.nodeStatus)
                checkRow(viewModel.authMethod.displayName, status: viewModel.authStatus)

                // Not required, and listing it as such made a fresh install look
                // broken to anyone who had not run `gh auth login`. Nothing in
                // the core loop needs it: pull requests are off by default, and
                // cloning only applies to an org knowledge repo.
                sectionHeader("Optional")
                checkRow("GitHub", status: viewModel.githubStatus)
                Text("For opening pull requests and cloning an organisation's agent packages. Kiteloop runs without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !viewModel.requiredRepos.isEmpty {
                    HStack {
                        if clonedCount == viewModel.requiredRepos.count {
                            sectionHeader("Repos (\(clonedCount) ready)")
                        } else {
                            sectionHeader("Repos (\(clonedCount)/\(viewModel.requiredRepos.count))")
                        }
                        Spacer()
                        if clonedCount < viewModel.requiredRepos.count {
                            Button("Clone All") {
                                Task { await viewModel.cloneAllRepos() }
                            }
                            .controlSize(.small)
                            .disabled(viewModel.isCloning)
                        }
                    }
                    ForEach(viewModel.requiredRepos, id: \.self) { repo in
                        repoRow(repo)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Right Panel: Agents

    private var agentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Recommended Agents")
                Text("Selected by default — a worker and a reviewer is what autopilot needs")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(viewModel.availableAgents) { agent in
                    agentRow(agent)
                }

                if viewModel.availableAgents.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "book.closed")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No agent packages found")
                            .font(.headline)
                        Text("Kiteloop ships with a Coder and a Reviewer, so this is unexpected — the built-in packages could not be read. You can point it at your own knowledge folder instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Choose a knowledge folder...") {
                            Task { await viewModel.installKnowledge() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip") { onDismiss() }
                .buttonStyle(.plain)
            if let finishError = viewModel.finishError {
                FooterErrorLabel(finishError)
            }
            Spacer()
            Button("Done") {
                Task {
                    if await viewModel.finish() {
                        onComplete()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canFinish)
        }
        .padding()
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }

    private func checkRow(_ label: String, status: SetupWizardViewModel.CheckStatus) -> some View {
        HStack(spacing: 8) {
            statusIcon(status)
            Text(label)
                .font(.body)
            Spacer()
            switch status {
            case .ok(let detail):
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .missing(let hint):
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            case .checking:
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func repoRow(_ repo: String) -> some View {
        let status = viewModel.repoCloneService.statuses[repo] ?? .notCloned
        let remoteSize = viewModel.repoCloneService.repoSizes[repo]
        return HStack(spacing: 8) {
            switch status {
            case .cloned:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .cloning, .pulling:
                ProgressView()
                    .controlSize(.small)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(msg)
            case .notCloned:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            Text(repo)
                .font(.body.monospaced())
            Spacer()
            switch status {
            case .cloning(let bytes):
                Text(formatBytes(bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .cloned(let size):
                Text(formatBytes(size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .notCloned:
                if let remote = remoteSize {
                    Text("~\(formatBytes(remote))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Clone") {
                    Task { await viewModel.cloneRepo(repo) }
                }
                .controlSize(.small)
            case .failed:
                Button("Retry") {
                    Task { await viewModel.cloneRepo(repo) }
                }
                .controlSize(.small)
            case .pulling:
                EmptyView()
            }
        }
    }

    private static let agentImageMap: [String: String] = [:]

    @ViewBuilder
    private func agentAvatar(_ agent: SetupWizardViewModel.AgentOption) -> some View {
        if let imageName = Self.agentImageMap[agent.id], let nsImage = NSImage(named: imageName) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text(agent.avatar)
                .font(.title3)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 * 1024 {
            return "\(bytes / 1024) KB"
        } else if bytes < 1024 * 1024 * 1024 {
            return "\(bytes / 1024 / 1024) MB"
        } else {
            return String(format: "%.1f GB", Double(bytes) / 1024 / 1024 / 1024)
        }
    }

    private func agentRow(_ agent: SetupWizardViewModel.AgentOption) -> some View {
        let isSelected = viewModel.selectedAgentIDs.contains(agent.id)
        return HStack(spacing: 10) {
            Button {
                if isSelected {
                    viewModel.selectedAgentIDs.remove(agent.id)
                } else {
                    viewModel.selectedAgentIDs.insert(agent.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            agentAvatar(agent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(agent.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ status: SetupWizardViewModel.CheckStatus) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.orange)
        case .checking:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed

    private var canFinish: Bool {
        if case .ok = viewModel.claudeStatus, case .ok = viewModel.nodeStatus {
            return true
        }
        return false
    }

    private var clonedCount: Int {
        viewModel.requiredRepos.filter { viewModel.repoCloneService.isCloned($0) }.count
    }
}
