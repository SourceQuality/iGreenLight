import Foundation

struct HTTPError: LocalizedError {
    let status: Int
    let url: String
    let body: String
    var errorDescription: String? { "HTTP \(status) from \(url): \(body.prefix(300))" }
}

/// Thin async wrapper around URLSession that mirrors Greenlight's http helpers.
enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }()

    struct Response {
        let status: Int
        let data: Data
        func json<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: data) }
        var object: Any? { try? JSONSerialization.jsonObject(with: data) }
        var text: String { String(data: data, encoding: .utf8) ?? "" }
    }

    /// A connection that went away under the request: typically a kept-alive one the network dropped (a change from
    /// Wi-Fi to mobile data, a carrier's idle timeout). It shows up as "connection lost", or as a TLS failure whose
    /// stream error says the other side closed (errSSLClosedAbort, errSSLClosedNoNotify); any other TLS failure
    /// (a certificate, a handshake) is a real one and not this.
    static func isDroppedConnection(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        if e.code == .networkConnectionLost { return true }
        guard e.code == .secureConnectionFailed else { return false }
        let stream = (e.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue
        return stream == -9806 || stream == -9816
    }

    /// `retryDropped`: send the request once more when its connection was dropped (see `isDroppedConnection`). On by
    /// default for GET only; pass true for a POST whose repetition does no harm.
    @discardableResult
    static func request(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil,
                        allowedStatus: ClosedRange<Int> = 200...299, retryDropped: Bool? = nil) async throws -> Response {
        do {
            return try await send(method, url, headers: headers, body: body, allowedStatus: allowedStatus)
        } catch where (retryDropped ?? (method == "GET")) && isDroppedConnection(error) && !Task.isCancelled {
            log("HTTP", "\(method) \(URL(string: url)?.path ?? url) lost its connection (\(error.localizedDescription)); trying once more")
            return try await send(method, url, headers: headers, body: body, allowedStatus: allowedStatus)
        }
    }

    private static func send(_ method: String, _ url: String, headers: [String: String], body: Data?,
                             allowedStatus: ClosedRange<Int>) async throws -> Response {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        // Diagnostics: capture gssv session calls (redacted inside the recorder).
        let rec = (url.contains("/sessions/") || url.contains("/v1/waittime")) ? DiagnosticsRecorder.current : nil
        let t0 = Date()
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            rec?.recordHTTP(method: method, url: url, headers: headers, body: body, status: 0, responseHeaders: [:], response: nil,
                            error: error.localizedDescription, ms: Date().timeIntervalSince(t0) * 1000)
            throw error
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        rec?.recordHTTP(method: method, url: url, headers: headers, body: body, status: status, responseHeaders: http?.allHeaderFields ?? [:],
                        response: data, error: nil, ms: Date().timeIntervalSince(t0) * 1000)
        guard allowedStatus.contains(status) else {
            throw HTTPError(status: status, url: url, body: String(data: data, encoding: .utf8) ?? "")
        }
        return Response(status: status, data: data)
    }

    static func form(_ dict: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = dict.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves '+' and some reserved chars unescaped; escape them for form bodies.
        let q = comps.percentEncodedQuery ?? ""
        return q.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)!
    }

    static func jsonBody(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
}
