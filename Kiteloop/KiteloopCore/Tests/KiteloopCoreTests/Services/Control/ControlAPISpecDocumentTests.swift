import XCTest
@testable import KiteloopCore

/// The shape of the generated OpenAPI document, read back as a driver would read
/// it: which parameters a route declares and whether each is required, which
/// bodies may be omitted, and where the document-wide auth requirement is
/// dropped. `KiteloopTests/…/ControlAPISpecTests` checks the document against
/// the running server; this checks the generator alone, with no app.
final class ControlAPISpecDocumentTests: XCTestCase {

    // MARK: - Path parameters

    /// A templated path declares its capture as a required path parameter, and a
    /// path with no capture declares nothing at all — not an empty list. A driver
    /// that builds URLs from this document needs both to be literally true.
    func testOnlyTemplatedPathsDeclarePathParameters() throws {
        let run = try pathItem("/v1/runs/{id}")
        let parameters = try XCTUnwrap(run["parameters"] as? [[String: Any]])
        XCTAssertEqual(parameters.count, 1)
        let id = try XCTUnwrap(parameters.first)
        XCTAssertEqual(id["name"] as? String, "id")
        XCTAssertEqual(id["in"] as? String, "path")
        XCTAssertEqual(id["required"] as? Bool, true,
                       "a path parameter cannot be optional: without it there is no path")

        let health = try pathItem("/health")
        XCTAssertNil(health["parameters"], "a path without a capture declares no parameters")
    }

    // MARK: - Query parameters

    /// An operation lists its query parameters only when it takes some — the
    /// ones that take none carry no `parameters` key rather than an empty list.
    func testOnlyOperationsWithQueryParametersDeclareThem() throws {
        let backlog = try operation("get", "/v1/backlog")
        XCTAssertEqual(try queryParameterNames(of: backlog), ["project"])

        let health = try operation("get", "/health")
        XCTAssertNil(health["parameters"])
        let projects = try operation("get", "/v1/projects")
        XCTAssertNil(projects["parameters"])
    }

    /// Where the answer is scoped to one project the caller has to say which,
    /// so `?project=` is required — these are the routes that answer 400 without it.
    func testProjectIsRequiredWhereTheAnswerIsScopedToOneProject() throws {
        for path in ["/v1/backlog", "/v1/backlog/templates", "/v1/autopilot", "/v1/memory/proposals"] {
            let project = try queryParameter("project", of: try operation("get", path))
            XCTAssertEqual(project["required"] as? Bool, true, path)
            XCTAssertEqual(project["description"] as? String,
                           "Project identifier — canonical path, raw path or folder name.", path)
        }
    }

    /// Where the answer spans every project, `?project=` only narrows it and
    /// must not be required — a driver reading `required: true` would never ask
    /// the fleet-wide question these routes exist to answer.
    func testProjectIsOptionalWhereTheAnswerSpansEveryProject() throws {
        for path in ["/v1/metrics", "/v1/estimates", "/v1/grooming", "/v1/runs"] {
            let project = try queryParameter("project", of: try operation("get", path))
            XCTAssertEqual(project["required"] as? Bool, false, path)
            XCTAssertEqual(project["description"] as? String,
                           "Narrow to one project. Without it the answer spans every project.", path)
        }
    }

    /// Every bound on how much comes back has a default, so none of them is
    /// required: `limit` on the history listings and the run log, `hours` on the
    /// report.
    func testLimitsWithDefaultsAreOptional() throws {
        let limit = try queryParameter("limit", of: try operation("get", "/v1/metrics"))
        XCTAssertEqual(limit["required"] as? Bool, false)
        XCTAssertEqual(limit["description"] as? String, "How many records to return, 1…200. Defaults to 20.")

        let logLimit = try queryParameter("limit", of: try operation("get", "/v1/runs/{id}/log"))
        XCTAssertEqual(logLimit["required"] as? Bool, false)

        let hours = try queryParameter("hours", of: try operation("get", "/v1/report"))
        XCTAssertEqual(hours["required"] as? Bool, false)
    }

    // MARK: - Request bodies

    /// A body is required unless the route says otherwise: `POST /v1/projects/open`
    /// has nothing to do without one.
    func testARequestBodyIsRequiredByDefault() throws {
        let body = try requestBody(of: try operation("post", "/v1/projects/open"))
        XCTAssertEqual(body["required"] as? Bool, true)
    }

