import KiteloopCore
import SwiftUI

/// The sheet a routine is made or changed in: its name, the agent, the prompt,
/// what fires it — a schedule, an event or a changed folder — the check that
/// decides whether there is anything to do, which chat it goes into and what
/// it may spend.
struct RoutineEditorSheet: View {
    /// What the sheet is open on.
    enum Target: Identifiable {
        case new(agent: String)
        case existing(Routine)

        var id: String {
            switch self {
            case .new: return "__new__"
            case .existing(let routine): return routine.id
            }
        }

        var routine: Routine? {
            if case .existing(let routine) = self { return routine }
            return nil
        }

        var draft: RoutineDraft {
            switch self {
            case .new(let agent): return RoutineDraft(agent: agent)
            case .existing(let routine): return RoutineDraft(routine: routine)
            }
        }
    }

    let target: Target
    let agentNames: [String]
    /// The file the routines' webhooks are kept in.
    let hooksURL: URL
    let onSave: (RoutineDraft) -> Void

    @State private var draft: RoutineDraft
    /// The webhooks that fire the routine being edited; nil for a new routine
    /// and until the file has been read.
    @State private var hookNames: [String]?
    @Environment(\.dismiss) private var dismiss

    init(target: Target, agentNames: [String], hooksURL: URL = RoutineHooks.defaultURL,
         onSave: @escaping (RoutineDraft) -> Void) {
        self.target = target
        self.agentNames = agentNames
        self.hooksURL = hooksURL
        self.onSave = onSave
        _draft = State(initialValue: target.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.routine == nil ? "New Routine" : "Edit Routine")
                .font(.title3.weight(.semibold))
                .padding(KiteloopTokens.Spacing.xl)
            Divider()
            ScrollView {
                RoutineEditorFields(draft: $draft, agentNames: Self.agentChoices(agentNames, current: draft.agent),
                                    hookNames: hookNames)
                    .padding(KiteloopTokens.Spacing.xl)
            }
            Divider()
            actions
        }
        .frame(width: 540, height: 700)
        .accessibilityIdentifier("routine-editor")
        .task { await loadHooks() }
    }

    /// Reads which webhooks fire this routine, off the main actor: their
    /// names only — the file keeps no secret to show.
    private func loadHooks() async {
        guard let id = target.routine?.id else { return }
        let url = hooksURL
        hookNames = await Task.detached { RoutineHooks.names(firing: id, at: url) }.value
    }

    private var actions: some View {
        HStack(spacing: KiteloopTokens.Spacing.lg) {
            Text(draft.problems.first ?? draft.scheduleWords ?? "")
                .font(.caption)
                .foregroundStyle(draft.problems.isEmpty ? Color.secondary : Color.orange)
                .lineLimit(2)
                .accessibilityIdentifier("routine-editor-status")
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(target.routine == nil ? "Create" : "Save") {
                onSave(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.problems.isEmpty)
            .accessibilityIdentifier("routine-editor-save")
        }
        .padding(KiteloopTokens.Spacing.xl)
    }

    /// The agents the picker offers: the team's, and the one the routine
    /// already names when that agent is no longer on it — so opening the sheet
    /// does not quietly point the routine at somebody else.
    static func agentChoices(_ team: [String], current: String) -> [String] {
        current.isEmpty || team.contains(current) ? team : team + [current]
    }
}

/// The editor's fields, apart from the sheet around them.
struct RoutineEditorFields: View {
    @Binding var draft: RoutineDraft
    let agentNames: [String]
    /// The webhooks that fire this routine; nil when there is nothing to say
    /// about them — a routine not yet saved.
    var hookNames: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xl) {
            who
            field("Trigger") { RoutineTriggerFields(draft: $draft) }
            precheck
            conversation
            field("Budget", note: "Optional. Once its runs have cost this much in the day or the month, the runs it starts by itself are refused until the next one. Run Now still works.") {
                RoutineBudgetFields(draft: $draft)
            }
            if let hookNames { webhook(hookNames) }
            Toggle(Self.armedLabel(for: draft.kind), isOn: $draft.armed)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("routine-editor-armed")
        }
    }

    /// What it is called, who it goes to and what it says.
    @ViewBuilder private var who: some View {
        field("Name") {
            TextField("Morning brief", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("routine-editor-name")
        }
        field("Agent") {
            Picker("Agent", selection: $draft.agent) {
                ForEach(agentNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("routine-editor-agent")
        }
        field("Prompt", note: "Sent to the agent as if you had typed it in its chat.") {
            editor($draft.prompt, height: 96, identifier: "routine-editor-prompt")
        }
    }

    private var precheck: some View {
        field("Only when", note: "Optional. A shell command run in the project folder first: if it fails or prints nothing the prompt is not sent, and what it prints goes to the agent under the prompt.") {
            TextField("gh pr list --search review-requested:@me", text: $draft.precheck)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("routine-editor-precheck")
        }
    }

    private var conversation: some View {
        field("Conversation", note: "A fresh chat each run keeps the agent's context from growing; it opens with a note of how the last run went.") {
            Picker("Conversation", selection: $draft.conversation) {
                Text("Continue its chat").tag(Routine.Conversation.continues)
                Text("Start a fresh chat").tag(Routine.Conversation.fresh)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("routine-editor-conversation")
        }
    }

    private func webhook(_ names: [String]) -> some View {
        field("Webhook", note: "Webhooks are made and revoked over the control API. A webhook's secret is shown once, when it is made, and never here.") {
            Text(Self.webhookWords(names))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("routine-editor-webhook")
        }
    }

    /// The arming switch's label: what an armed routine of this kind does.
    static func armedLabel(for kind: RoutineDraft.Kind) -> String {
        switch kind {
        case .clock: return "Armed — runs on its schedule once saved"
        case .event: return "Armed — runs when the event happens once saved"
        case .folder: return "Armed — runs when the folder changes once saved"
        }
    }

    /// Whether a webhook fires the routine, and which: names only.
    static func webhookWords(_ names: [String]) -> String {
        switch names.count {
        case 0: return "No webhook fires this routine."
        case 1: return "Fired by the webhook \(names[0])."
        default: return "Fired by the webhooks \(names.joined(separator: ", "))."
        }
    }

    private func field<Content: View>(_ title: String, note: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            Text(title).font(.subheadline.weight(.medium))
            content()
            if let note { RoutineFieldNote(note) }
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat, identifier: String) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(KiteloopTokens.Spacing.sm)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm)
                .strokeBorder(Color.primary.opacity(KiteloopTokens.Opacity.strong)))
            .accessibilityIdentifier(identifier)
    }
}

