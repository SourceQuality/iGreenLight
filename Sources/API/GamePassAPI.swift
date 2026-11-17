import Foundation

struct CloudTitle: Identifiable, Hashable {
    let id: String          // titleId (used to start xCloud sessions)
    let productId: String
    var name: String
    var imageURL: URL?
    var publisher: String?
    var supportsMKB: Bool = false
}

/// Port of Greenlight platform/controller/gamepass.ts + desktop titlemanager.
enum GamePassAPI {
    static func titles(baseURL: String, gsToken: String, recent: Bool = false) async throws -> [CloudTitle] {
        let path = recent ? "/v2/titles/mru?mr=25" : "/v2/titles"
        let r = try await HTTP.request("GET", baseURL + path, headers: [
            "Authorization": "Bearer " + gsToken, "Accept": "application/json", "X-Gssv-Client": "XboxComBrowser",
        ])
        guard let obj = r.object as? [String: Any], let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { d in
            guard let tid = d["titleId"] as? String, let details = d["details"] as? [String: Any],
                  let pid = details["productId"] as? String else { return nil }
            let mkb = (details["supportedInputTypes"] as? [String])?.contains("MKB") ?? false
            return CloudTitle(id: tid, productId: pid, name: details["name"] as? String ?? pid, supportsMKB: mkb)
        }
    }

    /// Hydrates names/box art from catalog.gamepass.com (batches of 200 products).
    static func hydrate(_ titles: [CloudTitle], market: String, language: String) async -> [CloudTitle] {
        var byProduct: [String: [String: Any]] = [:]
        let ids = titles.map(\.productId)
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            do {
                let r = try await HTTP.request("POST", "https://catalog.gamepass.com/v3/products?hydration=RemoteHighSapphire0&market=\(market)&language=\(language)",
                                               headers: ["Content-Type": "application/json", "ms-cv": "0.0",
                                                         "calling-app-name": "iGreenLight", "calling-app-version": "0.1.0"],
                                               body: HTTP.jsonBody(["Products": chunk]))
                if let obj = r.object as? [String: Any], let products = obj["Products"] as? [String: [String: Any]] {
                    byProduct.merge(products) { a, _ in a }
                }
            } catch { log("GamePass", "catalog hydrate failed: \(error.localizedDescription)") }
        }
        return titles.map { t in
            var t = t
            if let p = byProduct[t.productId] {
                t.name = p["ProductTitle"] as? String ?? t.name
                t.publisher = p["PublisherName"] as? String
                if let img = (p["Image_Tile"] as? [String: Any])?["URL"] as? String ?? (p["Image_Poster"] as? [String: Any])?["URL"] as? String {
                    t.imageURL = URL(string: img.hasPrefix("//") ? "https:" + img : img)
                }
            }
            return t
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
