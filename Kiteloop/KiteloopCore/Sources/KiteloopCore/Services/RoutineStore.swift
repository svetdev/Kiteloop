import Foundation

/// The routines and the ledger of their runs, as two files under
/// `~/.kiteloop`: `routines.json`, which a person or the control API writes,
/// and `routine-runs.jsonl`, which only a firing appends to. Both are readable
/// by this user alone — a prompt names what it is about.
///
/// A run is two lines when its turn started: the start, then the same run
/// again with how it ended. Read back, the later line for an id stands — so a
/// start with no finish beside it is a turn the app did not see end.
package struct RoutineStore: Sendable {
    package let directory: URL

    package init(directory: URL = KiteloopHome.url.appending(path: ".kiteloop")) {
        self.directory = directory
    }

    package static let storeName = "Routines"

    /// How much of the ledger is read back: the count and the age
    /// `RunRecordStore` keeps of run history, for its reason — a busy Mac
    /// meets the count first, an idle one the age.
    static let retentionLimit = 500
    static let retentionAge: TimeInterval = 30 * 24 * 60 * 60

    var routinesURL: URL { directory.appending(path: "routines.json") }
    var runsURL: URL { directory.appending(path: "routine-runs.jsonl") }

    private struct File: Codable {
        var routines: [Routine]
    }

    // MARK: - Routines

    /// The routines on file, in the order written. A file that will not decode
    /// is moved aside and reported, as every small store's is.
    package func routines() -> [Routine] {
        QuarantiningJSONFile.load(File.self, from: routinesURL, store: Self.storeName,
                                  decoder: Self.decoder)?.routines ?? []
    }

    package func save(_ routines: [Routine]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicFileWriter.write(Self.encoder.encode(File(routines: routines)), to: routinesURL, mode: 0o600)
    }

    // MARK: - The ledger

    package func append(_ run: RoutineRun) {
        guard var line = try? Self.lineEncoder.encode(run) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = runsURL.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? AtomicFileWriter.append(line, to: runsURL)
    }

    /// Every run on file, oldest first, each as its last line left it, within
    /// the two bounds the run history keeps: a count and an age.
    package func runs(now: Date = Date()) -> [RoutineRun] {
        let lines = AtomicFileWriter.loadLines(from: runsURL, as: RoutineRun.self)
        return Self.fold(lines, now: now)
    }

    static func fold(_ lines: [RoutineRun], now: Date) -> [RoutineRun] {
        var order: [String] = []
        var latest: [String: RoutineRun] = [:]
        for line in lines {
            if latest[line.id] == nil { order.append(line.id) }
            latest[line.id] = line
        }
        let oldest = now.addingTimeInterval(-retentionAge)
        return order.compactMap { latest[$0] }
            .filter { $0.at >= oldest }
            .suffix(retentionLimit)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Reading a routine from a request

extension Routine {
    /// The routine a request body describes, or what is wrong with it. `id`
    /// comes from the path; `existing` is the routine being replaced, whose
    /// name and `armed` stand when the body does not say.
    package static func parse(_ json: [String: Any], id: String, existing: Routine?) -> Result<Routine, Refusal> {
        let trigger = json["trigger"] as? [String: Any] ?? [:]
        let routine = Routine(
            id: id,
            name: json["name"] as? String ?? existing?.name ?? id,
            project: json["project"] as? String ?? "",
            agent: json["agent"] as? String ?? "",
            prompt: json["prompt"] as? String ?? "",
            trigger: Trigger(at: trigger["at"] as? String, every: trigger["every"] as? Int,
                             from: trigger["from"] as? String, until: trigger["until"] as? String,
                             days: trigger["days"] as? [String]),
            precheck: (json["precheck"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            armed: json["armed"] as? Bool ?? existing?.armed ?? false,
            armedAt: existing?.armedAt
        )
        let problems = routine.problems
        return problems.isEmpty ? .success(routine) : .failure(Refusal(problems: problems))
    }

    /// Everything that stops this routine from being kept, in the words the
    /// API answers with. Empty for one that can run.
    package var problems: [String] {
        var found: [String] = []
        if !Self.isValidID(id) { found.append("the id takes lowercase letters, digits and hyphens") }
        for (field, value) in [("project", project), ("agent", agent), ("prompt", prompt)]
        where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("\"\(field)\" is required")
        }
        if case .failure(let refusal) = RoutineSchedule.parse(trigger) { found += refusal.problems }
        return found
    }

    /// The parsed trigger; nil for a routine whose trigger does not parse,
    /// which `problems` would have named.
    package var schedule: RoutineSchedule? {
        try? RoutineSchedule.parse(trigger).get()
    }

    /// The occurrence this routine owes at `now`, given the runs on record.
    /// Nothing before it was armed is owed, and neither is anything while it
    /// is not armed.
    package func owed(at now: Date, lastHandled: Date?, calendar: Calendar) -> Date? {
        guard armed, let schedule else { return nil }
        let through = max(armedAt ?? now, lastHandled ?? .distantPast)
        return schedule.owed(at: now, handledThrough: through, calendar: calendar)
    }
}
