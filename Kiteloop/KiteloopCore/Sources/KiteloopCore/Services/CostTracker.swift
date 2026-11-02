import Foundation

package protocol CostTracking: Sendable {
    func record(_ entry: CostEntry) async
    func costToday(agent agentID: String?) async -> Double
    func costByAgent() async -> [String: Double]
    func allEntries() async -> [CostEntry]
}

package actor CostTracker: CostTracking {
    private let costsURL: URL
    private var entries: [CostEntry] = []
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(costsURL: URL) {
        self.costsURL = costsURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        // An actor's init is nonisolated, so it can't call isolated methods.
        // Loading is a pure function of the URL — read it here and assign.
        self.entries = Self.loadEntries(from: costsURL, decoder: decoder)
    }

    package func record(_ entry: CostEntry) {
        entries.append(entry)
        persistEntry(entry)
    }

    package func costToday(agent agentID: String? = nil) -> Double {
        let today = DayKey.string(for: Date())

        return entries
            .filter { $0.date == today && (agentID == nil || $0.agentID == agentID) }
            .reduce(0) { $0 + $1.costUSD }
    }

    package func costByAgent() -> [String: Double] {
        var result: [String: Double] = [:]
        for entry in entries {
            result[entry.agentID, default: 0] += entry.costUSD
        }
        return result
    }

    package func allEntries() -> [CostEntry] {
        entries
    }

    private func persistEntry(_ entry: CostEntry) {
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }

        // Through `AtomicFileWriter.append`, which starts a new line first when the
        // ledger doesn't end in one. A plain seek-to-end writes this entry onto the
        // remnant of one a kill cut short, and the pair decodes as neither — so the
        // spend recorded after the crash vanishes, and every cap read off this file
        // is under-counted by it.
        try? AtomicFileWriter.append(Data((line + "\n").utf8), to: costsURL)
    }

    private static func loadEntries(from url: URL, decoder: JSONDecoder) -> [CostEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        // Each line on its own bytes: one invalid byte costs only its line.
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(CostEntry.self, from: Data($0))
        }
    }
}
