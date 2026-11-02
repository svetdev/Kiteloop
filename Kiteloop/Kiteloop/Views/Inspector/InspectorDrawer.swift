import SwiftUI

/// Which companion surface the Inspector drawer is showing.
enum InspectorTab: String, CaseIterable, Identifiable {
    case preview = "Preview"
    case insights = "Insights"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .preview: "safari"
        case .insights: "chart.bar"
        }
    }
}

/// The right-hand companion drawer: a single sliding panel that holds the
/// "glance while you work" surfaces — Preview and Insights — behind a tab
/// switch. Slides in/out as a unit and coexists with the center work area.
/// (Traces live in the bottom Console, next to Activity.)
struct InspectorDrawer: View {
    @Bindable var webPreviewVM: WebPreviewViewModel
    let metricStore: TaskMetricStore
    let projectPath: String
    let projectName: String
    let onPopOutWebPreview: () -> Void
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, KiteloopTokens.Spacing.sm)
            .accessibilityIdentifier("inspector-tab-picker")

            Divider()
            content
        }
        .background(.background)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .preview:
            WebPreviewPanel(viewModel: webPreviewVM, onPopOut: onPopOutWebPreview)
        case .insights:
            TaskInsightsView(
                store: metricStore,
                projectPath: projectPath,
                projectName: projectName,
                embedded: true
            )
        }
    }
}
