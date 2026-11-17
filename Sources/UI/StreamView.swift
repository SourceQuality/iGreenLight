import SwiftUI
import MetalKit
#if os(macOS)
import AppKit

enum StreamWindow {
    nonisolated(unsafe) static weak var current: NSWindow?
}
#else
import GameController
#endif

/// Owns a StreamSession for the lifetime of the stream window.
struct StreamContainer: View {
    let target: StreamTarget
    @EnvironmentObject var auth: AuthManager
    @State private var session: StreamSession?

    var body: some View {
        Group {
            if let session { StreamView(session: session) } else { Color.black }
        }
        .onAppear {
            if session == nil {
                let s = StreamSession(target: target, auth: auth)
                session = s
                s.start()
            }
        }
        .onDisappear { session?.stop() }
        .navigationTitle(target.name)
    }
}

struct StreamView: View {
    @ObservedObject var session: StreamSession
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showStats = AppSettings.shared.showStats
    @State private var isFullScreen = false
    /// The options panel (sliders button, or both sticks clicked on a controller).
    @State private var menuOpen = false
    #if os(iOS)
    /// On-screen gamepad: on while no controller is connected (if the setting allows), or toggled from the controls.
    @State private var touchControls = AppSettings.shared.touchControls && GamepadInput.shared.controllers.isEmpty
    #endif

