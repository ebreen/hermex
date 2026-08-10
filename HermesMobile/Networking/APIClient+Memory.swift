import Foundation

extension APIClient {
    func memory() async throws -> MemoryResponse {
        try await send(endpoint: .memory, method: "GET")
    }

    func writeMemory(section: MemorySection, content: String) async throws -> MemoryWriteResponse {
        try await send(
            endpoint: .memoryWrite,
            method: "POST",
            body: MemoryWriteRequest(section: section, content: content)
        )
    }

    /// Byte-faithful raw Memory read (Hermex #19, v1).
    ///
    /// GET /api/memory/raw with the fixed `source` selector (and `session_id`
    /// only for `project_context`). Auth is exclusively the session cookie from
    /// the login flow carried by `URLSession`'s cookie storage: the raw request
    /// never adds a trusted identity, API key, profile cookie, or an arbitrary
    /// workspace/path. V1 is unconditional (no If-None-Match) and keeps no
    /// offline/persistent raw cache; a bodyless 304 on this explicit path is a
    /// protocol error (§19).
    func rawMemory(source: MemoryRawSource = .memory, sessionID: String? = nil) async throws -> MemoryRawResponse {
        var request = URLRequest(
            url: Endpoint.memoryRaw(source: source, sessionID: sessionID).url(relativeTo: baseURL)
        )
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // With a custom URLProtocol the URL loading system does not attach
        // stored cookies automatically (Apple CustomHTTPProtocol caveat), so
        // the session-bound login cookie is attached explicitly. The cookie
        // captured at login time is authoritative; the session's cookie
        // storage is a secondary source (Hermex #19 §19).
        if let sessionCookie {
            request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        } else if let cookieStorage = session.configuration.httpCookieStorage,
                  let cookies = cookieStorage.cookies(for: request.url ?? baseURL),
                  !cookies.isEmpty {
            let cookieHeader = cookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }

        // The generic APIClient treats 304 as an ordinary HTTP error; on the raw
        // path a 304 is only meaningful with a retained representation, which V1
        // does not keep, so it is a protocol error (§19).
        if httpResponse.statusCode == 304 {
            throw MemoryRawError.unexpectedNotModified
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }

        let raw = try MemoryRawResponse(
            data: data,
            etag: httpResponse.value(forHTTPHeaderField: "ETag") ?? ""
        )
        // The envelope must answer the exact selector that was requested.
        guard raw.source == source.wireValue else {
            throw MemoryRawError.sourceMismatch(requested: source.wireValue, received: raw.source)
        }
        return raw
    }
}

private struct MemoryWriteRequest: Encodable {
    let section: MemorySection
    let content: String
}

