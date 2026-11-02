import PhotosUI
import SwiftUI

/// A conversation the way Claude Code shows one: the agent's own words as
/// prose, each tool call as one quiet line naming the tool and what it was
/// pointed at, thinking left out, and a spinner at the bottom while the agent
/// is still working. Tool lines that follow each other fold into a count.
/// Pushed onto the project's navigation stack, under a solid bar: the back
/// button closes the conversation.
struct ChatView: View {
    @Bindable var model: AgentsViewModel
    let client: ControlClient
    /// What should change, typed on an open plan card before Keep planning.
    @State private var planFeedback = ""
    /// The answer being typed to an open question.
    @State private var questionAnswer = ""
    @State private var confirmingNewConversation = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photoProblem: String?
    /// The composer's keyboard, put away so a long reply can be read.
    @FocusState private var composing: Bool

    private var working: Bool {
        Self.showsWorking(state: model.chatAgent.flatMap { agent in model.agents.first { $0.id == agent.id } }?.state,
                          streamed: model.live ? model.streamedWorking : nil,
                          refreshFailure: model.error)
    }

    /// The spinner shows only while the last read succeeded: once a refresh
    /// fails, "working" is the Mac's word from before it stopped answering.
    /// Live, the stream's word wins over the agent list's, which lags.
    nonisolated static func showsWorking(state: String?, streamed: Bool? = nil, refreshFailure: String?) -> Bool {
        guard refreshFailure == nil else { return false }
        return streamed ?? (state == "working")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    ForEach(TranscriptRow.rows(from: model.transcript)) { row in
                        rowView(row).id(row.id).listRowSeparator(.hidden)
                    }
                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("working").listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.transcript.count) {
                    proxy.scrollTo(working ? "working" : (model.transcript.last?.listID ?? ""), anchor: .bottom)
                }
                // A reply growing in place changes no count; follow it too.
                .onChange(of: model.transcript.last?.text) {
                    proxy.scrollTo(working ? "working" : (model.transcript.last?.listID ?? ""), anchor: .bottom)
                }
            }
            if !model.live && model.chatAgent != nil && model.error == nil {
                Label("Not live — updating every few seconds", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let failure = model.error {
                Text("Couldn't refresh this conversation — \(failure)")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let failure = model.sendFailure {
                Text("Not sent — \(failure)")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let photo = model.photo {
                HStack(spacing: 8) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text("\(photo.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(photo.jpeg.count), countStyle: .file))")
                        .font(.caption)
                    Button { model.photo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Remove the photo")
                    Spacer()
                }
                .padding(.horizontal)
            }
            if let photoProblem {
                Text(photoProblem).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            if !model.quickReplies.isEmpty {
                quickReplyRow
            }
            HStack {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Image(systemName: "photo.badge.plus").font(.title3)
                }
                .accessibilityLabel("Attach a photo")
                TextField(working ? "Queue a message…" : "Message \(model.chatAgent?.name ?? "agent")…",
                          text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                if composing {
                    Button { composing = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.title3)
                    }
                    .accessibilityLabel("Hide the keyboard")
                }
                if working && model.draft.isEmpty && model.photo == nil {
                    Button {
                        Task { await model.interrupt(client) }
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop the agent")
                    .accessibilityIdentifier("chat-stop")
                } else {
                    Button {
                        Task { await model.send(client) }
                    } label: {
                        Image(systemName: model.sending ? "ellipsis.circle" : "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(model.sending || (model.draft.isEmpty && model.photo == nil))
                }
            }
            .padding()
        }
        .onChange(of: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            pickedPhoto = nil
            Task { await attach(item) }
        }
        .navigationTitle(model.chatAgent?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        // A file tool's line pushes the FileRoute the project screen's stack already opens.
        .navigationDestination(for: ChangesRoute.self) { _ in
            ChangesView(project: model.project, client: client)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ChangesRoute()) { Image(systemName: "plusminus") }
                    .accessibilityLabel("Uncommitted changes")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { confirmingNewConversation = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
            }
        }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmingNewConversation,
                            titleVisibility: .visible) {
            Button("New conversation", role: .destructive) { Task { await model.startNewConversation(client) } }
        } message: {
            Text("\(model.chatAgent?.name ?? "The agent") forgets this conversation, on the Mac too — as /clear does there.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow) -> some View {
        switch row.kind {
        case .prose(let sender, let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(sender).font(.caption2).foregroundStyle(.tertiary)
                MarkdownText(text: text)
            }
        case .tools(let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
                    if let path = line.path {
                        // A file tool's line opens the file it touched.
                        NavigationLink(value: FileRoute(path: path)) {
                            Label(line.text, systemImage: "doc.text").font(.caption).lineLimit(1)
                        }
                    } else {
                        Label(line.text, systemImage: "wrench").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if lines.count > 3 {
                    Text("+\(lines.count - 3) more tool calls").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case .error(let text):
            Text(text).font(.caption).foregroundStyle(.red)
        case .plan(let messageID, let text, let answer):
            planCard(messageID: messageID, text: text, answer: answer)
        case .question(let requestID, let text, let open):
            questionCard(requestID: requestID, text: text, open: open)
        }
    }

    /// The Mac's one-tap replies: sent at once while the agent is idle, added
    /// to the draft while it works or once something is typed.
    private var quickReplyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.quickReplies, id: \.self) { reply in
                    Button(reply) { Task { await model.useQuickReply(client, reply, working: working) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.sending)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 6)
    }

    /// Loads the picked photo and readies it to send, or says why it can't.
    private func attach(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let photo = PhotoAttachment.prepared(from: data) else {
            photoProblem = "That photo could not be read."
            return
        }
        photoProblem = nil
        model.photo = photo
    }

    /// A Plan-mode agent's plan, with the Mac card's three answers while it is open.
    @ViewBuilder
    private func planCard(messageID: String, text: String, answer: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer == nil ? "Plan · waiting for you" : "Plan").font(.caption.bold()).foregroundStyle(.tint)
            MarkdownText(text: text)
            if let answer {
                Text(TranscriptRow.planAnswerLabel(answer)).font(.caption.bold()).foregroundStyle(.green)
            } else {
                Button("Approve and build (Auto)") {
                    Task { await model.answerPlan(client, messageID: messageID, answer: "approveAuto") }
                }
                .buttonStyle(.borderedProminent)
                Button("Approve and build (Accept Edits)") {
                    Task { await model.answerPlan(client, messageID: messageID, answer: "approveAcceptEdits") }
                }
                .buttonStyle(.bordered)
                TextField("What should change?", text: $planFeedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Keep planning") {
                    let feedback = planFeedback
                    planFeedback = ""
                    Task { await model.answerPlan(client, messageID: messageID, answer: "keepPlanning", feedback: feedback) }
                }
            }
        }
        .padding(12)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// A question the agent stopped to ask, answered in free text while open.
    @ViewBuilder
    private func questionCard(requestID: String, text: String, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(open ? "\(model.chatAgent?.name ?? "The agent") is asking you" : "Asked you")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text(text).font(.callout).textSelection(.enabled)
            if open {
                TextField("Your answer", text: $questionAnswer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Answer") {
                    let answer = questionAnswer
                    questionAnswer = ""
                    Task { await model.answerQuestion(client, requestID: requestID, answer: answer) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One tool call's line, and the file it touched when it was a file tool.
struct ToolLine: Equatable {
    let text: String
    let path: String?
}

/// The transcript folded for reading: prose stays, tool calls that follow each
/// other become one block, thinking and system chatter drop out.
struct TranscriptRow: Identifiable {
    enum Kind {
        case prose(sender: String, text: String)
        case tools([ToolLine])
        case error(String)
        case plan(messageID: String, text: String, answer: String?)
        case question(requestID: String, text: String, open: Bool)
    }

    /// A plan or a question: a card the phone can answer.
    static func card(_ message: TranscriptMessage) -> TranscriptRow {
        guard message.kind == "question" else {
            return TranscriptRow(id: message.listID, kind: .plan(
                messageID: message.listID, text: message.text ?? "", answer: message.plan?.answer))
        }
        return TranscriptRow(id: message.listID, kind: .question(
            requestID: message.question?.request ?? "", text: message.text ?? "",
            open: message.question?.open == true))
    }

    /// What an answered plan card says it was answered with.
    static func planAnswerLabel(_ answer: String) -> String {
        switch answer {
        case "approveAuto": "Approved · building in Auto"
        case "approveAcceptEdits": "Approved · building in Accept Edits"
        default: "Kept planning"
        }
    }
    let id: String
    let kind: Kind

    static func rows(from messages: [TranscriptMessage]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var pendingTools: [ToolLine] = []
        var pendingID = ""
        func flushTools() {
            if !pendingTools.isEmpty { rows.append(TranscriptRow(id: pendingID, kind: .tools(pendingTools))) }
            pendingTools = []
        }
        for message in messages {
            switch message.kind {
            case "tool":
                if pendingTools.isEmpty { pendingID = message.listID }
                pendingTools.append(ToolLine(text: message.text ?? "", path: message.path))
            case "text":
                flushTools()
                if let text = message.text, !text.isEmpty {
                    rows.append(TranscriptRow(id: message.listID, kind: .prose(sender: message.sender ?? "", text: text)))
                }
            case "error":
                flushTools()
                rows.append(TranscriptRow(id: message.listID, kind: .error(message.text ?? "")))
            case "plan", "question":
                flushTools()
                rows.append(card(message))
            default:
                continue
            }
        }
        flushTools()
        return rows
    }
}
