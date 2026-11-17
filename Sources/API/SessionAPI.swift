import Foundation

/// gssv session endpoints: /v5/sessions/{home|cloud}/... (Greenlight player/src/server/index.ts + desktop xcloudapi.ts).
struct SessionAPI {
    enum Kind: String { case home, cloud }

    let baseURL: String
    let gsToken: String
    let kind: Kind
    let deviceInfo: String
    var sessionPath: String = ""   // "v5/sessions/home/<id>"

    var sessionId: String { sessionPath.split(separator: "/").last.map(String.init) ?? "" }

    private var headers: [String: String] {
        ["Accept": "application/json", "Content-Type": "application/json",
         "X-Gssv-Client": "XboxComBrowser", "X-MS-Device-Info": deviceInfo,
         "Authorization": "Bearer " + gsToken]
    }

    private func url(_ suffix: String) -> String { baseURL + "/" + sessionPath + suffix }

    mutating func play(target: String, locale: String, osName: String) async throws -> String {
        let tz = TimeZone.current.secondsFromGMT() / 60
        let body: [String: Any] = [
            "clientSessionId": "",
            "titleId": kind == .cloud ? target : "",
            "systemUpdateGroup": "",
            "settings": ["nanoVersion": "V3;WebrtcTransport.dll", "enableOptionalDataCollection": false,
                         "enableTextToSpeech": false, "highContrast": 0, "locale": locale,
                         "useIceConnection": false, "timezoneOffsetMinutes": tz, "sdkType": "web", "osName": osName],
            "serverId": kind == .home ? target : "",
            "fallbackRegionNames": [],
        ]
        let r = try await HTTP.request("POST", baseURL + "/v5/sessions/\(kind.rawValue)/play", headers: headers, body: HTTP.jsonBody(body))
        log("Session", "play -> \(r.text)")
        guard let obj = r.object as? [String: Any], let path = obj["sessionPath"] as? String else {
            throw HTTPError(status: r.status, url: "play", body: r.text)
        }
        sessionPath = path
        return path
    }

    func state() async throws -> [String: Any] {
        let r = try await HTTP.request("GET", url("/state"), headers: headers)
        return r.object as? [String: Any] ?? [:]
    }

    func connect(userToken: String) async throws {
        try await HTTP.request("POST", url("/connect"), headers: headers, body: HTTP.jsonBody(["userToken": userToken]))
    }

    func configuration() async throws -> [String: Any] {
        let r = try await HTTP.request("GET", url("/configuration"), headers: headers)
        return r.object as? [String: Any] ?? [:]
    }

    func waitTime(titleId: String) async throws -> [String: Any] {
        let r = try await HTTP.request("GET", baseURL + "/v1/waittime/" + titleId, headers: headers)
        return r.object as? [String: Any] ?? [:]
    }

    /// Posts the SDP offer, then polls GET /sdp until the answer is ready.
    func exchangeSDP(offer: String, chatOnly: Bool = false) async throws -> String {
        let config: [String: Any] = chatOnly ? ["isMediaStreamsChatRenegotiation": true] : [
            "chatConfiguration": ["bytesPerSample": 2, "expectedClipDurationMs": 20,
                                  "format": ["codec": "opus", "container": "webm"],
                                  "numChannels": 1, "sampleFrequencyHz": 24000],
            "chat": ["minVersion": 1, "maxVersion": 1],
            "control": ["minVersion": 1, "maxVersion": 3],
            // Greenlight desktop (the shipping app) negotiates input v1-8 on a single `input` channel.
            // Offering v9 also needs the `reliableinput`/`unreliableinput` channels, which we don't open.
            "input": ["minVersion": 1, "maxVersion": 8],
            "message": ["minVersion": 1, "maxVersion": 1],
        ]
        try await HTTP.request("POST", url("/sdp"), headers: headers,
                               body: HTTP.jsonBody(["messageType": "offer", "sdp": offer, "requestId": "1", "configuration": config]))
        let obj = try await pollExchange("/sdp")
        guard let exchange = obj["exchangeResponse"] as? String,
              let answer = (try? JSONSerialization.jsonObject(with: Data(exchange.utf8))) as? [String: Any],
              let sdp = answer["sdp"] as? String else {
            throw HTTPError(status: 0, url: "sdp", body: "No SDP answer: \(obj)")
        }
        if let status = answer["status"] as? String, status != "success" { log("Session", "SDP answer status: \(status)") }
        return sdp
    }

    /// Posts local ICE candidates, polls for the console's candidates.
    func exchangeICE(_ candidates: [[String: Any]]) async throws -> [[String: Any]] {
        try await HTTP.request("POST", url("/ice"), headers: headers,
                               body: HTTP.jsonBody(["messageType": "iceCandidate", "candidate": candidates]))
        let obj = try await pollExchange("/ice")
        guard let exchange = obj["exchangeResponse"] as? String,
              let list = (try? JSONSerialization.jsonObject(with: Data(exchange.utf8))) as? [[String: Any]] else {
            throw HTTPError(status: 0, url: "ice", body: "No ICE answer: \(obj)")
        }
        return list
    }

    private func pollExchange(_ suffix: String) async throws -> [String: Any] {
        for _ in 0..<60 {
            let r = try await HTTP.request("GET", url(suffix), headers: headers)
            if r.status == 200, let obj = r.object as? [String: Any] {
                if let err = obj["errorDetails"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
                    log("Session", "\(suffix) errorDetails: \(err)")
                }
                return obj
            }
            try await Task.sleep(nanoseconds: 750_000_000)
        }
        throw HTTPError(status: 204, url: suffix, body: "Timed out waiting for exchange")
    }

    func keepalive() async throws {
        try await HTTP.request("POST", url("/keepalive"), headers: headers, body: HTTP.jsonBody([String: String]()))
    }

    func stop() async {
        guard !sessionPath.isEmpty else { return }
        _ = try? await HTTP.request("DELETE", url(""), headers: headers)
    }
}
