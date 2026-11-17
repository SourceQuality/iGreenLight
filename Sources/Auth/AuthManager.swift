import Foundation
import AppKit

/// Owns the sign-in state and all tokens. Port of Greenlight desktop/main/authentication.ts.
@MainActor
final class AuthManager: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut
        case awaitingCode(userCode: String, url: String)
        case signingIn
        case signedIn
        case failed(String)
    }

    @Published var state: State = .checking
    @Published var gamertag: String?
    @Published private(set) var xhome: XboxAuth.StreamToken?
    @Published private(set) var xcloud: XboxAuth.StreamToken?
    @Published private(set) var webToken: XboxAuth.XSTSToken?

    private var userToken: MicrosoftAuth.UserToken? {
        didSet {
            if let t = userToken { Keychain.setCodable(t, for: "msa.userToken") } else { Keychain.delete("msa.userToken") }
        }
    }
    private var signInTask: Task<Void, Never>?

    var hasXCloud: Bool { xcloud != nil }

    func bootstrap() {
        if let t = Keychain.getCodable(MicrosoftAuth.UserToken.self, "msa.userToken") {
            userToken = t
            state = .signingIn
            Task { await refreshAll() }
        } else {
            state = .signedOut
        }
    }

    func startSignIn() {
        signInTask?.cancel()
        signInTask = Task {
            do {
                let code = try await MicrosoftAuth.startDeviceCode()
                log("Auth", "Device code issued, verification at \(code.verification_uri)")
                state = .awaitingCode(userCode: code.user_code, url: code.verification_uri)
                let token = try await MicrosoftAuth.pollDeviceCode(code)
                userToken = token
                state = .signingIn
                await refreshAll()
            } catch is CancellationError {
            } catch {
                log("Auth", "Sign-in failed: \(error)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() { signInTask?.cancel(); state = .signedOut }

    func signOut() {
        signInTask?.cancel()
        userToken = nil
        xhome = nil; xcloud = nil; webToken = nil; gamertag = nil
        state = .signedOut
    }

    /// Refreshes the MSA token if needed, then gets XSTS + xHome/xCloud stream tokens.
    func refreshAll() async {
        do {
            try await ensureFreshUserToken()
            guard let ut = userToken else { state = .signedOut; return }
            let user = try await XboxAuth.userAuthenticate(msaAccessToken: ut.access_token)
            let gssv = try await XboxAuth.xstsAuthorize(userToken: user.Token, relyingParty: "http://gssv.xboxlive.com/")
            let web = try? await XboxAuth.xstsAuthorize(userToken: user.Token, relyingParty: "http://xboxlive.com")
            webToken = web
            gamertag = web?.gamertag
            xhome = try await XboxAuth.streamToken(gssvToken: gssv.Token, offering: "xhome")
            log("Auth", "xHome token ok, market \(xhome?.market ?? "?"), regions: \(xhome?.offeringSettings.regions.map { "\($0.name)\($0.isDefault ? "*" : "")" } ?? [])")
            do {
                xcloud = try await XboxAuth.streamToken(gssvToken: gssv.Token, offering: "xgpuweb")
            } catch {
                log("Auth", "xgpuweb token failed (\(error.localizedDescription)); trying xgpuwebf2p")
                xcloud = try? await XboxAuth.streamToken(gssvToken: gssv.Token, offering: "xgpuwebf2p")
            }
            log("Auth", xcloud == nil ? "No xCloud token (region or subscription)" : "xCloud token ok")
            state = .signedIn
        } catch {
            log("Auth", "Token refresh failed: \(error)")
            if let e = error as? MicrosoftAuth.OAuthError, e.error == "invalid_grant" {
                userToken = nil
                state = .failed("Your sign-in expired. Please sign in again.")
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func ensureFreshUserToken() async throws {
        guard let t = userToken else { return }
        if !t.isFresh {
            log("Auth", "Refreshing MSA user token")
            userToken = try await MicrosoftAuth.refresh(t)
        }
    }

    /// Stream tokens are valid for a few hours; refresh lazily before use.
    func streamToken(cloud: Bool) async throws -> XboxAuth.StreamToken {
        let current = cloud ? xcloud : xhome
        if let c = current, c.isFresh { return c }
        await refreshAll()
        guard let t = cloud ? xcloud : xhome else { throw HTTPError(status: 401, url: "gssv", body: "No stream token") }
        return t
    }

    func transferToken() async throws -> String {
        guard let rt = userToken?.refresh_token else { throw HTTPError(status: 401, url: "msa", body: "Not signed in") }
        return try await MicrosoftAuth.transferToken(refreshToken: rt)
    }

    func baseURL(cloud: Bool, token: XboxAuth.StreamToken) -> String {
        let override = cloud ? AppSettings.shared.xcloudRegionOverride : AppSettings.shared.xhomeRegionOverride
        if !override.isEmpty, let r = token.offeringSettings.regions.first(where: { $0.name == override }) { return r.baseUri }
        return token.defaultRegion?.baseUri ?? (cloud ? "https://weu.core.gssv-play-prod.xboxlive.com" : "https://uks.core.gssv-play-prodxhome.xboxlive.com")
    }

    func openVerificationPage(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
