import SwiftUI

/// The line that says whether to wait or to pull: refreshing now, updated so
/// many seconds ago and refreshing itself, or what failed and what to do. A
/// failure gets a tinted banner with a button that tries again at once, so
/// "can't connect" is never a red sentence a person has to interpret.
struct RefreshStatusBar: View {
    let state: RefreshState
    let retry: () -> Void
    @State private var now = Date()

    var body: some View {
        Group {
            if let problem = state.problem {
                banner(problem)
            } else {
                HStack(spacing: 6) {
                    if state.phase == .refreshing {
                        ProgressView().controlSize(.mini)
                    } else if state.isStale(now: now) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    }
                    Text(state.line(now: now)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .task {
            // The "12s ago" needs a clock that ticks even when nothing else changes.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func banner(_ problem: ConnectionProblem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: problem.kind))
                .font(.title3)
                .foregroundStyle(.red)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.title).font(.subheadline.weight(.semibold))
                Text(problem.advice).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Try now", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func icon(for kind: ConnectionProblem.Kind) -> String {
        switch kind {
        case .unreachable: "wifi.exclamationmark"
        case .unauthorized: "key.slash"
        case .outdatedMac: "arrow.down.app"
        case .serverError: "exclamationmark.triangle"
        case .unreadable: "questionmark.text.page"
        case .other: "exclamationmark.circle"
        }
    }
}
