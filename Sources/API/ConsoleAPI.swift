import Foundation

struct XboxConsole: Identifiable, Hashable, Codable {
    let id: String          // serverId
    let name: String
    let consoleType: String
    let powerState: String
    let playPath: String?
    let outOfHomeWarning: Bool?
    let wirelessWarning: Bool?

    var isOn: Bool { powerState == "On" }
    var powerLabel: String {
        switch powerState {
        case "ConnectedStandby": "Standby"
        case "Unknown": "Unknown"
        default: powerState
        }
    }
    var typeLabel: String {
        switch consoleType {
        case "XboxSeriesX": "Xbox Series X"
        case "XboxSeriesS": "Xbox Series S"
        case "XboxOne": "Xbox One"
        case "XboxOneS": "Xbox One S"
        case "XboxOneX": "Xbox One X"
        default: consoleType
        }
    }
}

enum ConsoleAPI {
    /// GET {xhome base}/v6/servers/home (what xbox.com/play uses for Remote Play).
    static func homeServers(baseURL: String, gsToken: String) async throws -> [XboxConsole] {
        let r = try await HTTP.request("GET", baseURL + "/v6/servers/home?mr=50", headers: [
            "Authorization": "Bearer " + gsToken,
            "Accept": "application/json",
            "X-Gssv-Client": "XboxComBrowser",
        ])
        log("Consoles", "/v6/servers/home -> \(r.text.prefix(600))")
        guard let obj = r.object as? [String: Any], let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { d in
            guard let id = d["serverId"] as? String else { return nil }
            return XboxConsole(id: id, name: d["deviceName"] as? String ?? id,
                               consoleType: d["consoleType"] as? String ?? "Xbox",
                               powerState: d["powerState"] as? String ?? "Unknown",
                               playPath: d["playPath"] as? String,
                               outOfHomeWarning: d["outOfHomeWarning"] as? Bool,
                               wirelessWarning: d["wirelessWarning"] as? Bool)
        }
    }

    /// Fallback: SmartGlass device list (Greenlight desktop v2 uses this via xbox-webapi).
    static func smartglass(web: XboxAuth.XSTSToken) async throws -> [XboxConsole] {
        let r = try await HTTP.request("GET", "https://xccs.xboxlive.com/lists/devices?queryCurrentDevice=false&includeStorageDevices=true", headers: [
            "Authorization": "XBL3.0 x=\(web.uhs);\(web.Token)",
            "x-xbl-contract-version": "4",
            "skillplatform": "RemoteManagement",
            "Accept-Language": "en-US",
        ])
        guard let obj = r.object as? [String: Any], let results = obj["result"] as? [[String: Any]] else { return [] }
        return results.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return XboxConsole(id: id, name: d["name"] as? String ?? id, consoleType: d["consoleType"] as? String ?? "Xbox",
                               powerState: d["powerState"] as? String ?? "Unknown", playPath: nil,
                               outOfHomeWarning: nil, wirelessWarning: nil)
        }
    }
}
