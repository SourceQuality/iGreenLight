import Foundation
import WebRTC

struct StreamStats {
    var fps: Double = 0
    var resolution = "-"
    var bitrateMbps: Double = 0
    var rttMs: Double?
    var packetsLost: Int = 0
    var jitterMs: Double = 0
    var decodeMs: Double?
    var codec = "-"
    var path = "-"           // e.g. "host 192.168.1.20:9002 (udp)"
    var metalFX = false
    var serverSize: String?
}

/// Turns RTCStatisticsReport snapshots into overlay numbers (Greenlight stats.ts).
final class StatsSampler {
    private var lastBytes: Double = 0
    private var lastTime: Double = 0
    private var lastDecodeTime: Double = 0
    private var lastFramesDecoded: Double = 0
    private var sampleCount = 0

    func sample(_ report: RTCStatisticsReport) -> StreamStats {
        var s = StreamStats()
        let all = report.statistics
        func num(_ v: NSObject?) -> Double? { (v as? NSNumber)?.doubleValue }
        for (_, st) in all where st.type == "inbound-rtp" && (st.values["kind"] as? String) == "video" {
            let v = st.values
            sampleCount += 1
            if sampleCount % 5 == 1 {
                let keys = ["framesReceived", "framesDecoded", "keyFramesDecoded", "framesDropped", "frameWidth", "frameHeight", "decoderImplementation", "powerEfficientDecoder", "pliCount", "firCount", "nackCount", "framesPerSecond", "trackIdentifier"]
                log("Stats", "inbound video: " + keys.map { "\($0)=\(v[$0].map { "\($0)" } ?? "-")" }.joined(separator: " "))
            }
            s.fps = num(v["framesPerSecond"]) ?? 0
            if let w = num(v["frameWidth"]), let h = num(v["frameHeight"]) { s.resolution = "\(Int(w))x\(Int(h))" }
            s.packetsLost = Int(num(v["packetsLost"]) ?? 0)
            s.jitterMs = (num(v["jitter"]) ?? 0) * 1000
            let bytes = num(v["bytesReceived"]) ?? 0
            let t = st.timestamp_us / 1_000_000
            if lastTime > 0, t > lastTime { s.bitrateMbps = (bytes - lastBytes) * 8 / (t - lastTime) / 1_000_000 }
            lastBytes = bytes; lastTime = t
            let dt = num(v["totalDecodeTime"]) ?? 0, fd = num(v["framesDecoded"]) ?? 0
            if fd > lastFramesDecoded { s.decodeMs = (dt - lastDecodeTime) / (fd - lastFramesDecoded) * 1000 }
            lastDecodeTime = dt; lastFramesDecoded = fd
            if let cid = v["codecId"] as? String, let c = all[cid] { s.codec = (c.values["mimeType"] as? String ?? "-").replacingOccurrences(of: "video/", with: "") }
        }
        for (_, st) in all where st.type == "candidate-pair" {
            let v = st.values
            guard (v["state"] as? String) == "succeeded", (v["nominated"] as? NSNumber)?.boolValue == true else { continue }
            if let rtt = num(v["currentRoundTripTime"]) { s.rttMs = rtt * 1000 }
            if let rid = v["remoteCandidateId"] as? String, let r = all[rid]?.values {
                let type = r["candidateType"] as? String ?? "?"
                let addr = r["address"] as? String ?? r["ip"] as? String ?? "?"
                let port = (r["port"] as? NSNumber)?.intValue ?? 0
                s.path = "\(type) \(addr):\(port) (\(r["protocol"] as? String ?? "udp"))"
            }
        }
        return s
    }
}
