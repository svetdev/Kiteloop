import SwiftUI

/// Every open project in one row you can scroll sideways: the selected one
/// filled, the rest outlined, and a spinner beside the name of each one with a
/// run up — so the row reads as the fleet's status board before a project is
/// even tapped. The spinner sits in a slot that is always there, so a name does
/// not shift when its project starts or stops. A long press picks a chip up;
/// where it lands is the order the Mac's tabs take too.
struct ProjectChipRow: View {
    let projects: [Project]
    @Binding var selected: String
    /// A long-press drag dropped on a chip lands the dragged project in front
    /// of it; dropped past the last chip, at the end. Nil disables dragging.
    var onReorder: ((_ project: String, _ before: String?) -> Void)?
    @State private var drops = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(projects) { project in
                        chip(project)
                            .id(project.name)
                            .draggable(project.name)
                            .dropDestination(for: String.self) { items, _ in drop(items, before: project.name) }
                    }
                    if onReorder != nil {
                        Color.clear.frame(width: 44, height: 32)
                            .dropDestination(for: String.self) { items, _ in drop(items, before: nil) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: selected) { withAnimation { proxy.scrollTo(selected, anchor: .center) } }
            .sensoryFeedback(.impact, trigger: drops)
        }
    }

    private func drop(_ items: [String], before: String?) -> Bool {
        guard let onReorder, let moving = items.first, moving != before,
              projects.contains(where: { $0.name == moving }) else { return false }
        drops += 1
        onReorder(moving, before)
        return true
    }

    private func chip(_ project: Project) -> some View {
        let isSelected = project.name == selected
        return Button { selected = project.name } label: {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                spinnerSlot(running: project.isRunning, isSelected: isSelected)
            }
            .modifier(ChipStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(project.isRunning ? "\(project.name), running" : project.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Always the same width, so a name stays put when its project starts.
    private func spinnerSlot(running: Bool, isSelected: Bool) -> some View {
        ZStack {
            if running {
                ProgressView().controlSize(.mini).tint(isSelected ? .white : .accentColor)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Filled for the selected chip, outlined for the rest.
private struct ChipStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.4)))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}
