import Foundation

/// Teredo decoding and candidate helpers (Greenlight ice.ts / teredo.ts).
enum ICEHelper {
    /// For a Teredo address 2001:0:SSSS:SSSS:FLAG:PORT:CLIENT:CLIENT returns the obfuscated client IPv4 + port.
    static func teredo(_ address: String) -> (ip: String, port: Int)? {
        let parts = expandIPv6(address)
        guard parts.count == 8, parts[0] == "2001", Int(parts[1], radix: 16) == 0 else { return nil }
        guard let p = UInt16(parts[5], radix: 16), let hi = UInt16(parts[6], radix: 16), let lo = UInt16(parts[7], radix: 16) else { return nil }
        let ip = [~UInt8(hi >> 8), ~UInt8(hi & 0xff), ~UInt8(lo >> 8), ~UInt8(lo & 0xff)].map(String.init).joined(separator: ".")
        return (ip, Int(~p))
    }

    static func expandIPv6(_ s: String) -> [String] {
        let halves = s.components(separatedBy: "::")
        let head = halves[0].isEmpty ? [] : halves[0].split(separator: ":").map(String.init)
        let tail = halves.count > 1 && !halves[1].isEmpty ? halves[1].split(separator: ":").map(String.init) : []
        let fill = halves.count > 1 ? Array(repeating: "0", count: max(0, 8 - head.count - tail.count)) : []
        return (head + fill + tail).map { $0.lowercased() }
    }

    static func hostCandidate(foundation: Int, ip: String, port: Int) -> String {
        "candidate:\(foundation) 1 UDP 1 \(ip) \(port) typ host "
    }

    /// The gssv service sends candidates as "a=candidate:..."; libwebrtc wants "candidate:...".
    static func stripPrefix(_ c: String) -> String { c.hasPrefix("a=") ? String(c.dropFirst(2)) : c }

    /// One entry of the gssv `/ice` answer as libwebrtc wants it; nil for end-of-candidates and malformed entries.
    static func remoteCandidate(_ c: [String: Any]) -> (sdp: String, mid: String, index: Int32)? {
        guard let raw = c["candidate"] as? String, !raw.contains("end-of-candidates") else { return nil }
        let mid = (c["sdpMid"] as? String) ?? (c["sdpMid"] as? Int).map(String.init) ?? "0"
        let index = Int32((c["sdpMLineIndex"] as? Int) ?? Int((c["sdpMLineIndex"] as? String) ?? "0") ?? 0)
        return (stripPrefix(raw), mid, index)
    }

    /// One of our candidates as the `/ice` endpoint takes it: what a browser's `RTCIceCandidate` serialises to, which is
    /// what the official client sends. No `a=` in front (only the console's own candidates carry one); with it the
    /// console may not read the entry, which goes unnoticed on the same network, where it learns our address from the
    /// packets we send it, but not away from home, where it has to send to our public address first.
    static func localCandidate(sdp: String, mid: String?, index: Int32) -> [String: Any] {
        var c: [String: Any] = ["candidate": stripPrefix(sdp), "sdpMid": mid ?? "0", "sdpMLineIndex": index]
        let parts = sdp.split(separator: " ")
        if let i = parts.firstIndex(of: "ufrag"), i + 1 < parts.count { c["usernameFragment"] = String(parts[i + 1]) }
        return c
    }

    /// The STUN servers the session configuration names (`serverDetails.stunServerAddresses`), as libwebrtc takes them.
    static func stunServers(_ serverDetails: [String: Any]) -> [String] {
        ((serverDetails["stunServerAddresses"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("stun:") && $0.count > 5 }
    }

    static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".")
        return p.count == 4 && p.allSatisfy { UInt8($0) != nil }
    }
}
