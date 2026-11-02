import SwiftUI

struct SidebarRow<Icon: View>: View {
    let icon: Icon
    let label: String
    var subtitle: String? = nil
    var badge: Int? = nil
    var badgeColor: Color = .orange
    var isSelected: Bool = false
    var infoAction: (() -> Void)? = nil
    var splitAction: (() -> Void)? = nil
    /// Shown as a hover ✕ at the trailing edge — for rows that are meant to be
    /// closed rather than configured, like a forked-aside agent.
    var dismissAction: (() -> Void)? = nil
    var dismissHelp: String = "Dismiss"
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 3, height: 20)

            icon
                .frame(width: KiteloopTokens.Sidebar.iconSize, height: KiteloopTokens.Sidebar.iconSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isHovered, let splitAction {
                Button(action: splitAction) {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Pin to top of a split view")
                .transition(.opacity)
            }

            if isHovered, let infoAction {
                Button(action: infoAction) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            if isHovered, let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(dismissHelp)
                .transition(.opacity)
            }

            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding)
        .frame(height: KiteloopTokens.Sidebar.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.md)
                .fill(isSelected ? KiteloopTokens.Sidebar.selectedBg : isHovered ? KiteloopTokens.Sidebar.hoverBg : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { hovering in
            withAnimation(KiteloopTokens.Anim.hover) { isHovered = hovering }
        }
    }
}
