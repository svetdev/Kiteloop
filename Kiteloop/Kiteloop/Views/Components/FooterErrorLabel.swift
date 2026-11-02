import SwiftUI

/// A save or read error at the foot of a settings page, drawn in full.
///
/// These messages end with the part that matters — the reason, or what to do
/// about it — so the label has no line cap: it wraps, grows vertically rather
/// than being squeezed by the button beside it, and can be selected to copy.
struct FooterErrorLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