    var body: some View {
        ZStack {
            // The picture runs edge to edge; on the iPhone the overlays stay inside the safe area
            // (clear of the Dynamic Island and the rounded corners).
            Group {
                Color.black
                MetalVideoView(renderer: session.renderer)
            }
            .ignoresSafeArea()
            #if os(iOS)
            if touchControls, session.phase == .streaming { TouchGamepadOverlay() }
            #endif
            statusOverlay
            floatingControls
            if showStats, session.phase == .streaming { statsOverlay }
            if settings.diagnosticsEnabled, settings.diagnosticsOverlay, session.phase == .streaming, !session.diagnosticsLines.isEmpty { diagnosticsOverlay }
            if menuOpen { streamMenu }
            if let d = session.dialog { dialogCard(d) }
        }
        .preferredColorScheme(.dark)
        // Before and after the stream the controller drives these screens (B cancels / closes). During it the
        // controller is the game's, except while the menu or a console dialog is up.
        .padScope("stream", onBack: { if session.phase != .streaming { session.stop(); dismiss() } })
        .padKeyboard()
        .onAppear {
            PadNavigator.shared.onMenuChord = { if session.phase == .streaming { menuOpen.toggle() } }
            syncInputOwner()
        }
        .onDisappear {
            PadNavigator.shared.onMenuChord = nil
            PadNavigator.shared.suspended = false
            GamepadInput.shared.uiOwnsInput = false
        }
        .onChange(of: session.phase) { syncInputOwner() }
        .onChange(of: menuOpen) { syncInputOwner() }
        .onChange(of: session.dialog?.id) { syncInputOwner() }
        .onChange(of: settings.quality) { session.applyQuality() }
        #if os(macOS)
        .ignoresSafeArea()
        .background(WindowAccessor())
        #else
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { StreamScreen.enter() }
        .onDisappear { StreamScreen.leave() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in touchControls = false }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            touchControls = settings.touchControls && GamepadInput.shared.controllers.isEmpty
        }
        #endif
        .onChange(of: settings.scaling) { session.applySettings() }
        .onChange(of: settings.upscaler) { session.applySettings() }
        .onChange(of: settings.deband) { session.applySettings() }
        .onChange(of: settings.ambientBars) { session.applySettings() }
        .onChange(of: settings.edrExpansion) { session.applySettings() }
        // No window toolbar: in full screen the system gives it an opaque strip that covers the top of the
        // picture. The controls float over the video instead (`floatingControls`).
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { n in
            if (n.object as? NSWindow) === StreamWindow.current { isFullScreen = true; StreamWindow.current?.toolbar?.isVisible = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { n in
            if (n.object as? NSWindow) === StreamWindow.current { isFullScreen = false }
        }
        #endif
    }

    private func syncInputOwner() {
        let ui = menuOpen || session.dialog != nil
        GamepadInput.shared.uiOwnsInput = ui
        PadNavigator.shared.suspended = session.phase == .streaming && !ui
        if session.phase != .streaming, menuOpen { menuOpen = false }
    }

    private var streamMenu: StreamMenu {
        #if os(iOS)
        StreamMenu(session: session, isOpen: $menuOpen, showStats: $showStats, touchControls: $touchControls)
        #else
        StreamMenu(session: session, isOpen: $menuOpen, showStats: $showStats)
        #endif
    }

    /// A message from the console (e.g. "someone else wants to play").
    private func dialogCard(_ d: StreamSession.Dialog) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(d.title).font(.title2.bold()).foregroundStyle(.white)
                Text(d.text).multilineTextAlignment(.center).foregroundStyle(Xbox.secondaryText).frame(maxWidth: 420)
                HStack(spacing: 12) {
                    ForEach(Array((d.buttons.isEmpty ? ["OK"] : d.buttons).enumerated()), id: \.offset) { i, b in
                        XboxButton(id: "dialog-\(i)", title: b, prominent: i == 0) { session.answerDialog(d, result: i) }
                    }
                }
            }
            .padding(28)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14))
            .padScope("stream-dialog", onBack: { session.answerDialog(d, result: d.buttons.count > 1 ? 1 : 0) })
        }
    }

    private var streamControls: StreamControls {
        #if os(iOS)
        StreamControls(session: session, showStats: $showStats, menuOpen: $menuOpen, touchControls: $touchControls)
        #else
        StreamControls(session: session, showStats: $showStats, menuOpen: $menuOpen)
        #endif
    }

    var floatingControls: some View {
        HStack(spacing: 14) { streamControls }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .foregroundStyle(.white)
            #if os(macOS)
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .streamControlsGlass()
            .environment(\.colorScheme, .dark)
            .padding(10)
            // Windowed, the traffic lights sit in this corner (hidden title bar); start to their right.
            .padding(.leading, isFullScreen ? 0 : 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #else
            // Top centre: between the bumpers of the on-screen gamepad, away from the Dynamic Island.
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .streamControlsGlass()
            .environment(\.colorScheme, .dark)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            #endif
    }

    #if os(macOS)
    private let overlayTop: CGFloat = 44, overlayFont: CGFloat = 11
    #else
    private let overlayTop: CGFloat = 40, overlayFont: CGFloat = 9
    #endif

    @ViewBuilder var statusOverlay: some View {
        switch session.phase {
        case .streaming: EmptyView()
        case .starting: StatusCard(title: session.target.name, detail: "Starting…", spinner: true) { cancelButton }
        case .provisioning(let s), .connecting(let s), .queued(let s):
            StatusCard(title: session.target.name, detail: s, spinner: true) { cancelButton }
        case .ended(let s):
            StatusCard(title: "Stream ended", detail: s, spinner: false) { XboxButton(id: "stream-close", title: "Close") { dismiss() } }
        case .failed(let s):
            StatusCard(title: "Couldn't stream", detail: s, spinner: false) { XboxButton(id: "stream-close", title: "Close") { dismiss() } }
        }
    }

    private var cancelButton: some View {
        VStack(spacing: 10) {
            XboxButton(id: "stream-cancel", title: "Cancel", prominent: false) { session.stop(); dismiss() }
            if PadNavigator.shared.padConnected {
                HStack(spacing: 6) {
                    PadGlyph(kind: .sticks)
                    Text("opens the menu during the stream").font(.footnote).foregroundStyle(Xbox.secondaryText)
                }
            }
        }
    }

    var diagnosticsOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DIAGNOSTICS").bold()
            ForEach(Array(session.diagnosticsLines.enumerated()), id: \.offset) { Text($0.element) }
        }
        .font(.system(size: overlayFont, design: .monospaced))
        .foregroundStyle(.yellow)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .padding(.top, overlayTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    var statsOverlay: some View {
        let s = session.stats
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(s.resolution) @ \(Int(s.fps)) fps  \(s.codec)")
            Text(String(format: "%.1f Mbps  RTT %@  jitter %.1f ms  lost %d", s.bitrateMbps, s.rttMs.map { String(format: "%.0f ms", $0) } ?? "-", s.jitterMs, s.packetsLost))
            if let d = s.decodeMs { Text(String(format: "decode %.1f ms", d)) }
            Text("path: \(s.path)")
            Text("server video: \(s.serverSize ?? "-")  requested: \(settings.requestedSize.width)x\(settings.requestedSize.height)")
            Text("upscale: \(s.upscale)  [\(settings.scaling.rawValue)]")
            Text("render cost: \(session.renderer.timingSummary)")
            Text("controllers: \(GamepadInput.shared.controllerNames.joined(separator: ", ").isEmpty ? "keyboard" : GamepadInput.shared.controllerNames.joined(separator: ", "))")
        }
        .font(.system(size: overlayFont, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .padding(.top, overlayTop)   // clear the controls
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Backing of the floating stream controls: Liquid Glass on iOS / macOS 26 and later, the frosted blur before that.
    @ViewBuilder func streamControlsGlass() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// The stream's floating buttons.
///
/// A view of its own that doesn't observe the session, so the once-a-second stats redraw of `StreamView` leaves it alone.
struct StreamControls: View {
    let session: StreamSession
    @Binding var showStats: Bool
    @Binding var menuOpen: Bool
    #if os(iOS)
    @Binding var touchControls: Bool
    #endif
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { StreamWindow.current?.toggleFullScreen(nil) }
            .help("Toggle full screen (⌃⌘F)")
        #else
        Button("On-screen controls", systemImage: touchControls ? "gamecontroller.fill" : "gamecontroller") { touchControls.toggle() }
        #endif
        Button("Guide", systemImage: "xbox.logo") { session.sendGuideButton() }.help("Press the Xbox button")
        Button("Stats", systemImage: "chart.bar") { showStats.toggle() }.help("Toggle stats overlay")
        Button("Options", systemImage: "slider.horizontal.3") { menuOpen.toggle() }.help("Stream options")
        Button("Disconnect", systemImage: "xmark.circle") { session.stop(); dismiss() }
    }
}

/// Options panel over the stream, in the console's style. Works by touch, mouse and controller
/// (D-pad to move, A / left / right to change, B to close). Doesn't observe the session, for the same reason as `StreamControls`.
struct StreamMenu: View {
    let session: StreamSession
    @Binding var isOpen: Bool
    @Binding var showStats: Bool
    #if os(iOS)
    @Binding var touchControls: Bool
    #endif
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { isOpen = false }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "xbox.logo").font(.title2)
                    Text(session.target.name).font(.title3.bold()).lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)
                PadScrollView {
                    VStack(spacing: 6) {
                        XboxRow(id: "menu-resume", title: "Resume", action: { isOpen = false }) { Image(systemName: "play.fill").foregroundStyle(Xbox.brightGreen) }
                        XboxRow(id: "menu-guide", title: "Press the Xbox button", action: { isOpen = false; session.sendGuideButton() }) { Image(systemName: "xbox.logo").foregroundStyle(Xbox.secondaryText) }
                        XboxChoiceRow(id: "menu-quality", title: session.target.kind == .home ? "Quality" : "Quality (next session)",
                                      options: StreamQuality.allCases, label: \.label, selection: $settings.quality)
                        XboxChoiceRow(id: "menu-scaling", title: "Scaling", options: ScalingMode.allCases, label: \.label, selection: $settings.scaling)
                        XboxChoiceRow(id: "menu-upscaler", title: "Upscaler", options: Upscaler.allCases, label: \.label, selection: $settings.upscaler)
                        XboxToggleRow(id: "menu-deband", title: "Debanding", isOn: $settings.deband)
                        XboxToggleRow(id: "menu-ambient", title: "Ambient bars", isOn: $settings.ambientBars)
                        XboxChoiceRow(id: "menu-edr", title: "HDR highlight expansion", options: EDRExpansion.allCases, label: \.label, selection: $settings.edrExpansion)
                        XboxToggleRow(id: "menu-stats", title: "Stats overlay", isOn: $showStats)
                        #if os(iOS)
                        XboxToggleRow(id: "menu-touch", title: "On-screen controls", isOn: $touchControls)
                        #endif
                        XboxRow(id: "menu-keyframe", title: "Request keyframe", action: { session.requestKeyframe() }) { Image(systemName: "arrow.clockwise").foregroundStyle(Xbox.secondaryText) }
                        XboxRow(id: "menu-disconnect", title: "Disconnect", action: { session.stop(); dismiss() }) { Image(systemName: "xmark.circle").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42)) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                PadHints(hints: [(.a, "Change"), (.b, "Close")])
            }
            .frame(maxWidth: 380)
            .background(Color(white: 0.08).opacity(0.94))
            .padScope("stream-menu", onBack: { isOpen = false })
        }
        .transition(.opacity)
    }
}

