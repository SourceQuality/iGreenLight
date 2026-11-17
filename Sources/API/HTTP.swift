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

    @discardableResult
    static func request(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil,
                        allowedStatus: ClosedRange<Int> = 200...299) async throws -> Response {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
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
