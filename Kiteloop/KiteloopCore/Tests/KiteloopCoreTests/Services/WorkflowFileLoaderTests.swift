import XCTest
@testable import KiteloopCore

final class WorkflowFileLoaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "workflow-loader")
    }

    func testLoadValidWorkflowFile() throws {
        let json = """
        {
            "id": "test-wf",
            "name": "Test Workflow",
            "version": 1,
            "entryNode": "start",
            "terminalNodes": ["end"],
            "metadata": {"description": "test"},
            "nodes": {
                "start": {"id": "start", "agentID": "agent-a", "prompt": "Begin"},
                "end": {"id": "end", "agentID": "agent-b", "prompt": "Finish"}
            },
            "edges": [{"from": "start", "to": "end", "condition": {"type": "always"}}]
        }
        """
        let fileURL = tempDir.appending(path: "test.workflow.json")
        try json.data(using: .utf8)!.write(to: fileURL)

        let loader = WorkflowFileLoader(directory: tempDir)
        let results = try loader.loadAll()

        XCTAssertEqual(results.loaded.count, 1)
        XCTAssertEqual(results.loaded.first?.id, "test-wf")
        XCTAssertTrue(results.errors.isEmpty)
    }

    func testSkipInvalidWorkflowFile() throws {
        let invalidJSON = """
        { "id": "bad", "name": "Bad" }
        """
        let fileURL = tempDir.appending(path: "bad.workflow.json")
        try invalidJSON.data(using: .utf8)!.write(to: fileURL)

        let loader = WorkflowFileLoader(directory: tempDir)
        let results = try loader.loadAll()

        XCTAssertTrue(results.loaded.isEmpty)
        XCTAssertEqual(results.errors.count, 1)
    }

    func testLoadDirectoryWithOneValidAndOneStructurallyInvalidFile() throws {
        let validJSON = """
        {
            "id": "good-wf",
            "name": "Good Workflow",
            "version": 1,
            "entryNode": "start",
            "terminalNodes": ["end"],
            "metadata": {"description": "test"},
            "nodes": {
                "start": {"id": "start", "agentID": "agent-a", "prompt": "Begin"},
                "end": {"id": "end", "agentID": "agent-b", "prompt": "Finish"}
            },
            "edges": [{"from": "start", "to": "end", "condition": {"type": "always"}}]
        }
        """
        try validJSON.data(using: .utf8)!.write(to: tempDir.appending(path: "good.workflow.json"))

        let invalidJSON = """
        {
            "id": "bad-wf",
            "name": "Bad Workflow",
            "version": 1,
            "entryNode": "missing",
            "terminalNodes": ["end"],
            "metadata": {"description": "test"},
            "nodes": {
                "end": {"id": "end", "agentID": "agent-b", "prompt": "Finish"}
            },
            "edges": []
        }
        """
        try invalidJSON.data(using: .utf8)!.write(to: tempDir.appending(path: "bad-graph.workflow.json"))

        let loader = WorkflowFileLoader(directory: tempDir)
        let results = try loader.loadAll()

        XCTAssertEqual(results.loaded.count, 1)
        XCTAssertEqual(results.loaded.first?.id, "good-wf")
        XCTAssertEqual(results.errors.count, 1)
        XCTAssertEqual(results.errors.first?.filename, "bad-graph.workflow.json")
        XCTAssertTrue(results.errors.first?.error.localizedDescription.contains("entryNode") ?? false)
    }

    func testLoadSingleThrowsForStructurallyInvalidFile() throws {
        let invalidJSON = """
        {
            "id": "bad-wf",
            "name": "Bad Workflow",
            "version": 1,
            "entryNode": "start",
            "terminalNodes": ["end"],
            "metadata": {"description": "test"},
            "nodes": {
                "start": {"id": "start", "agentID": "agent-a", "prompt": "Begin"}
            },
            "edges": []
        }
        """
        let fileURL = tempDir.appending(path: "bad-graph.workflow.json")
        try invalidJSON.data(using: .utf8)!.write(to: fileURL)

        let loader = WorkflowFileLoader(directory: tempDir)
        XCTAssertThrowsError(try loader.loadSingle(at: fileURL))
    }

    func testIgnoreNonWorkflowFiles() throws {
        let fileURL = tempDir.appending(path: "readme.md")
        try "# Workflows".data(using: .utf8)!.write(to: fileURL)

        let loader = WorkflowFileLoader(directory: tempDir)
        let results = try loader.loadAll()

        XCTAssertTrue(results.loaded.isEmpty)
        XCTAssertTrue(results.errors.isEmpty)
    }

    func testLoadMultipleFiles() throws {
        for i in 1...3 {
            let json = """
            {
                "id": "wf-\(i)", "name": "WF \(i)", "version": 1,
                "entryNode": "n1", "terminalNodes": ["n1"],
                "metadata": {"description": ""},
                "nodes": {"n1": {"id": "n1", "agentID": "agent-\(i)", "prompt": "p"}},
                "edges": []
            }
            """
            let fileURL = tempDir.appending(path: "wf\(i).workflow.json")
            try json.data(using: .utf8)!.write(to: fileURL)
        }

        let loader = WorkflowFileLoader(directory: tempDir)
        let results = try loader.loadAll()

        XCTAssertEqual(results.loaded.count, 3)
    }
}
