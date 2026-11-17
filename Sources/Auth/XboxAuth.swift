import Foundation

/// Xbox Live token exchange (user token → XSTS → gssv stream tokens), ported from xal-node.
enum XboxAuth {
    struct XSTSToken: Codable {
        let IssueInstant: String?
        let NotAfter: String
        let Token: String
        let DisplayClaims: Claims
        struct Claims: Codable { let xui: [XUI] }
        struct XUI: Codable {
            let uhs: String
            let gtg: String?   // gamertag (only in http://xboxlive.com XSTS)
            let xid: String?
        }
        var uhs: String { DisplayClaims.xui.first?.uhs ?? "" }
        var gamertag: String? { DisplayClaims.xui.first?.gtg }
        var expiresAt: Date { ISO8601DateFormatter.lenientDate(NotAfter) }
        var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
    }

    struct Region: Codable, Hashable {
        let name: String
        let baseUri: String
        let isDefault: Bool
        let fallbackPriority: Int?
        let networkTestHostname: String?
    }

    struct StreamToken: Codable {
        let gsToken: String
        let market: String
        let durationInSeconds: Int
        let offeringSettings: OfferingSettings
        var obtainedAt: Date?
        struct OfferingSettings: Codable {
            let regions: [Region]
            let allowRegionSelection: Bool?
        }
        var defaultRegion: Region? { offeringSettings.regions.first(where: { $0.isDefault }) ?? offeringSettings.regions.first }
        var isFresh: Bool { (obtainedAt ?? .distantPast).addingTimeInterval(TimeInterval(durationInSeconds)).timeIntervalSinceNow > 60 }
    }

    private static let browserHeaders = [
        "x-xbl-contract-version": "1",
        "Cache-Control": "no-cache",
        "Content-Type": "application/json",
        "Origin": "https://www.xbox.com",
        "Referer": "https://www.xbox.com/",
        "Accept": "*/*",
        "ms-cv": "0",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    ]

    static func userAuthenticate(msaAccessToken: String) async throws -> XSTSToken {
        let body = HTTP.jsonBody(["Properties": ["AuthMethod": "RPS", "RpsTicket": "d=" + msaAccessToken,
                                                 "SiteName": "user.auth.xboxlive.com"],
                                  "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT"])
        let r = try await HTTP.request("POST", "https://user.auth.xboxlive.com/user/authenticate", headers: browserHeaders, body: body)
        return try r.json(XSTSToken.self)
    }

    static func xstsAuthorize(userToken: String, relyingParty: String) async throws -> XSTSToken {
        let body = HTTP.jsonBody(["Properties": ["SandboxId": "RETAIL", "UserTokens": [userToken]],
                                  "RelyingParty": relyingParty, "TokenType": "JWT"])
        let r = try await HTTP.request("POST", "https://xsts.auth.xboxlive.com/xsts/authorize", headers: browserHeaders, body: body)
        return try r.json(XSTSToken.self)
    }

    /// offering: "xhome", "xgpuweb", "xgpuwebf2p"
    static func streamToken(gssvToken: String, offering: String) async throws -> StreamToken {
        let body = HTTP.jsonBody(["token": gssvToken, "offeringId": offering])
        let r = try await HTTP.request("POST", "https://\(offering).gssv-play-prod.xboxlive.com/v2/login/user",
                                       headers: ["Content-Type": "application/json",
                                                 "Cache-Control": "no-store, must-revalidate, no-cache",
                                                 "x-gssv-client": "XboxComBrowser"],
                                       body: body)
        var t = try r.json(StreamToken.self)
        t.obtainedAt = Date()
        return t
    }
}

extension ISO8601DateFormatter {
    /// Xbox returns 7 fractional digits ("2026-11-18T07:36:20.1234567Z"); drop the fraction before parsing.
    static func lenientDate(_ s: String) -> Date {
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: stripped) ?? .distantPast
    }
}
