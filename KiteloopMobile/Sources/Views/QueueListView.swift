import SwiftUI

/// The backlog in the order that is its priority — every `now` item first,
/// tagged with its epic, then each epic's `later` items — with the verbs the API has.
/// Pushed from a project's screen, so it takes the project and owns no stack.
struct QueueListView: View {
    @Bindable var connection: ConnectionStore
    let project: String
    @State private var model = QueueViewModel()
    @State private var showDone = false
    @State private var filing = false

    private var client: ControlClient { ControlClient(baseURL: connection.baseURL, token: connection.token) }

    private var shown: [BacklogItem] { showDone ? model.items : model.items.filter(\.isOpen) }

    var body: some View {
        List {
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            let now = model.nowItems.filter { showDone || $0.isOpen }
            Section("Now") {
                if now.isEmpty {
                    Text("Nothing is marked now").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(now) { item in row(item, epic: item.epic) }
            }
            ForEach(model.epics.filter { epic in epic.items.contains { showDone || $0.isOpen } }, id: \.name) { epic in
                Section(epic.name) {
                    ForEach(epic.items.filter { showDone || $0.isOpen }) { item in
                        row(item)
                    }
                }
            }
        }
        .navigationDestination(for: BacklogItem.self) { item in
            ItemDetailView(model: model, client: client, item: item)
        }
        .navigationTitle("Queue — \(project)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Toggle("Show done", isOn: $showDone) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { filing = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add an idea")
            }
        }
        .sheet(isPresented: $filing) {
            FileIdeaSheet(project: project) { title, note, groom in
                await model.file(client, title: title, note: note, groom: groom)
            }
        }
        .refreshable { await model.refresh(client) }
        .task {
            model.project = project
            await model.refresh(client)
        }
    }

    @ViewBuilder
    /// `epic` is named on a row listed outside its epic — under Now.
    private func row(_ item: BacklogItem, epic: String? = nil) -> some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? item.id).font(.callout)
                HStack(spacing: 6) {
                    Text(item.status ?? "").font(.caption2).foregroundStyle(.secondary)
                    if let size = item.size { Text(size).font(.caption2).foregroundStyle(.tertiary) }
                    if let epic { Text(epic).font(.caption2).foregroundStyle(.blue) }
                    if item.isRetired { Text("retired").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                }
                whyNot(item)
            }
        }
        .swipeActions(edge: .leading) {
                        if item.isOpen {
                            Button("Top") { Task { await model.moveToTop(client, item) } }.tint(.blue)
                            Button(item.flippedLane.capitalized) { Task { await model.flipLane(client, item) } }.tint(.indigo)
                        }
                    }
        .swipeActions(edge: .trailing) {
            if item.status == "draft" {
                Button("Ready") { Task { await model.groom(client, item, to: "ready") } }.tint(.green)
            } else if item.status == "ready" {
                Button("Draft") { Task { await model.groom(client, item, to: "draft") } }.tint(.gray)
            }
            if item.offersRelease {
                Button("Release") { Task { await model.release(client, item) } }.tint(.orange)
            }
        }
    }
    /// Why the Mac would not start the item. A ready item it judged gives this
    /// refresh's `notReady`; the grooming ledger's refusal, which a regroom can
    /// leave stale, speaks only for an item it did not judge — a draft.
    @ViewBuilder
    private func whyNot(_ item: BacklogItem) -> some View {
        if item.isJudged {
            if item.cannotStart {
                ForEach(item.notReady ?? [], id: \.self) { reason in
                    Text(reason).font(.caption2).foregroundStyle(.orange)
                }
            }
        } else if let refusal = model.refusal(for: item) {
            Text("refused — \(refusal.check ?? ""): \(refusal.reason ?? "")")
                .font(.caption2).foregroundStyle(.orange)
        }
    }
}

/// One item, drilled into: the groomed detail as the Mac's gates read it.
struct ItemDetailView: View {
    let model: QueueViewModel
    let client: ControlClient
    let item: BacklogItem
    @State private var detail: ItemDetailReply?
    @State private var detailFailure: String?

    var body: some View {
        List {
            Section {
                Text(item.title ?? item.id).font(.headline)
                LabeledContent("Status", value: item.status ?? "—")
                if let size = item.size { LabeledContent("Size", value: size) }
                if let epic = item.epic { LabeledContent("Epic", value: epic) }
                LabeledContent("Lane", value: item.lane ?? "later")
                LabeledContent("Id", value: item.id)
            }
            if let detailFailure {
                Section { Text("Couldn't load this item's detail — \(detailFailure)").font(.callout).foregroundStyle(.red) }
            }
            if let verify = detail?.verify, !verify.isEmpty {
                Section("Verify") {
                    Text(verify).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let what = detail?.what { Section("What") { Text(what).font(.callout) } }
            if let approach = detail?.approach { Section("How") { Text(approach).font(.callout) } }
            if let criteria = detail?.acceptanceCriteria, !criteria.isEmpty {
                Section("Validation") { ForEach(criteria, id: \.self) { Text("· " + $0).font(.callout) } }
            }
            if let out = detail?.outOfScope, !out.isEmpty {
                Section("Out of scope") { ForEach(out, id: \.self) { Text("· " + $0).font(.callout) } }
            }
            if let notes = detail?.notes, !notes.isEmpty {
                Section("Notes") { Text(notes).font(.callout) }
            }
        }
        .navigationTitle(item.id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            switch await model.detail(client, item) {
            case .success(let reply): detail = reply
            case .failure(let failure): detailFailure = failure.reason
            }
        }
    }
}

/// An idea filed from the phone: a title, what it is about, and whether the
/// Mac should groom it straight away. It lands as a draft either way.
struct FileIdeaSheet: View {
    let project: String
    /// Files it; nil when it went through, else the Mac's reason.
    let file: (String, String, Bool) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var groom = true
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("What it is about (optional)", text: $note, axis: .vertical)
                    .lineLimit(3...8)
                Toggle("Groom it on the Mac", isOn: $groom)
                Section {
                    Text(groom
                         ? "Filed as a draft in Inbox; the Mac writes its verify, size and detail. You still promote it to ready."
                         : "Filed as a draft in Inbox, for grooming later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem {
                    Text("Not filed — \(problem)").font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add to \(project)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { Task { await submit() } }
                        .disabled(sending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        problem = await file(title, note, groom)
        if problem == nil { dismiss() }
    }
}
