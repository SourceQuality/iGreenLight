import SwiftUI
import MetalKit
import AppKit

enum StreamWindow {
    nonisolated(unsafe) static weak var current: NSWindow?
}

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

    var body: some View {
        ZStack {
            Color.black
            MetalVideoView(renderer: session.renderer)
            statusOverlay
            floatingControls
            if showStats, session.phase == .streaming { statsOverlay }
            if settings.diagnosticsEnabled, settings.diagnosticsOverlay, session.phase == .streaming, !session.diagnosticsLines.isEmpty { diagnosticsOverlay }
        }
        .ignoresSafeArea()
        .background(WindowAccessor())
        .onChange(of: settings.scaling) { session.applySettings() }
        .onChange(of: settings.upscaler) { session.applySettings() }
        .onChange(of: settings.deband) { session.applySettings() }
        .onChange(of: settings.ambientBars) { session.applySettings() }
        .onChange(of: settings.edrExpansion) { session.applySettings() }
        // No window toolbar: in full screen the system gives it an opaque strip that covers the top of the
        // picture. The controls float over the video instead (`floatingControls`).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { n in
            if (n.object as? NSWindow) === StreamWindow.current { isFullScreen = true; StreamWindow.current?.toolbar?.isVisible = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { n in
            if (n.object as? NSWindow) === StreamWindow.current { isFullScreen = false }
        }
        .alert(session.dialog?.title ?? "", isPresented: Binding(get: { session.dialog != nil }, set: { if !$0, let d = session.dialog { session.answerDialog(d, result: 1) } })) {
            if let d = session.dialog {
                ForEach(Array((d.buttons.isEmpty ? ["OK"] : d.buttons).enumerated()), id: \.offset) { i, b in
                    Button(b) { session.answerDialog(d, result: i) }
                }
            }
        } message: { Text(session.dialog?.text ?? "") }
    }

    /// Stream controls, shown by `floatingControls`.
    @ViewBuilder var controls: some View {
        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { StreamWindow.current?.toggleFullScreen(nil) }
            .help("Toggle full screen (⌃⌘F)")
        Button("Guide", systemImage: "xbox.logo") { session.sendGuideButton() }.help("Press the Xbox button")
        Button("Stats", systemImage: "chart.bar") { showStats.toggle() }.help("Toggle stats overlay")
        Menu {
            Picker("Scaling", selection: $settings.scaling) {
                ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Upscaler", selection: $settings.upscaler) {
                ForEach(Upscaler.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Debanding", isOn: $settings.deband)
            Toggle("Ambient bars", isOn: $settings.ambientBars)
            Picker("HDR highlight expansion", selection: $settings.edrExpansion) {
                ForEach(EDRExpansion.allCases) { Text($0.label).tag($0) }
            }
            Button("Request keyframe") { session.requestKeyframe() }
        } label: { Image(systemName: "slider.horizontal.3") }
        Button("Disconnect", systemImage: "xmark.circle") { session.stop(); dismiss() }
    }

    var floatingControls: some View {
        HStack(spacing: 14) { controls }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(10)
            // Windowed, the traffic lights sit in this corner (hidden title bar); start to their right.
            .padding(.leading, isFullScreen ? 0 : 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder var statusOverlay: some View {
        switch session.phase {
        case .streaming: EmptyView()
        case .starting: StatusCard(title: session.target.name, detail: "Starting…", spinner: true)
        case .provisioning(let s), .connecting(let s), .queued(let s):
            StatusCard(title: session.target.name, detail: s, spinner: true)
        case .ended(let s):
            StatusCard(title: "Stream ended", detail: s, spinner: false) { Button("Close") { dismiss() } }
        case .failed(let s):
            StatusCard(title: "Couldn't stream", detail: s, spinner: false) { Button("Close") { dismiss() } }
        }
    }

    var diagnosticsOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DIAGNOSTICS").bold()
            ForEach(Array(session.diagnosticsLines.enumerated()), id: \.offset) { Text($0.element) }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.yellow)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .padding(.top, 44)
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
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .padding(.top, 44)   // clear the toolbar, which stays visible in full screen
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
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
            Text(title).font(.title2.bold())
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            actions()
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

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