struct StatusCard<Actions: View>: View {
    let title: String
    let detail: String
    let spinner: Bool
    @ViewBuilder var actions: () -> Actions

    init(title: String, detail: String, spinner: Bool, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title; self.detail = detail; self.spinner = spinner; self.actions = actions
    }

    var body: some View {
        VStack(spacing: 14) {
            if spinner { ProgressView().controlSize(.large) }
            Text(title).font(.title2.bold()).foregroundStyle(.white)
            Text(detail).multilineTextAlignment(.center).foregroundStyle(Xbox.secondaryText).frame(maxWidth: 420)
            actions()
        }
        .padding(28)
        .background(Color(white: 0.12).opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
    }
}

#if os(iOS)
/// MTKView host for the Metal renderer.
struct MetalVideoView: UIViewRepresentable {
    let renderer: MetalVideoRenderer
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        renderer.configure(v)
        return v
    }
    func updateUIView(_ view: MTKView, context: Context) {}
}
#else
/// MTKView host for the Metal renderer.
struct MetalVideoView: NSViewRepresentable {
    let renderer: MetalVideoRenderer
    func makeNSView(context: Context) -> MTKView {
        let v = StreamMTKView()
        renderer.configure(v)
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}

final class StreamMTKView: MTKView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    override func mouseMoved(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(true) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}

/// Registers the hosting window as the stream window (for keyboard capture) and sets a 16:9 content aspect.
struct WindowAccessor: NSViewRepresentable {
    /// Configures the window once the view is actually in one (it often isn't yet on the next runloop turn).
    final class Probe: NSView {
        private var configured = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, !configured else { return }
            configured = true
            StreamWindow.current = w
            w.collectionBehavior.insert(.fullScreenPrimary)
            w.backgroundColor = .black
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            DispatchQueue.main.async {
                if AppSettings.shared.startFullscreen, !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
