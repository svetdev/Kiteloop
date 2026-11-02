import Foundation

package enum WorkflowGraphError: Error, LocalizedError {
    case invalidGraph(id: String, messages: [String])

    package var errorDescription: String? {
        switch self {
        case .invalidGraph(let id, let messages):
            return "Graph '\(id)' is structurally invalid: \(messages.joined(separator: "; "))"
        }
    }
}

package struct WorkflowLoadResult: Sendable {
    package let loaded: [WorkflowGraph]
    package let errors: [(filename: String, error: Error)]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(loaded: [WorkflowGraph], errors: [(filename: String, error: Error)]) {
        self.loaded = loaded
        self.errors = errors
    }
}

package struct WorkflowFileLoader: Sendable {
    package let directory: URL

    package func loadAll() throws -> WorkflowLoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return WorkflowLoadResult(loaded: [], errors: [])
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        let workflowFiles = contents.filter { $0.lastPathComponent.hasSuffix(".workflow.json") }

        var loaded: [WorkflowGraph] = []
        var errors: [(String, Error)] = []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in workflowFiles {
            do {
                let data = try Data(contentsOf: file)
                let graph = try decoder.decode(WorkflowGraph.self, from: data)
                let messages = WorkflowGraphValidator.validate(graph)
                if messages.isEmpty {
                    loaded.append(graph)
                } else {
                    errors.append((file.lastPathComponent, WorkflowGraphError.invalidGraph(id: graph.id, messages: messages)))
                }
            } catch {
                errors.append((file.lastPathComponent, error))
            }
        }

        return WorkflowLoadResult(loaded: loaded, errors: errors)
    }

    package func loadSingle(at url: URL) throws -> WorkflowGraph {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        let graph = try decoder.decode(WorkflowGraph.self, from: data)
        let messages = WorkflowGraphValidator.validate(graph)
        guard messages.isEmpty else {
            throw WorkflowGraphError.invalidGraph(id: graph.id, messages: messages)
        }
        return graph
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(directory: URL) {
        self.directory = directory
    }
}
