import KiteloopCore
import SwiftUI

struct AgentTaskPanelView: View {
    let tasks: [AgentTask]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text("Agent Tasks")
                        .font(.headline)
                    Spacer()
                    Text("\(completedCount)/\(tasks.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if tasks.isEmpty {
                    Text("No tasks tracked yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(tasks) { task in
                                    AgentTaskRow(task: task)
                                        .id(task.id)
                                }
                            }
                        }
                        .frame(maxHeight: 140)
                        .onAppear { reveal(Self.taskIDToReveal(in: tasks), with: proxy) }
                        .onChange(of: Self.taskIDToReveal(in: tasks)) { _, id in reveal(id, with: proxy) }
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var completedCount: Int {
        tasks.filter { $0.status == .completed }.count
    }

    /// How many lines a task's description shows: one while folded, all of
    /// them once the row is clicked open.
    static func descriptionLineLimit(isExpanded: Bool) -> Int? {
        isExpanded ? nil : 1
    }

    /// The task the list scrolls into view: the first one in progress, else
    /// the first pending one; nil once every task is completed, so the list
    /// stays where it is.
    static func taskIDToReveal(in tasks: [AgentTask]) -> String? {
        (tasks.first { $0.status == .inProgress } ?? tasks.first { $0.status == .pending })?.id
    }

    private func reveal(_ id: String?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

private struct AgentTaskRow: View {
    let task: AgentTask
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.caption)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.subject)
                    .font(.caption)
                    .fontWeight(task.status == .inProgress ? .semibold : .regular)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .completed ? .secondary : .primary)
                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(AgentTaskPanelView.descriptionLineLimit(isExpanded: isExpanded))
                        .help(task.description)
                }
            }

            Spacer()

            if task.status == .inProgress {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(task.status == .inProgress ? Color.accentColor.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !task.description.isEmpty else { return }
            isExpanded.toggle()
        }
    }

    private var statusIcon: String {
        switch task.status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}
