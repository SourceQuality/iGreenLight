import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable {
    case consoles = "My Consoles", cloud = "Cloud Gaming", log = "Log"
    var icon: String { switch self { case .consoles: "tv"; case .cloud: "cloud"; case .log: "doc.text" } }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var selection: SidebarItem? = .consoles

    var body: some View {
        switch auth.state {
        case .signedIn:
            NavigationSplitView {
                List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
                    Label(item.rawValue, systemImage: item.icon)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                .safeAreaInset(edge: .bottom) { AccountFooter() }
            } detail: {
                switch selection ?? .consoles {
                case .consoles: ConsoleListView()
                case .cloud: CloudLibraryView()
                case .log: LogView()
                }
            }
        default:
            SignInView()
        }
    }
}

struct AccountFooter: View {
    @EnvironmentObject var auth: AuthManager
    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle")
            Text(auth.gamertag ?? "Signed in").lineLimit(1)
            Spacer()
            Menu {
                Button("Refresh tokens") { Task { await auth.refreshAll() } }
                Button("Sign out", role: .destructive) { auth.signOut() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10)
    }
}

struct LogView: View {
    @State private var lines: [String] = []
    var body: some View {
        ScrollViewReader { proxy in
            List(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
            }
            .onAppear {
                lines = Log.shared.snapshot()
                proxy.scrollTo(lines.count - 1)
            }
        }
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") { lines = Log.shared.snapshot() }
            Button("Reveal Log File", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([Log.shared.logFileURL]) }
        }
        .navigationTitle("Log")
    }
}
