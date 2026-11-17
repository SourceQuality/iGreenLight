import SwiftUI

struct CloudLibraryView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    var filtered: [CloudTitle] {
        search.isEmpty ? library.cloudTitles : library.cloudTitles.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if !auth.hasXCloud {
                ContentUnavailableView("Cloud Gaming unavailable", systemImage: "cloud.slash",
                                       description: Text("No xCloud token for this account (needs Game Pass Ultimate/Premium, or an unsupported region)."))
            } else if library.loadingCloud && library.cloudTitles.isEmpty {
                ProgressView("Loading library…")
            } else if let err = library.cloudError {
                ContentUnavailableView("Couldn't load library", systemImage: "exclamationmark.triangle", description: Text(err))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if search.isEmpty && !library.recentTitles.isEmpty {
                            Text("Jump back in").font(.title2.bold())
                            grid(library.recentTitles)
                            Text("All games").font(.title2.bold())
                        }
                        grid(filtered)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Cloud Gaming")
        .searchable(text: $search)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.loadCloud(auth) } }
        }
        .task { if library.cloudTitles.isEmpty { await library.loadCloud(auth) } }
    }

    func grid(_ titles: [CloudTitle]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            ForEach(titles) { t in
                Button {
                    openWindow(id: "stream", value: StreamTarget(kind: .cloud, id: t.id, name: t.name))
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        AsyncImage(url: t.imageURL) { img in img.resizable().aspectRatio(1, contentMode: .fill) }
                            placeholder: { Rectangle().fill(.quaternary).overlay(Image(systemName: "gamecontroller")) }
                            .frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(t.name).font(.callout).lineLimit(2).frame(width: 150, alignment: .leading)
                        if t.supportsMKB { Text("Mouse & keyboard").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
