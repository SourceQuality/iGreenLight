import SwiftUI

struct SignInView: View {
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("iGreenLight").font(.largeTitle.bold())
            Text("Native Xbox Remote Play and Cloud Gaming for macOS").foregroundStyle(.secondary)

            switch auth.state {
            case .checking, .signingIn:
                ProgressView("Signing in…")
            case .awaitingCode(let code, let url):
                VStack(spacing: 12) {
                    Text("Go to \(url) and enter this code:").font(.headline)
                    Text(code).font(.system(size: 40, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Copy Code & Open Browser") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            auth.openVerificationPage(url)
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Cancel") { auth.cancelSignIn() }
                    }
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to finish signing in…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("Sign in with Microsoft") { auth.startSignIn() }.keyboardShortcut(.defaultAction)
            default:
                Button("Sign in with Microsoft") { auth.startSignIn() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
                Text("Uses the Microsoft device-code sign-in (same as Greenlight). Tokens are stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
