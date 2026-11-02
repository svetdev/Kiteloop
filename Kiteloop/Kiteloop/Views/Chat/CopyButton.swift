import AppKit
import SwiftUI

struct CopyButton: View {
    let text: String
    /// The tooltip: what a click copies.
    var label = "Copy reply"
    @State private var copied = false

    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("copy-button")
        .help(copied ? "Copied!" : label)
    }
}
