import Foundation
import KiteloopCore

struct TeamConfigManager {
    let project: KiteloopProject

    func saveTeam(_ templates: [AgentTemplate]) throws {
        try project.ensureKiteloopDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(templates)
        try AtomicFileWriter.write(data, to: project.teamConfigURL)
    }

    func hasCustomConfig() -> Bool {
        FileManager.default.fileExists(atPath: project.teamConfigURL.path(percentEncoded: false))
    }
}