    /// The routes whose every field is optional accept no body at all — an
    /// absent body approves, or reports the state unchanged — so the document
    /// must not demand one.
    func testRoutesThatAcceptAnAbsentBodyDoNotRequireOne() throws {
        for (method, path) in [("put", "/v1/coordinator/refill"),
                               ("put", "/v1/coordinator/scheduling"),
                               ("post", "/v1/runs/{id}/approve")] {
            let body = try requestBody(of: try operation(method, path))
            XCTAssertEqual(body["required"] as? Bool, false, "\(method.uppercased()) \(path)")
        }
    }

    /// An object schema lists its required keys when it has any and omits the
    /// key when it has none — `"required": []` is not valid OpenAPI.
    func testAnObjectSchemaListsRequiredKeysOnlyWhenItHasSome() throws {
        let open = try bodySchema(of: try operation("post", "/v1/projects/open"))
        XCTAssertEqual(open["required"] as? [String], ["path"])

        let approve = try bodySchema(of: try operation("post", "/v1/runs/{id}/approve"))
        XCTAssertNil(approve["required"], "every field of the approve body is optional")

        let error = try XCTUnwrap(schemas()["Error"] as? [String: Any])
        XCTAssertEqual(error["required"] as? [String], ["error"])
    }

    /// A finished result carries the verify verdict the app took before the
    /// reviewer, so a driver generated from the document can read whether the
    /// item's own `verify:` passed. None of the three is required: the server
    /// writes them only when a verdict was taken, and leaves them out — never
    /// null — when none was.
    func testTheRunResultSchemaDescribesTheVerifyVerdict() throws {
        let result = try XCTUnwrap(schemas()["RunResult"] as? [String: Any])
        let properties = try XCTUnwrap(result["properties"] as? [String: Any])
        let required = try XCTUnwrap(result["required"] as? [String])

        for key in ["verifyExitStatus", "verifyCommand", "verifyOutputTail",
                    "verifyTimedOut", "verifyDirectory"] {
            XCTAssertNotNil(properties[key], "a driver reading the spec can't see \(key)")
            XCTAssertFalse(required.contains(key), "\(key) is absent when no verdict was taken")
        }
        let exitStatus = try XCTUnwrap(properties["verifyExitStatus"] as? [String: Any])
        XCTAssertEqual(exitStatus["type"] as? String, "integer")
        let timedOut = try XCTUnwrap(properties["verifyTimedOut"] as? [String: Any])
        XCTAssertEqual(timedOut["type"] as? String, "boolean",
                       "a driver has to read it as the flag it is, not a string")
        let directory = try XCTUnwrap(properties["verifyDirectory"] as? [String: Any])
        XCTAssertEqual(directory["type"] as? String, "string")
    }

    /// And the document has to say what `verifyTimedOut` is *for*: a negative
    /// exit status is a command that returned none, and this is the only field
    /// separating one the deadline killed from one that could not be spawned.
    /// A driver generated from a description that omits that reads the two as
    /// the same failure.
    func testTheRunResultSchemaSaysWhatTimedOutDistinguishes() throws {
        let result = try XCTUnwrap(schemas()["RunResult"] as? [String: Any])
        let properties = try XCTUnwrap(result["properties"] as? [String: Any])

        let timedOut = try XCTUnwrap(properties["verifyTimedOut"] as? [String: Any])
        let description = try XCTUnwrap(timedOut["description"] as? String)
        XCTAssertTrue(description.contains("deadline"), "the fact it reports is the deadline")
        XCTAssertTrue(description.contains("spawn"),
                      "and what it separates that from: a command that never started")
    }

    /// And the same three are described as surviving on the record, because they
    /// do: a run read back after a restart answers with them, so a driver
    /// generated from the document must not be told they are a live-only reading.
    func testTheRunResultSchemaSaysTheVerifyVerdictOutlivesTheProcess() throws {
        let result = try XCTUnwrap(schemas()["RunResult"] as? [String: Any])
        let properties = try XCTUnwrap(result["properties"] as? [String: Any])

        let exitStatus = try XCTUnwrap(properties["verifyExitStatus"] as? [String: Any])
        let description = try XCTUnwrap(exitStatus["description"] as? String)
        XCTAssertTrue(description.contains("historical"),
                      "the historical readout reports it too — the document has to say so")
        XCTAssertTrue(description.contains("record"),
                      "and say where it survives: the run's durable record")
    }

