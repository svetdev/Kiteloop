import Foundation

/// The one transport: async calls against the Mac's control API, bearer-token
/// authed, decoding into the tolerant models. SSE lives here too, as an
/// AsyncStream of lines, so a view model never touches URLSession.
struct ControlClient {
    var baseURL: String
    var token: String

    enum ClientError: LocalizedError {
        case badURL(String)
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .badURL(let path): "Could not build a request for \(path)."
            case .http(let code, let body): "HTTP \(code): \(body)"
            }
        }
    }

    /// Builds `path?key=value&...` with every value percent-encoded against an
    /// unreserved-only set, so a space, `&`, `=`, `+`, `#` or `?` in a project
    /// or item name can't split the query or get lost to `URL(string:)`.
    func query(_ path: String, _ params: [(String, String)]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let pairs = params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return path + "?" + pairs.joined(separator: "&")
    }

    /// The server's SSE keepalive comment goes out every 15s
    /// (`KiteloopControlServer.runEvents`); a stream deadline of just that
    /// cadence races the very traffic meant to reset it, so `events` gets a
    /// deadline several times as long instead.
    private static let streamTimeout: TimeInterval = 90

    /// `POST /v1/backlog/approve` (and `/v1/runs/{runId}/approve`, which
    /// resolves the same gate) can run the merge verify inline and only kills
    /// the command at its 900-second ceiling (`docs/control-api.md`), so the
    /// deadline for an approval has to clear that ceiling with room to spare.
    static let approvalTimeout: TimeInterval = 960

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw ClientError.badURL(path) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func run(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(method, path, body: body, timeout: timeout))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ClientError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// A GET's bytes as they came — the web preview's PNG.
    func data(_ path: String) async throws -> Data {
        try await run("GET", path)
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: await run("GET", path))
    }

    /// The projects open on the Mac right now, with the held selection
    /// reconciled against them: kept if still listed, otherwise the first —
    /// so a project opened since the last refresh appears, and one since
    /// closed is dropped along with any selection of it.
    func projectsAndSelection(holding project: String) async throws -> (names: [String], selected: String) {
        let names = ((try await get("/v1/projects", as: ProjectsReply.self).projects) ?? []).map(\.name)
        let selected = names.contains(project) ? project : (names.first ?? project)
        return (names, selected)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let data = try await run("POST", path, body: body, timeout: timeout)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// `POST /v1/pair`: the pairing QR's one-time code, traded for this
    /// phone's own token. Needs no token of its own to call.
    func claimPairing(code: String, name: String) async throws -> String {
        let reply = try await post("/v1/pair", ["code": code, "name": name])
        guard let token = reply["token"] as? String, !token.isEmpty else {
            throw ClientError.http(200, "The Mac answered without a token.")
        }
        return token
    }

    @discardableResult
    func put(_ path: String, _ body: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let data = try await run("PUT", path, body: body, timeout: timeout)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// The `data:` lines of an SSE stream, already unwrapped. Ends when the
    /// server closes; cancellation closes it from this side. A non-2xx status
    /// (an unknown run, one that has ended, a token that no longer authorises)
    /// carries no `data:` lines, so the status and body are read off the same
    /// byte sequence and raised as the same error the unary calls raise.
    func events(_ path: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request("GET", path, timeout: Self.streamTimeout))
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw ClientError.http(code, String(data: body, encoding: .utf8) ?? "")
                    }
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:") {
                            continuation.yield(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ControlClient.ClientError: HTTPStatusCarrying {
    var httpStatus: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }
}

extension ControlClient {
    /// `GET /v1/quick-replies`. Last in the file: lizard reads `get(` as a
    /// `get` accessor and would count whatever follows into it.
    func quickReplies() async throws -> [String] {
        try await get("/v1/quick-replies", as: QuickRepliesReply.self).replies ?? []
    }
}
