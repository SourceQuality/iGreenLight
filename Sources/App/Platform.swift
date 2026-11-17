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
        #if DEBUG
        if SelfTest.requested {
            Task { @MainActor in
                await SelfTest.run()
                exit(0)
            }
        }
        #endif
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

    /// How long a stream survives the app being in the background (a glance at a message, the app switcher).
    static let backgroundGrace: TimeInterval = 20
    private static var graceTask: Task<Void, Never>?

    /// The app went to the background, where iOS would soon suspend it: the connection would die and the console
    /// or cloud slot would stay allocated until it timed out. Keep the stream going for `backgroundGrace` under a
    /// background task; if the app isn't back by then, end the streams and wait for the server to be told.
    static func appEnteredBackground() {
        guard StreamSession.hasActive, graceTask == nil else { return }
        let reason = "The stream ended after iGreenLight was in the background for \(Int(backgroundGrace)) seconds."
        let background = BackgroundTask()
        background.id = UIApplication.shared.beginBackgroundTask(withName: "Stream grace period") {
            // iOS wants the time back before the grace period is over: end now.
            // The deletes need a moment to go out; iOS allows a little after this handler, so the task is ended
            // when they are done or after 1.5 s, whichever is first.
            MainActor.assumeIsolated {
                graceTask?.cancel()
                graceTask = nil
                let deletes = StreamSession.stopAllForTermination(reason: reason)
                Task { @MainActor in
                    for delete in deletes { await delete.value }
                    background.end()
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    background.end()
                }
            }
        }
        graceTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(backgroundGrace * 1_000_000_000)) } catch {
                background.end()   // back in front (or expired) before the grace period ran out
                return
            }
            graceTask = nil
            for delete in StreamSession.stopAllForTermination(reason: reason) { await delete.value }
            background.end()
        }
    }

    /// Back in front within the grace period: the stream carries on.
    static func appBecameActive() {
        graceTask?.cancel()
        graceTask = nil
    }

    private final class BackgroundTask {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    // TODO: Modernization - Consider adopting `prefersInterfaceOrientationLocked` (iOS 26+)
    // as the modern replacement for orientation locking via `supportedInterfaceOrientations`. The inner display of
    // iPhone Duo doesn't honour this request; the stream and the on-screen gamepad lay out for a tall view there.
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

/// Reports the interface orientation of the scene a view is in, and again when it changes. Only for questions
/// about the hardware (which side the Dynamic Island is on); the shape of the layout comes from the view's size.
struct SceneOrientationReader: UIViewRepresentable {
    let onChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        v.onChange = onChange
        return v
    }
    func updateUIView(_ view: Probe, context: Context) { view.onChange = onChange }

    final class Probe: UIView {
        var onChange: (UIInterfaceOrientation) -> Void = { _ in }
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = window?.windowScene?.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
                let orientation = scene.effectiveGeometry.interfaceOrientation
                DispatchQueue.main.async { self?.onChange(orientation) }
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
