import Foundation
import Testing
@testable import iGreenLight

@Suite struct SessionAPITests {
    @Test func deepMergeMergesNestedOverwritesScalarsAndRemovesNulls() {
        let base: [String: Any] = ["a": 1, "settings": ["locale": "en-US", "osName": "windows"], "gone": true]
        let over: [String: Any] = ["a": 2, "settings": ["osName": "tizen", "extra": 5], "gone": NSNull(), "new": "x"]
        let m = SessionAPI.deepMerge(base, over)
        #expect(m["a"] as? Int == 2)
        #expect(m["new"] as? String == "x")
        #expect(m["gone"] == nil)
        let s = m["settings"] as? [String: Any]
        #expect(s?["locale"] as? String == "en-US")
        #expect(s?["osName"] as? String == "tizen")
        #expect(s?["extra"] as? Int == 5)
    }

    @Test func deepMergeReplacesADictionaryWithAScalar() {
        let m = SessionAPI.deepMerge(["settings": ["a": 1]], ["settings": "off"])
        #expect(m["settings"] as? String == "off")
    }

    @Test func sessionIdIsTheLastPathComponent() {
        var api = SessionAPI(baseURL: "https://example.test", gsToken: "t", kind: .home, deviceInfo: "{}")
        #expect(api.sessionId == "")
        api.sessionPath = "v5/sessions/home/ABC-123"
        #expect(api.sessionId == "ABC-123")
    }
}

@Suite struct HTTPTests {
    /// Refresh tokens go through this; '+' must not turn into a space on the server.
    @Test func formEscapesReservedCharacters() {
        let s = String(decoding: HTTP.form(["refresh_token": "a+b c&d=e/f"]), as: UTF8.self)
        #expect(s.hasPrefix("refresh_token="))
        #expect(s.contains("a%2Bb"))
        #expect(!s.contains("+"))
        #expect(!s.contains(" "))
        #expect(s.contains("%26d%3De"))
    }

    @Test func httpErrorDescriptionIsTruncated() {
        let e = HTTPError(status: 500, url: "u", body: String(repeating: "x", count: 1000))
        #expect((e.errorDescription ?? "").count < 400)
    }
}

@Suite struct TokenFreshnessTests {
    private func userToken(obtained: Date?, expiresIn: Int) -> MicrosoftAuth.UserToken {
        MicrosoftAuth.UserToken(access_token: "a", refresh_token: "r", expires_in: expiresIn, scope: nil, token_type: nil, obtainedAt: obtained)
    }

    @Test func userTokenFreshness() {
        #expect(userToken(obtained: Date(), expiresIn: 3600).isFresh)
        #expect(!userToken(obtained: Date(), expiresIn: 30).isFresh)                               // inside the 60 s margin
        #expect(!userToken(obtained: Date().addingTimeInterval(-7200), expiresIn: 3600).isFresh)   // expired
        #expect(!userToken(obtained: nil, expiresIn: 3600).isFresh)                                // unknown age counts as expired
    }

    @Test func userTokenSurvivesTheKeychainRoundTrip() throws {
        let t = userToken(obtained: Date(timeIntervalSince1970: 1_700_000_000), expiresIn: 3600)
        let back = try JSONDecoder().decode(MicrosoftAuth.UserToken.self, from: JSONEncoder().encode(t))
        #expect(back.refresh_token == "r")
        #expect(back.obtainedAt == t.obtainedAt)
    }

    private func streamToken(regions: String, obtained: Bool, duration: Int = 14400) throws -> XboxAuth.StreamToken {
        let json = #"{"gsToken":"g","market":"PT","durationInSeconds":\#(duration),"offeringSettings":{"regions":\#(regions)}}"#
        var t = try JSONDecoder().decode(XboxAuth.StreamToken.self, from: Data(json.utf8))
        if obtained { t.obtainedAt = Date() }
        return t
    }

    @Test func streamTokenFreshnessAndDefaultRegion() throws {
        let regions = #"[{"name":"A","baseUri":"https://a.test","isDefault":false},{"name":"B","baseUri":"https://b.test","isDefault":true}]"#
        let t = try streamToken(regions: regions, obtained: true)
        #expect(t.isFresh)
        #expect(t.defaultRegion?.name == "B")
        #expect(try !streamToken(regions: regions, obtained: false).isFresh)
        #expect(try !streamToken(regions: regions, obtained: true, duration: 20).isFresh)
        let noDefault = #"[{"name":"A","baseUri":"https://a.test","isDefault":false}]"#
        #expect(try streamToken(regions: noDefault, obtained: true).defaultRegion?.name == "A")
        #expect(try streamToken(regions: "[]", obtained: true).defaultRegion == nil)
    }
}

@Suite struct HTTPRetryTests {
    @Test func onlyDroppedConnectionsAreRetried() {
        #expect(HTTP.isDroppedConnection(URLError(.networkConnectionLost)))
        #expect(HTTP.isDroppedConnection(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9816])))
        #expect(HTTP.isDroppedConnection(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9806])))
        #expect(!HTTP.isDroppedConnection(URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": -9807])))   // a certificate
        #expect(!HTTP.isDroppedConnection(URLError(.secureConnectionFailed)))
        #expect(!HTTP.isDroppedConnection(URLError(.timedOut)))
        #expect(!HTTP.isDroppedConnection(URLError(.cancelled)))
        #expect(!HTTP.isDroppedConnection(URLError(.serverCertificateUntrusted)))
        #expect(!HTTP.isDroppedConnection(HTTPError(status: 500, url: "x", body: "")))
    }
}
