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

    static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".")
        return p.count == 4 && p.allSatisfy { UInt8($0) != nil }
    }
}
