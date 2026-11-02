import KiteloopCore
import SwiftUI

struct SystemEventDivider: View {
    let event: Message.SystemEvent

    var body: some View {
        HStack(spacing: 8) {
            line
            Label {
                Text(event.detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: iconName)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
            }
            line
        }
        .padding(.vertical, 6)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 1)
    }

    private var iconName: String {
        switch event.kind {
        case .compaction: return "arrow.trianglehead.2.clockwise"
        case .apiRetry: return "arrow.clockwise"
        case .sessionResumed: return "play.circle"
        case .reconnecting: return "antenna.radiowaves.left.and.right"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .compaction: return .orange
        case .apiRetry: return .yellow
        case .sessionResumed: return .green
        case .reconnecting: return .blue
        }
    }
}
