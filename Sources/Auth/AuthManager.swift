import Foundation

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
            guard persistUserToken else { return }
            if let t = userToken { Keychain.setCodable(t, for: "msa.userToken") } else { Keychain.delete("msa.userToken") }
        }
    }
    /// Off while loading from the Keychain, so launching doesn't rewrite the token it just read.
    private var persistUserToken = true
    private var signInTask: Task<Void, Never>?
    /// The refresh in flight, shared by everyone who asks while it runs.
    private var refreshTask: Task<Void, Error>?
    /// Bumped on sign-out and on a new sign-in; work started under an older value must not write its results.
    private var generation = 0
    /// True when `state` is `.failed` but the stored sign-in is still there, so "Try again" can work without a new login.
    @Published private(set) var canRetry = false

    /// Set by the `--ui-demo` debug launch argument.
    var demo = false
    var hasXCloud: Bool { xcloud != nil || demo }

    func bootstrap() {
        if let t = Keychain.getCodable(MicrosoftAuth.UserToken.self, "msa.userToken") {
            persistUserToken = false
            userToken = t
            persistUserToken = true
            state = .signingIn
            Task { await refreshAll() }
        } else {
            state = .signedOut
        }
    }

    func startSignIn() {
        signInTask?.cancel()
        generation += 1
        let gen = generation
        canRetry = false
        signInTask = Task {
            do {
                let code = try await MicrosoftAuth.startDeviceCode()
                try checkCurrent(gen)
                log("Auth", "Device code issued, verification at \(code.verification_uri)")
                state = .awaitingCode(userCode: code.user_code, url: code.verification_uri)
                let token = try await MicrosoftAuth.pollDeviceCode(code)
                try checkCurrent(gen)
                userToken = token
                state = .signingIn
                await refreshAll()
            } catch {
                // Cancelling (Cancel, a second sign-in, sign-out) surfaces as CancellationError or URLError.cancelled.
                guard gen == generation, !Task.isCancelled, !(error is CancellationError) else { return }
                log("Auth", "Sign-in failed: \(error)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() { signInTask?.cancel(); generation += 1; state = .signedOut }

    func signOut() {
        signInTask?.cancel()
        refreshTask?.cancel()
        generation += 1
        canRetry = false
        userToken = nil
        xhome = nil; xcloud = nil; webToken = nil; gamertag = nil
        state = .signedOut
    }

    /// After a failed refresh with the sign-in still stored (offline at launch, a network error): try again.
    func retry() {
        guard canRetry else { return }
        canRetry = false
        state = .signingIn
        Task { await refreshAll() }
    }

    private func checkCurrent(_ gen: Int) throws {
        if gen != generation || Task.isCancelled { throw CancellationError() }
    }

    /// Refreshes the MSA token if needed, then gets XSTS + xHome/xCloud stream tokens, and updates `state`.
    /// A failure only drops out of the signed-in screens when the sign-in itself is gone (`invalid_grant`) or
    /// there was no working session yet; a network error while signed in leaves the session as it is.
    func refreshAll() async {
        let wasSignedIn = state == .signedIn
        do {
            try await refresh()
        } catch is CancellationError {
        } catch {
            if userToken == nil { return }   // sign-in expired: refresh() already set the state
            if wasSignedIn {
                log("Auth", "Keeping the current session after a failed refresh")
            } else {
                canRetry = true
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// One refresh at a time: callers that arrive while one is running wait for it and get its result.
    private func refresh() async throws {
        if let running = refreshTask { return try await running.value }
        let gen = generation
        let task = Task { try await performRefresh(gen) }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        do {
            try await task.value
        } catch {
            guard gen == generation, !(error is CancellationError) else { throw CancellationError() }
            log("Auth", "Token refresh failed: \(error)")
            if let e = error as? MicrosoftAuth.OAuthError, e.error == "invalid_grant" {
                userToken = nil
                xhome = nil; xcloud = nil; webToken = nil
                canRetry = false
                state = .failed("Your sign-in expired. Please sign in again.")
            }
            throw error
        }
    }

    private func performRefresh(_ gen: Int) async throws {
        try await ensureFreshUserToken(gen)
        guard let ut = userToken else { state = .signedOut; return }
        let user = try await XboxAuth.userAuthenticate(msaAccessToken: ut.access_token)
        let gssv = try await XboxAuth.xstsAuthorize(userToken: user.Token, relyingParty: "http://gssv.xboxlive.com/")
        let web = try? await XboxAuth.xstsAuthorize(userToken: user.Token, relyingParty: "http://xboxlive.com")
        let home = try await XboxAuth.streamToken(gssvToken: gssv.Token, offering: "xhome")
        var cloud: XboxAuth.StreamToken?
        do {
            cloud = try await XboxAuth.streamToken(gssvToken: gssv.Token, offering: "xgpuweb")
        } catch {
            log("Auth", "xgpuweb token failed (\(error.localizedDescription)); trying xgpuwebf2p")
            cloud = try? await XboxAuth.streamToken(gssvToken: gssv.Token, offering: "xgpuwebf2p")
        }
        // Nothing is published until everything is in hand and the user hasn't signed out meanwhile.
        try checkCurrent(gen)
        webToken = web
        gamertag = web?.gamertag
        xhome = home
        xcloud = cloud
        log("Auth", "xHome token ok, market \(home.market), regions: \(home.offeringSettings.regions.map { "\($0.name)\($0.isDefault ? "*" : "")" })")
        log("Auth", cloud == nil ? "No xCloud token (region or subscription)" : "xCloud token ok")
        canRetry = false
        state = .signedIn
    }

    private func ensureFreshUserToken(_ gen: Int) async throws {
        guard let t = userToken else { return }
        if !t.isFresh {
            log("Auth", "Refreshing MSA user token")
            let fresh = try await MicrosoftAuth.refresh(t)
            try checkCurrent(gen)   // signed out while refreshing: don't put the token back in the Keychain
            userToken = fresh
        }
    }

    /// Stream tokens are valid for a few hours; refresh lazily before use. Throws the refresh error itself
    /// (not a stale token) when the refresh fails.
    func streamToken(cloud: Bool) async throws -> XboxAuth.StreamToken {
        if let c = cloud ? xcloud : xhome, c.isFresh { return c }
        // No cloud entitlement: a refresh can't produce one, and the home token is still good.
        if cloud, xcloud == nil, let h = xhome, h.isFresh { throw HTTPError(status: 401, url: "gssv", body: "No stream token") }
        try await refresh()
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
        if let u = URL(string: url) { Platform.open(u) }
    }
}