    /// A run's ending is reported as soon as the run has ended, whether or not
    /// the process that ran it is still up — so the listing's schema must not
    /// tell a driver these are historical-only. It said so of all four, which
    /// is the belief the listing itself used to act on, and `endedAt` it did not
    /// describe at all. Still none of them is required: a run that is still
    /// working carries none.
    func testTheRunSummarySchemaDoesNotCallTheEndingFieldsHistoricalOnly() throws {
        let summary = try XCTUnwrap(schemas()["RunSummary"] as? [String: Any])
        let properties = try XCTUnwrap(summary["properties"] as? [String: Any])
        let required = try XCTUnwrap(summary["required"] as? [String])

        for key in ["endedAt", "outcome", "reason", "durationSec", "qualityScore"] {
            let property = try XCTUnwrap(properties[key] as? [String: Any])
            let description = try XCTUnwrap(property["description"] as? String)
            XCTAssertFalse(description.lowercased().contains("historical"),
                           "\(key) is on a run that has ended, not on a row that came off disk")
            XCTAssertFalse(description.contains("Absent on a live run"),
                           "\(key) is present on a live run that has ended")
            XCTAssertFalse(required.contains(key), "\(key) is absent while a run is still working")
        }
    }

    /// When a run ended is on the wire wherever an ending is, and the two per-run
    /// bodies that report an ending report it live as well as after a restart —
    /// so neither may go on describing it as something only a record read back
    /// carries. The 202 is the exception that proves it: a run still in flight
    /// has reached no ending, so that body does not describe the field at all.
    func testTheRunBodiesDescribeTheEndingTimeWithoutCallingItHistorical() throws {
        for name in ["RunStatus", "RunResult"] {
            let schema = try XCTUnwrap(schemas()[name] as? [String: Any], name)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any], name)
            let ended = try XCTUnwrap(properties["endedAt"] as? [String: Any],
                                      "\(name) doesn't describe endedAt")
            let description = try XCTUnwrap(ended["description"] as? String, name)
            XCTAssertFalse(description.lowercased().contains("historical"),
                           "\(name) still calls endedAt a historical-only field")
            XCTAssertFalse((schema["required"] as? [String] ?? []).contains("endedAt"),
                           "\(name) requires endedAt, which a run that reached no ending has none of")
        }

        let pending = try XCTUnwrap(schemas()["RunPending"] as? [String: Any])
        XCTAssertNil((pending["properties"] as? [String: Any])?["endedAt"],
                     "a run still in flight has no ending, so the 202 describes none")
    }

    /// Every per-run body a driver polls describes `executionId` — the join to
    /// the run's transcript and its metric row — and none of them requires it: a
    /// run that never got an execution leaves the key out rather than sending
    /// null. A description calling the field historical-only would tell a
    /// generated driver to look for it in the wrong place.
    func testEveryRunBodyDescribesTheExecutionIdWithoutCallingItHistorical() throws {
        for name in ["RunStatus", "RunResult", "RunPending", "RunSummary"] {
            let schema = try XCTUnwrap(schemas()[name] as? [String: Any], name)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any], name)
            let execution = try XCTUnwrap(properties["executionId"] as? [String: Any],
                                          "\(name) doesn't describe executionId")
            let description = try XCTUnwrap(execution["description"] as? String, name)
            XCTAssertFalse(description.lowercased().contains("historical"),
                           "\(name) still calls executionId a historical-only field")
            XCTAssertFalse((schema["required"] as? [String] ?? []).contains("executionId"),
                           "\(name) requires executionId, which a refused start never gets")
        }
    }

    /// "One of these keys, either spelling" is written as `anyOf` over required
    /// lists, and only where a body actually has an alias.
    func testEitherSpellingIsWrittenAsAnyOfOnlyWhereABodyHasAnAlias() throws {
        let ask = try bodySchema(of: try operation("post", "/v1/projects/ask"))
        let anyOf = try XCTUnwrap(ask["anyOf"] as? [[String: Any]])
        XCTAssertEqual(anyOf.map { $0["required"] as? [String] }, [["question"], ["q"]])
        XCTAssertEqual(ask["required"] as? [String], ["project"])

        let open = try bodySchema(of: try operation("post", "/v1/projects/open"))
        XCTAssertNil(open["anyOf"])
    }

    // MARK: - Auth

    /// The document-wide bearer requirement is dropped on exactly the route the
    /// table says needs no token, by writing an empty `security` there; every
    /// other operation inherits the requirement by carrying no override.
    func testOnlyTheUnauthenticatedRouteOverridesSecurity() throws {
        let health = try operation("get", "/health")
        let security = try XCTUnwrap(health["security"] as? [[String: [String]]],
                                     "/health must carry an explicit, empty security requirement")
        XCTAssertTrue(security.isEmpty)

        let projects = try operation("get", "/v1/projects")
        XCTAssertNil(projects["security"], "an authenticated route inherits the document-wide requirement")
        let runs = try operation("post", "/v1/runs")
        XCTAssertNil(runs["security"])
    }

    // MARK: - The family dispatch behind each operation

    /// Every routed endpoint reaches the document carrying an `operationId` of
    /// its own. `detail(for:)` hands a route to its family and each family to a
    /// function per route, so a route wired to a sibling's description shows up
    /// here as a repeated id — where a wrong summary would otherwise sit in the
    /// document unread.
    func testEveryEndpointReachesTheDocumentWithADistinctOperationId() throws {
        let ids = try operationIds()
        XCTAssertEqual(ids.count, ControlRouter.endpoints.count,
                       "every routed endpoint should describe itself exactly once")
        XCTAssertFalse(ids.contains(where: \.isEmpty), "an operationId is how a driver names a call")

        let repeated = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        XCTAssertTrue(repeated.isEmpty, "two endpoints share an operationId: \(repeated.sorted())")
    }

    // MARK: - Reading the document

    private func document() -> [String: Any] {
        ControlAPISpec.document(version: "1.2.3", port: 4517)
    }

    /// Every operation's `operationId`, across every path and method — a path
    /// item's own `parameters` list is not an operation.
    private func operationIds() throws -> [String] {
        let paths = try XCTUnwrap(document()["paths"] as? [String: Any])
        return try paths.values.flatMap { item -> [String] in
            let pathItem = try XCTUnwrap(item as? [String: Any])
            return try pathItem.filter { $0.key != "parameters" }
                .map { try XCTUnwrap(($0.value as? [String: Any])?["operationId"] as? String) }
        }
    }

    private func schemas() throws -> [String: Any] {
        let components = try XCTUnwrap(document()["components"] as? [String: Any])
        return try XCTUnwrap(components["schemas"] as? [String: Any])
    }

    private func pathItem(_ path: String) throws -> [String: Any] {
        let paths = try XCTUnwrap(document()["paths"] as? [String: Any])
        return try XCTUnwrap(paths[path] as? [String: Any], "no path item for \(path)")
    }

    private func operation(_ method: String, _ path: String) throws -> [String: Any] {
        try XCTUnwrap(try pathItem(path)[method] as? [String: Any], "no \(method.uppercased()) operation at \(path)")
    }

    private func queryParameterNames(of operation: [String: Any]) throws -> [String] {
        let parameters = try XCTUnwrap(operation["parameters"] as? [[String: Any]])
        return parameters.filter { $0["in"] as? String == "query" }.compactMap { $0["name"] as? String }
    }

    private func queryParameter(_ name: String, of operation: [String: Any]) throws -> [String: Any] {
        let parameters = try XCTUnwrap(operation["parameters"] as? [[String: Any]])
        return try XCTUnwrap(parameters.first { $0["in"] as? String == "query" && $0["name"] as? String == name },
                             "no query parameter named \(name)")
    }

    private func requestBody(of operation: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(operation["requestBody"] as? [String: Any], "operation declares no request body")
    }

    private func bodySchema(of operation: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(try requestBody(of: operation)["content"] as? [String: Any])
        let json = try XCTUnwrap(content["application/json"] as? [String: Any])
        return try XCTUnwrap(json["schema"] as? [String: Any])
    }
}
