import SwiftUI

/// Where a file tool's line in the chat leads.
struct FileRoute: Hashable { let path: String }
/// The chat's Changes button.
struct ChangesRoute: Hashable {}

/// What the agents have changed in the project so far, before anything
/// reaches a gate: each file with its git letters, then the patch colored the
/// way the gate review colors one.
struct ChangesView: View {
    let project: String
    let client: ControlClient
    @State private var reply: WorkspaceChangesReply?
    @State private var problem: String?

    var body: some View {
        List {
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            } else if let reply {
                let files = reply.files ?? []
                if files.isEmpty {
                    Text("Nothing changed since the last commit.").foregroundStyle(.secondary)
                } else {
                    Section("\(files.count) file\(files.count == 1 ? "" : "s")") {
                        ForEach(files) { file in
                            NavigationLink(value: FileRoute(path: file.path)) {
                                HStack {
                                    Text(ChangesView.label(file.status)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(file.path).font(.callout.monospaced()).lineLimit(1)
                                }
                            }
                        }
                    }
                    let preview = DiffPreview(patch: reply.patch ?? "", truncated: reply.truncated)
                    if !preview.lines.isEmpty {
                        Section(preview.header) { DiffText(preview: preview) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    /// git's two letters as a word: "modified", "new", "deleted".
    static func label(_ status: String?) -> String {
        switch status?.trimmingCharacters(in: .whitespaces) {
        case "??", "A": "new"
        case "D": "deleted"
        case "R": "renamed"
        default: "modified"
        }
    }

    private func load() async {
        do {
            reply = try await client.get(client.query("/v1/workspace/changes", [("project", project)]),
                                         as: WorkspaceChangesReply.self)
            problem = nil
        } catch {
            problem = NowViewModel.refusalText(error)
        }
    }
}

/// One file the agent named, read-only with line numbers — or a folder,
/// whose entries open in turn.
struct FileView: View {
    let project: String
    let path: String
    let client: ControlClient
    @State private var reply: WorkspaceFileReply?
    @State private var problem: String?

    var body: some View {
        Group {
            if let problem {
                ContentUnavailableView("Can't show this file", systemImage: "doc.questionmark", description: Text(problem))
            } else if let entries = reply?.entries, reply?.kind == "directory" {
                List(entries) { entry in
                    NavigationLink(value: FileRoute(path: FileView.join(path, entry.name))) {
                        Label(entry.name, systemImage: entry.directory == true ? "folder" : "doc")
                    }
                }
            } else if let text = reply?.text {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(FileView.numbered(text).enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(line.number).foregroundStyle(.tertiary).frame(minWidth: 32, alignment: .trailing)
                                Text(line.text)
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle((path as NSString).lastPathComponent.isEmpty ? project : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Each line with its number, as an editor's gutter shows it.
    static func numbered(_ text: String) -> [(number: String, text: String)] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.enumerated().map { (String($0.offset + 1), $0.element) }
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : (folder.hasSuffix("/") ? folder + name : folder + "/" + name)
    }

    private func load() async {
        do {
            reply = try await client.get(client.query("/v1/workspace/file", [("project", project), ("path", path)]),
                                         as: WorkspaceFileReply.self)
            problem = nil
        } catch {
            problem = NowViewModel.refusalText(error)
        }
    }
}

/// What the Mac's web preview shows for the project, pulled down to refresh.
struct PreviewView: View {
    let project: String
    let client: ControlClient
    @State private var image: UIImage?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(8)
            } else if let problem {
                ContentUnavailableView("No preview", systemImage: "safari", description: Text(problem))
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle("Web preview")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let data = try await client.data(client.query("/v1/preview/screenshot", [("project", project)]))
            image = UIImage(data: data)
            problem = image == nil ? "The Mac sent something that is not an image." : nil
        } catch {
            problem = NowViewModel.refusalText(error)
            image = nil
        }
    }
}