/// What fires a routine: a schedule, an event of one kind, or a change in a
/// folder — the choice, then the fields of the kind chosen, with what is wrong
/// with them underneath.
struct RoutineTriggerFields: View {
    @Binding var draft: RoutineDraft

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            Picker("Trigger", selection: $draft.kind) {
                Text("On a schedule").tag(RoutineDraft.Kind.clock)
                Text("On an event").tag(RoutineDraft.Kind.event)
                Text("When a folder changes").tag(RoutineDraft.Kind.folder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("routine-editor-kind")
            switch draft.kind {
            case .clock: RoutineScheduleFields(draft: $draft)
            case .event: event
            case .folder: folder
            }
            RoutineFieldProblems(problems: draft.triggerProblems, identifier: "routine-editor-trigger-problems")
        }
    }

    private var event: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            Picker("Event", selection: $draft.event) {
                ForEach(RoutineDraft.eventChoices(current: draft.event), id: \.self) {
                    Text(RoutineDraft.eventLabel($0)).tag($0)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("routine-editor-event")
            RoutineFieldNote("Runs each time this happens in the routine's project. What happened goes to the agent under the prompt.")
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            TextField("notes/inbox", text: $draft.watch)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("routine-editor-watch")
            RoutineFieldNote("A folder inside the project, written relative to it. Runs when a file directly inside it is added, removed, renamed or replaced.")
        }
    }
}

/// A routine's own budget: whether it has one, and then its ceiling and
/// whether that is for a day or a month.
struct RoutineBudgetFields: View {
    @Binding var draft: RoutineDraft

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            Toggle("Limit what this routine spends", isOn: $draft.limitsSpend)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("routine-editor-budget")
            if draft.limitsSpend {
                ceiling
                RoutineFieldProblems(problems: draft.budgetProblems, identifier: "routine-editor-budget-problems")
            }
        }
    }

    private var ceiling: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Text("Up to $")
            TextField("5.00", text: $draft.ceiling)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .accessibilityIdentifier("routine-editor-ceiling")
            Text("a")
            Picker("Period", selection: $draft.period) {
                Text("day").tag(SpendBudget.Period.day)
                Text("month").tag(SpendBudget.Period.month)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("routine-editor-period")
        }
    }
}

/// The small grey line under a field that says what it does.
struct RoutineFieldNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// What is wrong with a field, under it, in the colour the sheet's own
/// status line names a problem in. Draws nothing when nothing is wrong.
struct RoutineFieldProblems: View {
    let problems: [String]
    let identifier: String

    var body: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
                ForEach(problems, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }
}

/// When a routine falls: once a day at a time, or every so many minutes
/// between two times, on the days chosen.
struct RoutineScheduleFields: View {
    @Binding var draft: RoutineDraft

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            Picker("Pattern", selection: $draft.pattern) {
                Text("Once a day").tag(RoutineDraft.Pattern.daily)
                Text("Repeatedly").tag(RoutineDraft.Pattern.interval)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("routine-editor-pattern")
            if draft.pattern == .daily { daily } else { interval }
            days
        }
    }

    private var daily: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Text("At")
            time($draft.atMinute, identifier: "routine-editor-at")
        }
    }

    private var interval: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Text("Every")
            TextField("30", value: $draft.everyMinutes, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .accessibilityIdentifier("routine-editor-every")
            Text("min, from")
            time($draft.fromMinute, identifier: "routine-editor-from")
            Text("until")
            time($draft.untilMinute, identifier: "routine-editor-until")
        }
    }

    private var days: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            ForEach(RoutineDraft.dayOrder, id: \.self) { day in
                let isOn = draft.days.contains(day)
                Button(Self.dayLabel(day)) { draft.days.formSymmetricDifference([day]) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .frame(width: 40, height: 26)
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .background(isOn ? Color.accentColor : Color.primary.opacity(KiteloopTokens.Opacity.light),
                                in: RoundedRectangle(cornerRadius: KiteloopTokens.Radius.md))
                    .accessibilityIdentifier("routine-editor-day-\(day)")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func time(_ minute: Binding<Int>, identifier: String) -> some View {
        DatePicker("", selection: Self.date(for: minute), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier(identifier)
    }

    /// A minute of the day as the date a time picker edits: that time today.
    static func date(for minute: Binding<Int>, calendar: Calendar = .current) -> Binding<Date> {
        Binding(
            get: { calendar.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60,
                                 second: 0, of: Date()) ?? Date() },
            set: { minute.wrappedValue = calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }
        )
    }

    /// `Mon` … `Sun` for a `Calendar` weekday number.
    static func dayLabel(_ weekday: Int) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday - 1]
    }
}
