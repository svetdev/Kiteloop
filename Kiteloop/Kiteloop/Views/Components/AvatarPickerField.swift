import KiteloopCore
import SwiftUI
import AppKit

struct AvatarPickerField: View {
    @Binding var selection: String?
    var projectURL: URL?
    @State private var showingPicker = false

    var body: some View {
        HStack {
            Text("Avatar")
            Spacer()
            Button(action: { showingPicker = true }) {
                HStack(spacing: 8) {
                    if let av = selection, !av.isEmpty {
                        if av.containsOnlyEmoji {
                            Text(av).font(.title2)
                        } else {
                            customImageThumb(av)
                        }
                        Text(displayName(av))
                            .font(.body)
                    } else {
                        Image(systemName: "face.smiling")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Auto (by role)")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPicker, arrowEdge: .trailing) {
                AvatarGridPicker(selection: $selection, projectURL: projectURL)
            }
        }
    }

    @ViewBuilder
    private func customImageThumb(_ filename: String) -> some View {
        if let url = imageURL(filename), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(Circle())
        } else {
            Image(systemName: "photo")
                .frame(width: 24, height: 24)
        }
    }

    private func imageURL(_ filename: String) -> URL? {
        guard let projectURL else { return nil }
        let url = projectURL.appendingPathComponent(".kiteloop/avatars/\(filename)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func displayName(_ av: String) -> String {
        if av.containsOnlyEmoji { return av }
        return av.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".png", with: "")
            .replacingOccurrences(of: ".jpg", with: "")
            .capitalized
    }
}

struct AvatarGridPicker: View {
    @Binding var selection: String?
    var projectURL: URL?
    @Environment(\.dismiss) private var dismiss

    static let defaultEmoji: [String] = [
        "🧙‍♂️", "🧙‍♀️", "👺", "👹", "🤖", "🦉", "🐉", "🧛", "🧟", "🦹",
        "🦸", "🧝‍♂️", "🧝‍♀️", "🔮", "⚔️", "🛡️", "🏰", "👾", "🐺", "🦅",
        "🐍", "🕷️", "💀", "👁️", "🌑", "⚡", "🔥", "🌊", "🎨", "🧩",
        "🐛", "🦇", "🐙", "🦂", "🗡️", "🏹"
    ]

    private let columns = Array(repeating: GridItem(.fixed(48), spacing: 8), count: 8)

    @State private var customImages: [String] = []
    @State private var uploadError: String?

    /// A name in `directory` no file already holds, suffixing before the
    /// extension so a second `avatar.png` is written as `avatar-2.png` rather
    /// than failing the copy and leaving the old image installed.
    static func availableName(for filename: String, in directory: URL) -> String {
        let manager = FileManager.default
        let taken: (String) -> Bool = { candidate in
            manager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        guard taken(filename) else { return filename }

        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        var suffix = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            if !taken(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Copies `source` into the project's avatar folder under a free name and
    /// answers the name it wrote.
    static func installCustomImage(from source: URL, intoProjectAt projectURL: URL) throws -> String {
        let avatarDir = projectURL.appendingPathComponent(".kiteloop/avatars")
        try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
        let filename = availableName(for: source.lastPathComponent, in: avatarDir)
        try FileManager.default.copyItem(at: source, to: avatarDir.appendingPathComponent(filename))
        return filename
    }

    /// What the picker shows when an image could not be installed.
    static func uploadErrorMessage(for error: Error) -> String {
        "Couldn't add that image: \(error.localizedDescription)"
    }

    /// Where an upload would install, decided before the file panel runs: with
    /// no project root there is nowhere to put the image, and saying so beats
    /// running the panel and discarding what was picked.
    enum UploadDestination: Equatable {
        case project(URL)
        case nowhere(message: String)

        static let noProjectMessage = "No project is open, so there's nowhere to install an avatar."
    }

    static func uploadDestination(forProjectAt projectURL: URL?) -> UploadDestination {
        guard let projectURL else { return .nowhere(message: UploadDestination.noProjectMessage) }
        return .project(projectURL)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Choose Avatar")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        autoCell

                        ForEach(Self.defaultEmoji, id: \.self) { emoji in
                            emojiCell(emoji)
                        }
                    }

                    if !customImages.isEmpty {
                        Divider()
                        Text("Custom")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(customImages, id: \.self) { filename in
                                customImageCell(filename)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            if let uploadError {
                Label(uploadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            HStack {
                Button("Upload Image…") { uploadCustomImage() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 16)
        .frame(width: 440, height: 380)
        .onAppear { loadCustomImages() }
    }

    private var autoCell: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "sparkles")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .overlay {
                if selection == nil {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .frame(width: 42, height: 42)
                }
            }
        }
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = nil
            dismiss()
        }
    }

    private func emojiCell(_ emoji: String) -> some View {
        ZStack {
            Text(emoji)
                .font(.system(size: 26))
                .frame(width: 38, height: 38)
        }
        .overlay {
            if selection == emoji {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .frame(width: 42, height: 42)
            }
        }
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = emoji
            dismiss()
        }
    }

    @ViewBuilder
    private func customImageCell(_ filename: String) -> some View {
        if let url = imageURL(filename), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay {
                    if selection == filename {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .frame(width: 42, height: 42)
                    }
                }
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = filename
                    dismiss()
                }
        }
    }

    private func uploadCustomImage() {
        guard case .project(let projectRoot) = Self.uploadDestination(forProjectAt: projectURL) else {
            uploadError = UploadDestination.noProjectMessage
            return
        }
        guard let url = chooseImageFile() else { return }

        switch Result(catching: { try Self.installCustomImage(from: url, intoProjectAt: projectRoot) }) {
        case .success(let filename):
            uploadError = nil
            // Re-read the folder rather than appending: the grid's ForEach is
            // keyed on the name itself, so a name must appear exactly once.
            loadCustomImages()
            selection = filename
            dismiss()
        case .failure(let error):
            // Nothing was installed, so nothing is selected — say why instead.
            uploadError = Self.uploadErrorMessage(for: error)
        }
    }

    /// The image the person picks in the open panel; nil when they cancel.
    private func chooseImageFile() -> URL? {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "choose avatar image")
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an avatar image"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func loadCustomImages() {
        guard let projectURL else { return }
        let avatarDir = projectURL.appendingPathComponent(".kiteloop/avatars")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: avatarDir.path) else { return }
        customImages = files.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "gif", "webp"].contains(ext)
        }.sorted()
    }

    private func imageURL(_ filename: String) -> URL? {
        guard let projectURL else { return nil }
        let url = projectURL.appendingPathComponent(".kiteloop/avatars/\(filename)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
