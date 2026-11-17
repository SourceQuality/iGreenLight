import SwiftUI

enum HomeTab: String, CaseIterable {
    case consoles = "Consoles", cloud = "Cloud Gaming", settings = "Settings"
    var icon: String { switch self { case .consoles: "tv"; case .cloud: "cloud"; case .settings: "gearshape" } }
}

extension Notification.Name {
    /// Posted by the Mac's Settings… menu item (⌘,).
    static let showSettingsTab = Notification.Name("showSettingsTab")
}

/// The dashboard: a tab strip along the top (LB / RB), the selected page, controller hints along the bottom.
struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryModel
    @ObservedObject private var nav = PadNavigator.shared
    @State private var tab: HomeTab = .consoles
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(iOS)
    @State private var streaming: StreamTarget?
    @State private var touchTest = TouchGamepadTestView.requested
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        ZStack {
            XboxBackground()
            switch auth.state {
            case .signedIn: home
            default: SignInView()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Xbox.brightGreen)
        .padKeyboard()
        // Signed out (or the sign-in expired): drop that account's consoles and games.
        .onChange(of: auth.state) { old, new in if old == .signedIn, new != .signedIn { library.clear() } }
        #if os(iOS)
        .fullScreenCover(item: $streaming) { target in
            StreamContainer(target: target)
                .environmentObject(auth)
                .environmentObject(AppSettings.shared)
        }
        .fullScreenCover(isPresented: $touchTest) { TouchGamepadTestView() }
        #endif
    }

    private var home: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch tab {
                case .consoles: ConsoleListView()
                case .cloud: CloudLibraryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PadHints(hints: [(.a, "Select"), (.lb, ""), (.rb, "Switch tab")])
        }
        #if os(iOS)
        .environment(\.startStream, StartStreamAction { streaming = $0 })
        #else
        .environment(\.startStream, StartStreamAction { target in
            // One stream at a time: a second request brings the running one to the front.
            if StreamSession.hasActive, let w = StreamWindow.current { w.makeKeyAndOrderFront(nil) }
            else { openWindow(id: "stream", value: target) }
        })
        #endif
        .onAppear { nav.onTab = { step in select(step) } }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { _ in tab = .settings; nav.resetFocus() }
    }

    private func select(_ step: Int) {
        let all = HomeTab.allCases
        let i = (all.firstIndex(of: tab)! + step + all.count) % all.count
        tab = all[i]
        nav.resetFocus()
    }

    private var topBar: some View {
        HStack(spacing: sizeClass == .compact ? 4 : 10) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 24)).foregroundStyle(.white)
                .padding(.trailing, sizeClass == .compact ? 4 : 10)
            ForEach(HomeTab.allCases, id: \.self) { t in
                PadButton(id: "tab-\(t.rawValue)", priority: -1, scale: 1.0) {
                    tab = t
                } label: { _ in
                    VStack(spacing: 5) {
                        Text(t.rawValue).font(.system(size: sizeClass == .compact ? 15 : 17, weight: tab == t ? .bold : .medium))
                            .foregroundStyle(tab == t ? .white : Xbox.secondaryText)
                            .lineLimit(1).fixedSize()
                        Capsule().fill(tab == t ? Xbox.brightGreen : .clear).frame(height: 3)
                    }
                    .padding(.horizontal, sizeClass == .compact ? 8 : 12).padding(.top, 8)
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
            if sizeClass != .compact {
                Label(auth.gamertag ?? "Signed in", systemImage: "person.crop.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(Xbox.secondaryText).lineLimit(1)
            }
        }
        .padding(.horizontal, sizeClass == .compact ? 14 : 24).padding(.top, 10).padding(.bottom, 6)
    }
}

/// Page header: big title, optional trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// Settings → Show log.
struct LogView: View {
    let onClose: () -> Void
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                XboxButton(id: "log-back", title: "Back", systemImage: "chevron.left", prominent: false, action: onClose)
                XboxButton(id: "log-reload", title: "Reload", systemImage: "arrow.clockwise", prominent: false) { lines = Log.shared.snapshot() }
                #if os(iOS)
                ShareLink(item: Log.shared.logFileURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    .padding(.leading, 6)
                #else
                XboxButton(id: "log-reveal", title: "Reveal in Finder", systemImage: "folder", prominent: false) { Platform.reveal(Log.shared.logFileURL) }
                #endif
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }
                    .padding(10)
                }
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Xbox.corner))
                .onAppear {
                    lines = Log.shared.snapshot()
                    DispatchQueue.main.async { proxy.scrollTo(lines.count - 1) }
                }
            }
        }
        .padding(20)
        .padScope("log", onBack: onClose)
    }
}
