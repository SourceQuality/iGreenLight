import Foundation

/// Microsoft account OAuth (device-code flow), ported from xal-node's `Msal` class used by Greenlight.
enum MicrosoftAuth {
    static let clientId = "1f907974-e22b-4810-a9de-d9647380c97e"
    static let scope = "xboxlive.signin openid profile offline_access"

    struct DeviceCode: Decodable {
        let user_code: String
        let device_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int?
        let message: String?
    }

    struct UserToken: Codable {
        var access_token: String
        var refresh_token: String
        var expires_in: Int
        var scope: String?
        var token_type: String?
        /// Set locally when the token is received.
        var obtainedAt: Date?

        var expiresAt: Date { (obtainedAt ?? .distantPast).addingTimeInterval(TimeInterval(expires_in)) }
        var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
    }

    struct OAuthError: LocalizedError, Decodable {
        let error: String
        let error_description: String?
        var errorDescription: String? { "\(error): \(error_description ?? "")" }
    }

    static func startDeviceCode() async throws -> DeviceCode {
        let r = try await HTTP.request("POST", "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
                                       headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                       body: HTTP.form(["client_id": clientId, "scope": scope]))
        return try r.json(DeviceCode.self)
    }

    /// Polls until the user finishes signing in on microsoft.com/link (or the code expires).
    static func pollDeviceCode(_ code: DeviceCode) async throws -> UserToken {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        var interval = UInt64(max(code.interval ?? 5, 1))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            let r = try await HTTP.request("POST", "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
                                           headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                           body: HTTP.form(["grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                                            "client_id": clientId,
                                                            "device_code": code.device_code]),
                                           allowedStatus: 200...499)
            if r.status == 200 {
                var t = try r.json(UserToken.self)
                t.obtainedAt = Date()
                return t
            }
            let err = (try? r.json(OAuthError.self)) ?? OAuthError(error: "http_\(r.status)", error_description: r.text)
            switch err.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            default: throw err
            }
        }
        throw OAuthError(error: "expired_token", error_description: "The sign-in code expired.")
    }

    static func refresh(_ token: UserToken) async throws -> UserToken {
        let r = try await HTTP.request("POST", "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
                                       headers: ["Content-Type": "application/x-www-form-urlencoded",
                                                 "Cache-Control": "no-store, must-revalidate, no-cache"],
                                       body: HTTP.form(["client_id": clientId, "grant_type": "refresh_token",
                                                        "refresh_token": token.refresh_token, "scope": scope]),
                                       allowedStatus: 200...499)
        guard r.status == 200 else {
            throw (try? r.json(OAuthError.self)) ?? OAuthError(error: "http_\(r.status)", error_description: r.text)
        }
        var t = try r.json(UserToken.self)
        t.obtainedAt = Date()
        return t
    }

    /// "Console transfer token" that Remote Play sends to `/connect` when the session is `ReadyToConnect`.
    static func transferToken(refreshToken: String) async throws -> String {
        let r = try await HTTP.request("POST", "https://login.live.com/oauth20_token.srf",
                                       headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                       body: HTTP.form(["client_id": clientId,
                                                        "scope": "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN",
                                                        "grant_type": "refresh_token",
                                                        "refresh_token": refreshToken]))
        guard let obj = r.object as? [String: Any], let at = obj["access_token"] as? String else {
            throw OAuthError(error: "no_transfer_token", error_description: r.text)
        }
        return at
    }
}
