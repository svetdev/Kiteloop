import KiteloopCore
import SwiftUI

/// The sheet a routine is made or changed in: its name, the agent, the prompt,
/// when it falls, and — for one that should stay quiet when there is nothing
/// to do — the check that decides.
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
    let onSave: (RoutineDraft) -> Void

    @State private var draft: RoutineDraft
    @Environment(\.dismiss) private var dismiss

    init(target: Target, agentNames: [String], onSave: @escaping (RoutineDraft) -> Void) {
        self.target = target
        self.agentNames = agentNames
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
                RoutineEditorFields(draft: $draft, agentNames: Self.agentChoices(agentNames, current: draft.agent))
                    .padding(KiteloopTokens.Spacing.xl)
            }
            Divider()
            actions
        }
        .frame(width: 540, height: 700)
        .accessibilityIdentifier("routine-editor")
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

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xl) {
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
            field("Schedule") { RoutineScheduleFields(draft: $draft) }
            field("Only when", note: "Optional. A shell command run in the project folder first: if it fails or prints nothing the prompt is not sent, and what it prints goes to the agent under the prompt.") {
                TextField("gh pr list --search review-requested:@me", text: $draft.precheck)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("routine-editor-precheck")
            }
            Toggle("Armed — runs on its schedule once saved", isOn: $draft.armed)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("routine-editor-armed")
        }
    }

    private func field<Content: View>(_ title: String, note: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            Text(title).font(.subheadline.weight(.medium))
            content()
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
