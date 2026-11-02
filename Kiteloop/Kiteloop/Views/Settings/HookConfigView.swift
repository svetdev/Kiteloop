import SwiftUI

struct HookConfigView: View {
    let projectPath: String
    /// Where this page reports work typed but not yet saved, so leaving it
    /// asks first. See `SettingsEditGuard`.
    let editGuard: SettingsEditGuard
    @State private var hookEntries: [HookEntry] = []
    @State private var selectedEvent: String = "PreToolUse"
    @State private var saveError: String?
    @State private var unreadableMessage: String?
    /// What `fingerprint` was when the page last loaded or saved. An edit is
    /// the two disagreeing.
    @State private var savedFingerprint: String = ""

    /// The events the panel offers when adding a hook. A settings file may bind
    /// a hook to any event Claude Code supports, so this is not the whole set —
    /// see `eventChoices(for:)`.
    static let eventTypes = ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hook Configuration")
                .font(.headline)
            Text("Hooks run shell commands before/after tool execution. Stored in .claude/settings.json.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Picker("Event", selection: $selectedEvent) {
                    ForEach(Self.eventTypes, id: \.self) { Text($0) }
                }
                .frame(width: 180)

                Spacer()

                Button("Add Hook") {
                    hookEntries.append(HookEntry(event: selectedEvent, matcher: "", command: "", timeout: 10))
                }
            }

            if hookEntries.isEmpty {
                if unreadableMessage == nil {
                    ContentUnavailableView("No Hooks Configured", systemImage: "terminal", description: Text("Add a hook to run scripts when agents use tools."))
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else {
                List {
                    ForEach($hookEntries) { $entry in
                        HStack(alignment: .top) {
                            HookEntryRow(entry: $entry)
                            Button(role: .destructive) {
                                hookEntries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Remove this hook. Nothing changes on disk until Save.")
                            .accessibilityIdentifier("settings-hook-delete-\(entry.event)-\(entry.matcher)")
                        }
                    }
                    .onDelete { indexSet in
                        hookEntries.remove(atOffsets: indexSet)
                    }
                }
            }

            HStack {
                if let message = unreadableMessage ?? saveError {
                    FooterErrorLabel(message)
                }
                Spacer()
                Button("Save") { saveHooks() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear { loadHooks() }
        .onChange(of: fingerprint) { _, current in
            editGuard.report(isDirty: current != savedFingerprint, for: .hooks)
        }
    }

    /// What the page has on screen, as text a baseline can be compared with.
    /// `HookEntry` carries the rule it was read from as `[String: Any]` and so
    /// is not `Equatable`; the four fields a row edits are what an edit shows
    /// up in.
    private var fingerprint: String {
        hookEntries
            .map { "\($0.event)\u{1}\($0.matcher)\u{1}\($0.command)\u{1}\($0.timeout.map(String.init) ?? "")" }
            .joined(separator: "\u{2}")
    }

    private func markSaved() {
        savedFingerprint = fingerprint
        editGuard.report(isDirty: false, for: .hooks)
    }

    private func loadHooks() {
        guard !projectPath.isEmpty else { return }
        let settingsURL = URL(fileURLWithPath: projectPath).appending(path: ".claude/settings.json")
        switch Self.classify(try? Data(contentsOf: settingsURL)) {
        case .absent:
            hookEntries = []
            unreadableMessage = nil
        case .unreadable(let message):
            hookEntries = []
            unreadableMessage = message
        case .parsed(let settings):
            hookEntries = Self.hookEntries(in: settings)
            unreadableMessage = nil
        }
        markSaved()
    }

    private func saveHooks() {
        guard !projectPath.isEmpty else { return }
        let settingsURL = URL(fileURLWithPath: projectPath).appending(path: ".claude/settings.json")

        let existing: [String: Any]
        switch Self.classify(try? Data(contentsOf: settingsURL)) {
        case .absent:
            existing = [:]
        case .unreadable(let message):
            unreadableMessage = message
            saveError = nil
            return
        case .parsed(let settings):
            existing = settings
        }

        let claudeDir = URL(fileURLWithPath: projectPath).appending(path: ".claude")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        do {
            let merged = Self.merged(hookEntries, into: existing)
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            saveError = nil
            unreadableMessage = nil
            markSaved()
        } catch {
            saveError = "Couldn't save hooks: \(error.localizedDescription)"
        }
    }

    /// What the bytes of `.claude/settings.json` are: no file at all, bytes the
    /// panel cannot represent, or a settings object it can edit. `nil` bytes are
    /// a file that is not there — a project with no settings yet.
    static func classify(_ data: Data?) -> HookSettingsFile {
        guard let data else { return .absent }
        let prefix = "Couldn't read .claude/settings.json"
        let suffix = "Fix or remove the file before saving hooks."
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return .unreadable("\(prefix): the file is not valid JSON. \(suffix)")
        }
        guard let settings = json as? [String: Any] else {
            return .unreadable("\(prefix): its top level is not a JSON object. \(suffix)")
        }
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else {
            return .unreadable("\(prefix): its \"hooks\" value is not an object. \(suffix)")
        }
        return .parsed(settings)
    }

    /// The events a row's menu offers for an entry bound to `event`: the known
    /// events, plus the entry's own when the settings file bound it to one the
    /// panel does not list. Without it the menu has no item matching the
    /// selection, so it draws blank and the first pick rebinds the hook.
    static func eventChoices(for event: String) -> [String] {
        eventTypes.contains(event) ? eventTypes : eventTypes + [event]
    }

    /// The rows the panel shows for a parsed settings object. Every entry
    /// remembers the rule and hook definition it was read from, so a save can
    /// write back the keys the panel does not model.
    static func hookEntries(in settings: [String: Any]) -> [HookEntry] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var entries: [HookEntry] = []
        for (event, value) in hooks {
            guard let rules = value as? [[String: Any]] else { continue }
            for (index, rule) in rules.enumerated() {
                guard let defs = rule["hooks"] as? [[String: Any]] else { continue }
                let ruleID = UUID()
                entries.append(contentsOf: defs.map { def in
                    HookEntry(
                        event: event,
                        matcher: rule["matcher"] as? String ?? "",
                        command: def["command"] as? String ?? "",
                        timeout: def["timeout"] as? Int,
                        origin: HookOrigin(ruleID: ruleID, ruleIndex: index, rule: rule, definition: def)
                    )
                })
            }
        }
        return entries
    }

    /// The settings object to write: `settings` with only the hook events the
    /// panel could read replaced by the edited entries. An event whose value the
    /// panel could not read, a rule inside a readable event that it could not
    /// read, and every key on a rule or hook definition it does not model are
    /// carried through as they were found.
    static func merged(_ entries: [HookEntry], into settings: [String: Any]) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let edited = Dictionary(grouping: entries.filter { !$0.command.isEmpty }, by: \.event)
        for event in Set(hooks.keys).union(edited.keys) {
            var originalRules: [[String: Any]] = []
            if let value = hooks[event] {
                guard let rules = value as? [[String: Any]] else { continue }
                originalRules = rules
            }
            let rules = rebuiltRules(for: edited[event] ?? [], original: originalRules)
            if rules.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = rules
            }
        }
        settings["hooks"] = hooks
        return settings
    }

    /// The rules for one event: one rule per run of entries that came from the
    /// same rule, plus the rules the panel could not read, each back at the
    /// index it was read from.
    private static func rebuiltRules(for entries: [HookEntry], original: [[String: Any]]) -> [[String: Any]] {
        var built = groupedByRule(entries).map { group in
            (order: group[0].origin?.ruleIndex ?? Int.max, rule: mergedRule(from: group))
        }
        for (index, rule) in original.enumerated() where rule["hooks"] as? [[String: Any]] == nil {
            built.append((order: index, rule: rule))
        }
        return built.enumerated()
            .sorted { $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order }
            .map(\.element.rule)
    }

    /// Consecutive entries that still share the rule they were read from, and
    /// still agree on its matcher, stay one rule.
    private static func groupedByRule(_ entries: [HookEntry]) -> [[HookEntry]] {
        var groups: [[HookEntry]] = []
        for entry in entries {
            let last = groups.last?.last
            if let ruleID = last?.origin?.ruleID, ruleID == entry.origin?.ruleID, last?.matcher == entry.matcher {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups
    }

    private static func mergedRule(from group: [HookEntry]) -> [String: Any] {
        var rule = group[0].origin?.rule ?? [:]
        if !group[0].matcher.isEmpty || rule["matcher"] != nil {
            rule["matcher"] = group[0].matcher
        }
        rule["hooks"] = group.map(mergedDefinition)
        return rule
    }

    private static func mergedDefinition(from entry: HookEntry) -> [String: Any] {
        var def = entry.origin?.definition ?? ["type": "command"]
        def["command"] = entry.command
        if let timeout = entry.timeout {
            def["timeout"] = timeout
        } else {
            def.removeValue(forKey: "timeout")
        }
        return def
    }
}

/// The three things `.claude/settings.json` can be when the Hooks panel reads it.
enum HookSettingsFile {
    case absent
    case unreadable(String)
    case parsed([String: Any])
}

/// Where a `HookEntry` was read from, so a save can put back what the panel
/// does not model.
struct HookOrigin {
    let ruleID: UUID
    let ruleIndex: Int
    let rule: [String: Any]
    let definition: [String: Any]
}

struct HookEntry: Identifiable {
    let id = UUID()
    var event: String
    var matcher: String
    var command: String
    /// The definition's `timeout`, or nil when it carried none: a definition
    /// that had no timeout is written back without one.
    var timeout: Int?
    var origin: HookOrigin?
}

private struct HookEntryRow: View {
    @Binding var entry: HookEntry

    private var timeout: Binding<Int> {
        Binding(get: { entry.timeout ?? 10 }, set: { entry.timeout = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $entry.event) {
                    ForEach(HookConfigView.eventChoices(for: entry.event), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)

                TextField("Matcher (tool pattern)", text: $entry.matcher)
                    .frame(width: 150)
                    .help("Tool name pattern, e.g. 'Bash' or '*' for all")
            }
            HStack {
                TextField("Command", text: $entry.command)
                Stepper("Timeout: \(entry.timeout.map { "\($0)s" } ?? "default")", value: timeout, in: 1...300)
                    .frame(width: 140)
            }
        }
        .padding(.vertical, 4)
    }
}
