import KiteloopCore
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageContentView: View {
    let data: Data
    @State private var saveFailure: String?

    /// The uniform type of `data`, read from the bytes themselves: the media type the
    /// stream reported is gone by the time the view sees them, so a JPEG or a GIF must
    /// be recognised here or be copied and saved under a claim about it that is false.
    /// Bytes that are not an image at all fall back to PNG.
    static func imageType(for data: Data) -> UTType {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return .png }
        return type
    }

    /// The name the save panel offers — "image." plus the extension the bytes deserve.
    static func saveFilename(for data: Data) -> String {
        "image.\(imageType(for: data).preferredFilenameExtension ?? "png")"
    }

    /// Writes `data` to `url`. Nil when the bytes landed; otherwise what to tell the
    /// user — the file's name and the system's reason — so a save that failed is not
    /// mistaken for one that worked.
    static func writeImage(_ data: Data, to url: URL) -> String? {
        do {
            try data.write(to: url)
            return nil
        } catch {
            return "\(url.lastPathComponent) could not be saved: \(error.localizedDescription)"
        }
    }

    /// What `writeImageToOpen` could not do — the message `writeImage` gave, naming the file.
    struct WriteFailure: Error, Equatable {
        let message: String
    }

    /// Writes `data` into `directory` under a name no earlier call used, ending in the
    /// extension `saveFilename(for:)` gives the bytes, so the viewer opens a JPEG as a
    /// JPEG and a second image never replaces a first that is still open.
    static func writeImageToOpen(_ data: Data, in directory: URL) -> Result<URL, WriteFailure> {
        let url = directory.appending(path: "\(UUID().uuidString)-\(saveFilename(for: data))")
        if let message = writeImage(data, to: url) { return .failure(WriteFailure(message: message)) }
        return .success(url)
    }

    var body: some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 500, maxHeight: 400)
                .cornerRadius(8)
                .onTapGesture(count: 2) { openImage() }
                .contextMenu {
                    Button("Open in Preview") { openImage() }
                    Button("Copy Image") {
                        NSPasteboard.general.clearContents()
                        let type = NSPasteboard.PasteboardType(Self.imageType(for: data).identifier)
                        NSPasteboard.general.setData(data, forType: type)
                    }
                    Button("Save As...") { saveImage() }
                }
                .alert("Couldn't write image", isPresented: Binding(
                    get: { saveFailure != nil },
                    set: { if !$0 { saveFailure = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(saveFailure ?? "")
                }
        } else {
            Text("Failed to decode image")
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.red.opacity(0.05))
                .cornerRadius(4)
        }
    }

    private func saveImage() {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "save image to disk")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.imageType(for: data)]
        panel.nameFieldStringValue = Self.saveFilename(for: data)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFailure = Self.writeImage(data, to: url)
    }

    /// Writes the bytes to a temporary file and opens it at full size in the default viewer.
    private func openImage() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Kiteloop Images")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch Self.writeImageToOpen(data, in: directory) {
        case .success(let url): NSWorkspace.shared.open(url)
        case .failure(let failure): saveFailure = failure.message
        }
    }
}
