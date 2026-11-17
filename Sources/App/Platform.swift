import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
import SafariServices
#endif

/// The few things that differ between the Mac and iPhone builds and aren't view code.
enum Platform {
    /// Where the log and diagnostics go.
    /// macOS: `Application Support/iGreenLight`. iOS: the app's Documents folder, so the Files app shows it.
    static let dataDirectory: URL = {
        #if os(macOS)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iGreenLight", isDirectory: true)
        #else
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// macOS: selects the file in Finder. iOS: opens the Files app at the file's folder.
    static func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
        let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let files = URL(string: "shareddocuments://" + dir.path) { UIApplication.shared.open(files) }
        #endif
    }
}

/// Starts a stream: a new window on the Mac, a full-screen cover on the iPhone. Set by `RootView`.
struct StartStreamAction {
    var run: (StreamTarget) -> Void = { _ in }
    func callAsFunction(_ target: StreamTarget) { run(target) }
}

private struct StartStreamKey: EnvironmentKey {
    static let defaultValue = StartStreamAction()
}

extension EnvironmentValues {
    var startStream: StartStreamAction {
        get { self[StartStreamKey.self] }
        set { self[StartStreamKey.self] = newValue }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Orientations the app allows right now; the stream narrows it to landscape.
    static var orientations: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        log("App", "iGreenLight launched, log at \(Log.shared.logFileURL.path)")
        if SelfTest.requested {
            Task { @MainActor in
                await SelfTest.run()
                exit(0)
            }
        }
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

@MainActor
enum StreamScreen {
    /// While a stream is up: landscape only, and the screen doesn't dim or lock.
    static func enter() { apply(.landscape, awake: true) }
    static func leave() { apply(.allButUpsideDown, awake: false) }

    private static func apply(_ mask: UIInterfaceOrientationMask, awake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = awake
        AppDelegate.orientations = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                log("App", "orientation update refused: \(error.localizedDescription)")
            }
            for window in scene.windows {
                var vc = window.rootViewController
                while let c = vc { c.setNeedsUpdateOfSupportedInterfaceOrientations(); vc = c.presentedViewController }
            }
        }
    }
}

/// In-app Safari for the Microsoft device-code page, so the app stays in front and keeps polling.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
#endif
