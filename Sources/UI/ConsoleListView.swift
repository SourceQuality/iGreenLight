import SwiftUI

struct ConsoleListView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            if library.loadingConsoles && library.consoles.isEmpty {
                ProgressView("Finding consoles…").padding(60)
            } else if let err = library.consolesError {
                ContentUnavailableView("Couldn't load consoles", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if library.consoles.isEmpty {
                ContentUnavailableView("No consoles", systemImage: "tv.slash",
                                       description: Text("Enable Remote Play on your Xbox: Settings → Devices & connections → Remote features."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(library.consoles) { c in
                        ConsoleCard(console: c) {
                            openWindow(id: "stream", value: StreamTarget(kind: .home, id: c.id, name: c.name))
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("My Consoles")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.loadConsoles(auth) } }
                .disabled(library.loadingConsoles)
        }
        .task { if library.consoles.isEmpty { await library.loadConsoles(auth) } }
    }
}

struct ConsoleCard: View {
    let console: XboxConsole
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "xbox.logo").font(.title)
                Spacer()
                Text(console.powerState)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(console.isOn ? Color.green.opacity(0.25) : Color.gray.opacity(0.25), in: Capsule())
            }
            Text(console.name).font(.title3.bold()).lineLimit(1)
            Text(console.typeLabel).foregroundStyle(.secondary)
            Text(console.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            if console.wirelessWarning == true {
                Label("Console is on Wi-Fi; wired is better", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
            Button(action: onPlay) {
                Label("Start Remote Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
