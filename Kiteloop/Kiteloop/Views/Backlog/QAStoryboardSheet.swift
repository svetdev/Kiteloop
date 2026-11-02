import KiteloopCore
import SwiftUI

/// The storyboard an item's QA run kept, opened from its row at the approval
/// gate: every step QA judged, in order, its caption above its picture — so a
/// UI change is approved on what QA saw, not on a summary of it.
struct QAStoryboardSheet: View {
    let title: String
    let pageURL: URL
    @Environment(\.dismiss) private var dismiss
    /// Read off the main actor when the sheet opens; nil until then, or when
    /// the page has gone.
    @State private var page: QAStoryboardPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("qa-storyboard-done-button")
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(page?.steps ?? [], id: \.number) { stepView($0) }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 480, idealHeight: 720)
        .task {
            let url = pageURL
            page = await Task.detached { QAStoryboardPage.read(url) }.value
        }
    }

    private func stepView(_ step: QAStoryboardPage.Step) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(step.number). \(step.caption)",
                  systemImage: step.failed ? "exclamationmark.triangle.fill" : "camera")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captionColor(step))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("qa-storyboard-step-caption")
            picture(step.picture)
        }
    }

    /// Red for a step QA failed, so it is not read past on the way to Approve.
    private func captionColor(_ step: QAStoryboardPage.Step) -> Color {
        step.failed ? .red : .primary
    }

    @ViewBuilder
    private func picture(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label("Picture missing", systemImage: "photo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
