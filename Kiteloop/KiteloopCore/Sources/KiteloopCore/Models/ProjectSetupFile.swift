import Foundation

/// A project's whole setup as one document: its team as package refs, its
/// routines, its settings, its pinned document and the names of the
/// connectors its agents need. What `GET /v1/projects/setup` exports and what
/// applying one will read back.
///
/// No secret is ever in it: Bedrock, telemetry, build environment, search
/// paths, denied tools and session ids stay on the Mac they belong to, and a
/// connector is carried by name only — never its command, URL or headers.
package struct ProjectSetupFile: Codable, Equatable, Sendable {
    /// The shape's version; a reader refuses one it does not know.
    package static let currentFormat = 1

    package var format: Int
    /// The team, as package refs. Nil when the project has none in that shape.
    package var team: PackageTeamConfig?
    /// Every one disarmed: an applied routine fires only once someone arms it.
    package var routines: [Routine]
    package var settings: Settings
    package var pinnedDocument: String?
    /// The MCP servers the team's agents name, sorted and each once.
    package var connectors: [String]

    /// The settings `GET /v1/projects/settings` reports that travel between
    /// Macs.
    package struct Settings: Codable, Equatable, Sendable {
        package var model: String?
        package var permissionMode: String
        package var effort: String?
        package var maxBudgetUSD: Double?
        package var goal: String?
        package var companions: [CompanionRepo]

        package init(model: String?, permissionMode: String, effort: String?, maxBudgetUSD: Double?,
                     goal: String?, companions: [CompanionRepo]) {
            self.model = model
            self.permissionMode = permissionMode
            self.effort = effort
            self.maxBudgetUSD = maxBudgetUSD
            self.goal = goal
            self.companions = companions
        }

        package init(_ config: ProjectConfig) {
            self.init(model: config.model, permissionMode: config.permissionMode, effort: config.effort,
                      maxBudgetUSD: config.maxBudgetUSD, goal: config.goal, companions: config.companions ?? [])
        }

        /// Every key written, null for an empty one, so the file shows each.
        package func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(permissionMode, forKey: .permissionMode)
            try c.encode(effort, forKey: .effort)
            try c.encode(maxBudgetUSD, forKey: .maxBudgetUSD)
            try c.encode(goal, forKey: .goal)
            try c.encode(companions, forKey: .companions)
        }
    }

    package init(format: Int = ProjectSetupFile.currentFormat, team: PackageTeamConfig?, routines: [Routine],
                 settings: Settings, pinnedDocument: String?, connectors: [String]) {
        self.format = format
        self.team = team
        self.routines = routines
        self.settings = settings
        self.pinnedDocument = pinnedDocument
        self.connectors = connectors
    }

    /// The file for a project's config, team and routines.
    package static func make(config: ProjectConfig, team: PackageTeamConfig?, routines: [Routine]) -> ProjectSetupFile {
        let disarmed = routines.map { routine -> Routine in
            var copy = routine
            copy.armed = false
            copy.armedAt = nil
            return copy
        }
        let names = (team?.agents ?? []).flatMap { $0.overrides?.mcpServers ?? [] }
        return ProjectSetupFile(team: team, routines: disarmed, settings: Settings(config),
                                pinnedDocument: config.pinnedDocument, connectors: Array(Set(names)).sorted())
    }

    /// Every key written, null for an empty one, so the file shows each.
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(team, forKey: .team)
        try c.encode(routines, forKey: .routines)
        try c.encode(settings, forKey: .settings)
        try c.encode(pinnedDocument, forKey: .pinnedDocument)
        try c.encode(connectors, forKey: .connectors)
    }

    /// The file as it is written: sorted keys, ISO 8601 dates.
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// A file as `encoded()` writes it.
    package static func decoded(from data: Data) throws -> ProjectSetupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectSetupFile.self, from: data)
    }
}
