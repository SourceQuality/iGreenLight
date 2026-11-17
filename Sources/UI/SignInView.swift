import SwiftUI

struct SignInView: View {
    @EnvironmentObject var auth: AuthManager
    #if os(iOS)
    @State private var verificationPage: IdentifiedURL?
    private let subtitle = "Native Xbox Remote Play and Cloud Gaming for iPhone"
    #else
    private let subtitle = "Native Xbox Remote Play and Cloud Gaming for macOS"
    #endif

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "xbox.logo").font(.system(size: 64)).foregroundStyle(.white)
            Text("iGreenLight").font(.largeTitle.bold()).foregroundStyle(.white)
            Text(subtitle).foregroundStyle(Xbox.secondaryText).multilineTextAlignment(.center)

            switch auth.state {
            case .checking, .signingIn:
                ProgressView("Signing in…")
            case .awaitingCode(let code, let url):
                VStack(spacing: 12) {
                    Text("The sign-in page opens with this code already filled in.\nIf it doesn't, go to \(url) and enter it:")
                        .font(.headline).multilineTextAlignment(.center).foregroundStyle(.white)
                    Text(code).font(.system(size: 40, weight: .bold, design: .monospaced)).textSelection(.enabled).foregroundStyle(Xbox.brightGreen)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    HStack {
                        XboxButton(id: "signin-open", title: "Open Sign-in Page Again") { openVerification(code: code, url: url) }
                        XboxButton(id: "signin-cancel", title: "Cancel", prominent: false) { auth.cancelSignIn() }
                    }
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to finish signing in…").font(.caption).foregroundStyle(Xbox.secondaryText)
                }
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 460)
                if auth.canRetry { XboxButton(id: "signin-tryagain", title: "Try again") { auth.retry() } }
                XboxButton(id: "signin-retry", title: "Sign in with Microsoft") { auth.startSignIn() }
            default:
                XboxButton(id: "signin-start", title: "Sign in with Microsoft") { auth.startSignIn() }
                Text("Uses the Microsoft device-code sign-in (same as Greenlight). Tokens are stored in your Keychain.")
                    .font(.caption).foregroundStyle(Xbox.secondaryText).multilineTextAlignment(.center)
            }
        }
        #if os(iOS)
        .padding(24)
        .sheet(item: $verificationPage) { SafariView(url: $0.url).ignoresSafeArea() }
        #else
        .padding(40)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Open the page as soon as the code is issued; no copy and paste.
        .onChange(of: auth.state) { _, new in
            if case .awaitingCode(let code, let url) = new { openVerification(code: code, url: url) }
        }
    }

    /// Opens Microsoft's device-login page with the code prefilled (`?otc=`, the link Microsoft puts in its own QR codes).
    /// The code is also copied, in case the page ignores the parameter.
    private func openVerification(code: String, url: String) {
        Platform.copy(code)
        var c = URLComponents(string: url)
        let items = (c?.queryItems ?? []) + [URLQueryItem(name: "otc", value: code)]
        c?.queryItems = items
        let page = c?.url?.absoluteString ?? url
        #if os(iOS)
        // In-app Safari: leaving the app would suspend it and stall the sign-in polling.
        if let u = URL(string: page) { verificationPage = IdentifiedURL(url: u) }
        #else
        auth.openVerificationPage(page)
        #endif
    }
}
