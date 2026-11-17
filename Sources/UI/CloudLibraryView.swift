import SwiftUI

struct CloudLibraryView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryModel
    @Environment(\.startStream) private var startStream
    @State private var search = ""

    var filtered: [CloudTitle] {
        search.isEmpty ? library.cloudTitles : library.cloudTitles.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        PadScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Cloud Gaming") {
                    XboxButton(id: "cloud-refresh", title: "Refresh", systemImage: "arrow.clockwise", prominent: false) {
                        Task { await library.loadCloud(auth) }
                    }
                }
                if !auth.hasXCloud {
                    ContentUnavailableView("Cloud Gaming unavailable", systemImage: "cloud.slash",
                                           description: Text("No xCloud token for this account (needs Game Pass Ultimate/Premium, or an unsupported region)."))
                } else if library.loadingCloud && library.cloudTitles.isEmpty {
                    ProgressView("Loading library…").frame(maxWidth: .infinity).padding(60)
                } else if let err = library.cloudError {
                    ContentUnavailableView("Couldn't load library", systemImage: "exclamationmark.triangle", description: Text(err))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Xbox.secondaryText)
                        TextField("Search games", text: $search).textFieldStyle(.plain).foregroundStyle(.white)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Xbox.surface, in: RoundedRectangle(cornerRadius: Xbox.corner))
                    .frame(maxWidth: 420)

                    if search.isEmpty && !library.recentTitles.isEmpty {
                        Text("Jump back in").font(.title2.bold()).foregroundStyle(.white)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.recentTitles) { t in tile(t, prefix: "recent", size: 170).frame(width: 170) }
                            }
                            .padding(.vertical, 10).padding(.horizontal, 6)
                        }
                        .padding(.horizontal, -6)
                        Text("All games").font(.title2.bold()).foregroundStyle(.white)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 16) {
                        ForEach(filtered) { t in tile(t, prefix: "title", size: 140) }
                    }
                }
            }
            .padding(24)
        }
        .task { if library.cloudTitles.isEmpty { await library.loadCloud(auth) } }
    }

    func tile(_ t: CloudTitle, prefix: String, size: CGFloat) -> some View {
        PadButton(id: "\(prefix)-\(t.id)", priority: 1) {
            startStream(StreamTarget(kind: .cloud, id: t.id, name: t.name))
        } label: { focused in
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: t.imageURL) { img in img.resizable().aspectRatio(contentMode: .fill) }
                            placeholder: { Rectangle().fill(Xbox.surfaceRaised).overlay(Image(systemName: "gamecontroller").font(.title).foregroundStyle(Xbox.secondaryText)) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Xbox.corner))
                Text(t.name).font(.callout.weight(focused ? .bold : .regular)).foregroundStyle(.white)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                if t.supportsMKB { Text("Mouse & keyboard").font(.caption2).foregroundStyle(Xbox.secondaryText) }
            }
        }
    }
}
