import KiteloopCore
import SwiftUI

struct BranchBarView: View {
    let tree: ConversationTree
    /// A turn is streaming: its reply is written into the line on screen, so
    /// moving to another line has to wait for it.
    let isStreaming: Bool
    let onSwitchToMain: () -> Void
    let onSwitchToBranch: (UUID) -> Void
    let onDeleteBranch: (UUID) -> Void
    let onRenameBranch: (UUID, String) -> Void

    @State private var pendingDeleteBranch: ConversationBranch?
    @State private var pendingRenameBranch: ConversationBranch?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.orange)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("main") {
                            onSwitchToMain()
                        }
                        .buttonStyle(.plain)
                        .disabled(isStreaming)
                        .font(.caption.bold())
                        .foregroundStyle(tree.activeBranchID == nil ? .primary : .secondary)
                        .fixedSize()
                        .id(ScrollTarget.main)

                        ForEach(tree.branches) { branch in
                            Button(branch.name) {
                                onSwitchToBranch(branch.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(isStreaming)
                            .font(.caption)
                            .foregroundStyle(tree.activeBranchID == branch.id ? .primary : .secondary)
                            .underline(tree.activeBranchID == branch.id)
                            .fixedSize()
                            .id(ScrollTarget.branch(branch.id))
                            .contextMenu {
                                Button("Rename Branch…") {
                                    renameText = branch.name
                                    pendingRenameBranch = branch
                                }
                                Button("Delete Branch…", role: .destructive) { pendingDeleteBranch = branch }
                            }
                        }
                    }
                }
                .onAppear { proxy.scrollTo(Self.scrollTarget(in: tree)) }
                .onChange(of: tree.activeBranchID) { proxy.scrollTo(Self.scrollTarget(in: tree)) }
            }

            Spacer()

            if tree.branchCount > 0 {
                Text("\(tree.branchCount) branch\(tree.branchCount == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            "Delete branch \u{201C}\(pendingDeleteBranch?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { pendingDeleteBranch != nil },
                set: { if !$0 { pendingDeleteBranch = nil } }
            ),
            presenting: pendingDeleteBranch
        ) { branch in
            Button("Delete", role: .destructive) {
                pendingDeleteBranch = nil
                onDeleteBranch(branch.id)
            }
            Button("Cancel", role: .cancel) { pendingDeleteBranch = nil }
        } message: { branch in
            Text("The transcript on \(branch.name) will be gone. Main and other branches are kept.")
        }
        .alert(
            "Rename branch \u{201C}\(pendingRenameBranch?.name ?? "")\u{201D}",
            isPresented: Binding(
                get: { pendingRenameBranch != nil },
                set: { if !$0 { pendingRenameBranch = nil } }
            ),
            presenting: pendingRenameBranch
        ) { branch in
            TextField("Branch name", text: $renameText)
            Button("Rename") {
                pendingRenameBranch = nil
                onRenameBranch(branch.id, renameText)
            }
            Button("Cancel", role: .cancel) { pendingRenameBranch = nil }
        }
    }

    /// What the bar's scrolling row identifies its buttons by: main, or a branch.
    enum ScrollTarget: Hashable {
        case main
        case branch(UUID)
    }

    /// The button the row scrolls into view: the branch you are on, else main.
    static func scrollTarget(in tree: ConversationTree) -> ScrollTarget {
        tree.activeBranchID.map(ScrollTarget.branch) ?? .main
    }
}
