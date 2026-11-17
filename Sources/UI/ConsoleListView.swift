import SwiftUI

struct ConsoleListView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryModel
    @Environment(\.startStream) private var startStream

    var body: some View {
        PadScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "My consoles") {
                    XboxButton(id: "consoles-refresh", title: "Refresh", systemImage: "arrow.clockwise", prominent: false) {
                        Task { await library.loadConsoles(auth) }
                    }
                    .opacity(library.loadingConsoles ? 0.5 : 1)
                }
                if library.loadingConsoles && library.consoles.isEmpty {
                    ProgressView("Finding consoles…").frame(maxWidth: .infinity).padding(60)
                } else if let err = library.consolesError {
                    ContentUnavailableView("Couldn't load consoles", systemImage: "exclamationmark.triangle", description: Text(err))
                } else if library.consoles.isEmpty {
                    ContentUnavailableView("No consoles", systemImage: "tv.slash",
                                           description: Text("Enable Remote Play on your Xbox: Settings → Devices & connections → Remote features."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 18, alignment: .top)], spacing: 18) {
                        ForEach(library.consoles) { c in
                            ConsoleCard(console: c) { startStream(StreamTarget(kind: .home, id: c.id, name: c.name)) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { if library.consoles.isEmpty { await library.loadConsoles(auth) } }
    }
}

struct ConsoleCard: View {
    let console: XboxConsole
    let onPlay: () -> Void

    var body: some View {
        PadButton(id: "console-\(console.id)", priority: 1, action: onPlay) { focused in
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: [Xbox.green, Xbox.green.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "tv").font(.system(size: 56)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(console.powerLabel)
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(console.isOn ? Color.black.opacity(0.35) : Color.black.opacity(0.6), in: Capsule())
                        .padding(10)
                }
                .frame(height: 130)
                VStack(alignment: .leading, spacing: 4) {
                    Text(console.name).font(.title3.bold()).foregroundStyle(.white).lineLimit(1)
                    Text(console.typeLabel).font(.callout).foregroundStyle(Xbox.secondaryText)
                    if console.wirelessWarning == true {
                        Label("Console is on Wi-Fi; wired is better", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Start Remote Play").fontWeight(.semibold)
                    }
                    .font(.callout).foregroundStyle(focused ? Xbox.brightGreen : .white)
                    .padding(.top, 6)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(focused ? Xbox.surfaceRaised : Xbox.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: Xbox.corner))
        }
    }
}
