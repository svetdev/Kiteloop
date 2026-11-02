import ActivityKit
import SwiftUI
import WidgetKit

@main
struct KiteloopMobileWidgets: WidgetBundle {
    var body: some Widget {
        AgentActivityWidget()
    }
}

/// An agent's turn at a glance: who, where it is, and its newest line.
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(context.attributes.agentName) · \(context.attributes.project)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    stateIcon(context.state)
                }
                Text(context.state.status).font(.headline)
                if !context.state.line.isEmpty {
                    Text(context.state.line).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
                }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.agentName).font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.trailing) { stateIcon(context.state) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.state.status).font(.headline)
                        Text(context.state.line).font(.caption).lineLimit(2)
                    }
                }
            } compactLeading: {
                Text(String(context.attributes.agentName.prefix(1))).font(.caption.bold())
            } compactTrailing: {
                stateIcon(context.state)
            } minimal: {
                stateIcon(context.state)
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: AgentActivityAttributes.ContentState) -> some View {
        if state.working {
            Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.blue)
        } else if state.status == "Done" {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        }
    }
}
