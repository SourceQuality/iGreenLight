import SwiftUI
import AppKit

@main
struct iGreenLightApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var library = LibraryModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("iGreenLight", id: "main") {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(AppSettings.shared)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear {
                    if auth.state == .checking { auth.bootstrap() }
                    _ = GamepadInput.shared
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Log.shared.logFileURL]) }
            }
        }

        WindowGroup("Stream", id: "stream", for: StreamTarget.self) { $target in
            if let target {
                StreamContainer(target: target)
                    .environmentObject(auth)
                    .environmentObject(AppSettings.shared)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        Settings {
            SettingsView()
                .environmentObject(AppSettings.shared)
                .environmentObject(auth)
                .frame(width: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("App", "iGreenLight launched, log at \(Log.shared.logFileURL.path)")
    }
}

/// Consoles + xCloud library state.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var consoles: [XboxConsole] = []
    @Published var consolesError: String?
    @Published var loadingConsoles = false
    @Published var cloudTitles: [CloudTitle] = []
    @Published var recentTitles: [CloudTitle] = []
    @Published var cloudError: String?
    @Published var loadingCloud = false

    func loadConsoles(_ auth: AuthManager) async {
        loadingConsoles = true; defer { loadingConsoles = false }
        consolesError = nil
        do {
            let t = try await auth.streamToken(cloud: false)
            var list = try await ConsoleAPI.homeServers(baseURL: auth.baseURL(cloud: false, token: t), gsToken: t.gsToken)
            if list.isEmpty, let web = auth.webToken {
                log("Consoles", "no servers from /v6/servers/home, trying smartglass")
                list = (try? await ConsoleAPI.smartglass(web: web)) ?? []
            }
            consoles = list
            log("Consoles", "found \(list.count) console(s): \(list.map { "\($0.name) [\($0.powerState)]" })")
        } catch {
            log("Consoles", "load failed: \(error)")
            consolesError = error.localizedDescription
        }
    }

    func loadCloud(_ auth: AuthManager) async {
        guard auth.hasXCloud else { return }
        loadingCloud = true; defer { loadingCloud = false }
        cloudError = nil
        do {
            let t = try await auth.streamToken(cloud: true)
            let base = auth.baseURL(cloud: true, token: t)
            let all = try await GamePassAPI.titles(baseURL: base, gsToken: t.gsToken)
            let lang = AppSettings.shared.locale
            cloudTitles = await GamePassAPI.hydrate(all, market: t.market, language: lang)
            let recent = (try? await GamePassAPI.titles(baseURL: base, gsToken: t.gsToken, recent: true)) ?? []
            let byId = Dictionary(cloudTitles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            recentTitles = recent.compactMap { byId[$0.id] }
            log("GamePass", "\(cloudTitles.count) cloud titles, \(recentTitles.count) recent")
        } catch {
            log("GamePass", "load failed: \(error)")
            cloudError = error.localizedDescription
        }
    }
}
