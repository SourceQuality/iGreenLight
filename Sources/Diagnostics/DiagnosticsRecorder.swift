import Foundation
import WebRTC

/// Captures everything about one streaming session into
/// `Application Support/iGreenLight/diagnostics/<timestamp>/` (inside the app's container):
///
/// * `run.json`            – experimental settings used for this run, then the results summary when the session ends
/// * `http.jsonl`          – gssv session calls (request/response bodies, headers we send), auth tokens stripped
/// * `offer.sdp` / `answer.sdp` – verbatim, plus `sdp-summary.json` / `sdp-summary.txt`
/// * `datachannels.jsonl`  – data-channel messages in both directions (decoded where known, hex otherwise)
/// * `stats.jsonl`         – WebRTC getStats once per second (inbound video/audio, selected candidate pair)
/// * `stats-raw-*.json`    – full getStats dumps (first sample and after 10 s)
/// * `frames.jsonl`        – sampled decoded frames: pixel format, bit depth, colour attachments, HDR metadata
/// * `pacing.jsonl`        – every 5 s: frames received / dropped by the renderer, arrival and on-screen intervals, repeated ticks
/// * `bitstream.jsonl`     – parameter sets parsed from the encoded stream (SPS/VPS: profile, bit depth, VUI colour)
/// * `summary.md`          – human-readable summary written at the end
///
/// It also appends one line per run to `diagnostics/runs.jsonl` (setting → results) for scripts/diag-table.py.
final class DiagnosticsRecorder: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: DiagnosticsRecorder?
    /// The recorder of the running session, or nil when diagnostics are off.
    static var current: DiagnosticsRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }

    /// `diagnostics` next to the log: in the app's container on the Mac, in Documents on iOS.
    static let rootURL = Platform.dataDirectory.appendingPathComponent("diagnostics", isDirectory: true)

    let directory: URL
    let runId: String
    private let queue = DispatchQueue(label: "app.igreenlight.diagnostics")
    private var handles: [String: FileHandle] = [:]
    private let started = Date()
    private var meta: [String: Any]
    private var agg = Aggregate()
    private var statsState = StatsState()
    private var dcOutCounts: [String: Int] = [:]
    private var frameCount = 0
    private var lastFrameKey = ""
    private var finished = false

    /// Live numbers for the overlay (read on the main thread; written on `queue`).
    private let liveLock = NSLock()
    private var _live: [String] = []
    var liveLines: [String] { liveLock.lock(); defer { liveLock.unlock() }; return _live }

    init?(meta: [String: Any]) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        var id = fmt.string(from: Date())
        var n = 2
        while FileManager.default.fileExists(atPath: Self.rootURL.appendingPathComponent(id).path) { id = fmt.string(from: Date()) + "-\(n)"; n += 1 }
        runId = id
        directory = Self.rootURL.appendingPathComponent(runId, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            log("Diag", "cannot create \(directory.path): \(error)"); return nil
        }
        self.meta = meta
        self.meta["runId"] = runId
        self.meta["startedAt"] = ISO8601DateFormatter().string(from: started)
        writeJSON("run.json", self.meta)
        log("Diag", "capturing session to \(directory.path)")
    }

    private var t: Double { Date().timeIntervalSince(started) }

    // MARK: Files
    private func append(_ file: String, _ obj: [String: Any]) {
        guard !finished else { return }
        var o = obj
        o["t"] = (t * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(o) as Any, options: [.sortedKeys]) else { return }
        let h: FileHandle
        if let existing = handles[file] { h = existing } else {
            let url = directory.appendingPathComponent(file)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let nh = try? FileHandle(forWritingTo: url) else { return }
            handles[file] = nh; h = nh
        }
        h.write(data); h.write(Data("\n".utf8))
    }

    private func writeJSON(_ file: String, _ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(obj) as Any, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent(file))
    }

    private func writeText(_ file: String, _ text: String) {
        try? Data(text.utf8).write(to: directory.appendingPathComponent(file))
    }

    // MARK: HTTP
    /// Called by `HTTP.request` for gssv session endpoints. Bodies are redacted before they're written.
    func recordHTTP(method: String, url: String, headers: [String: String], body: Data?, status: Int,
                    responseHeaders: [AnyHashable: Any], response: Data?, error: String?, ms: Double) {
        let reqHeaders = Redact.headers(headers)
        let respHeaders = Redact.headers(Dictionary(uniqueKeysWithValues: responseHeaders.map { ("\($0.key)", "\($0.value)") }))
        let reqBody = body.map(Redact.body)
        let respBody = response.map(Redact.body)
        let u = Redact.url(url)
        queue.async {
            var entry: [String: Any] = ["method": method, "url": u, "endpoint": Self.endpoint(u), "requestHeaders": reqHeaders,
                                        "status": status, "responseHeaders": respHeaders, "ms": (ms * 10).rounded() / 10]
            if let reqBody { entry["requestBody"] = reqBody }
            if let respBody { entry["responseBody"] = respBody }
            if let error { entry["error"] = error }
            self.append("http.jsonl", entry)
            let ep = Self.endpoint(u)
            self.agg.httpCounts[ep, default: 0] += 1
            if ep == "configuration", let obj = respBody as? [String: Any] { self.agg.configuration = obj }
            if ep == "play", let obj = respBody as? [String: Any] { self.agg.play = obj }
        }
    }

    static func endpoint(_ url: String) -> String {
        guard let path = URL(string: url)?.path else { return "?" }
        for e in ["play", "state", "configuration", "sdp", "ice", "connect", "keepalive", "waittime"] where path.contains("/\(e)") {
            return e
        }
        if path.contains("/sessions/") { return "session" }   // DELETE <session>
        return path
    }

    // MARK: SDP
    func recordSDP(offer: String? = nil, answer: String? = nil) {
        queue.async {
            if let offer { self.writeText("offer.sdp", offer); self.agg.offer = SDPSummary(offer) }
            if let answer { self.writeText("answer.sdp", answer); self.agg.answer = SDPSummary(answer) }
            guard let o = self.agg.offer else { return }
            let a = self.agg.answer
            var summary: [String: Any] = ["offer": o.json]
            if let a {
                summary["answer"] = a.json
                summary["negotiated"] = SDPSummary.negotiated(offer: o, answer: a)
            }
            self.writeJSON("sdp-summary.json", summary)
            self.writeText("sdp-summary.txt", SDPSummary.text(offer: o, answer: a))
        }
    }

    // MARK: Data channels
    enum Direction: String { case send, recv }

    func recordDataChannel(_ channel: String, _ dir: Direction, _ data: Data, binary: Bool) {
        queue.async {
            let decoded = DataChannelDecoder.decode(channel: channel, dir: dir, data: data)
            // Input reports go out at up to ~60/s; keep the first 50 of each type, then count.
            if channel == "input", dir == .send {
                let n = self.dcOutCounts[decoded.kind, default: 0] + 1
                self.dcOutCounts[decoded.kind] = n
                if n > 50 { self.agg.dcCounts["input/send/\(decoded.kind)", default: 0] += 1; return }
            }
            var entry: [String: Any] = ["channel": channel, "dir": dir.rawValue, "bytes": data.count, "binary": binary, "kind": decoded.kind]
            if let v = decoded.value { entry["decoded"] = v } else { entry["hex"] = data.prefix(512).map { String(format: "%02x", $0) }.joined() }
            self.append("datachannels.jsonl", entry)
            self.agg.dcCounts["\(channel)/\(dir.rawValue)/\(decoded.kind)", default: 0] += 1
            if !decoded.handled { self.agg.unhandled.insert("\(channel) \(dir.rawValue): \(decoded.kind)") }
        }
    }

    /// For things the app logs as unhandled (message types, transaction targets, input report types).
    func noteUnhandled(_ what: String) {
        queue.async { self.agg.unhandled.insert(what) }
    }

    func recordServerVideoSize(_ w: Int, _ h: Int) {
        queue.async {
            self.agg.serverVideoSizes.insert("\(w)x\(h)")
            self.append("events.jsonl", ["event": "serverMetadata", "width": w, "height": h])
        }
    }

    func event(_ name: String, _ info: [String: Any] = [:]) {
        queue.async { var e = info; e["event"] = name; self.append("events.jsonl", e) }
    }

    // MARK: Stats
    func recordStats(_ report: RTCStatisticsReport) {
        let raw = report.statistics.mapValues { st -> [String: Any] in
            var v: [String: Any] = st.values.mapValues { $0 as Any }
            v["type"] = st.type; v["id"] = st.id; v["timestamp_us"] = st.timestamp_us
            return v
        }
        queue.async {
            self.statsState.samples += 1
            if self.statsState.samples == 1 { self.writeJSON("stats-raw-first.json", raw) }
            if self.statsState.samples == 10 { self.writeJSON("stats-raw-10s.json", raw) }
            let s = StatsExtractor.extract(raw, state: &self.statsState)
            self.append("stats.jsonl", s)
            self.agg.add(stats: s)
            self.updateLive()
        }
    }

    // MARK: Frames
    /// Called from the decoder/render thread for every frame; samples the first frame, every 120th, and on any change.
    func recordFrame(_ frame: RTCVideoFrame) {
        frameCount += 1
        let info = FrameInspector.inspect(frame)
        let key = info["key"] as? String ?? ""
        guard frameCount == 1 || frameCount % 120 == 0 || key != lastFrameKey else { return }
        let changed = key != lastFrameKey
        lastFrameKey = key
        let n = frameCount
        queue.async {
            var e = info
            e.removeValue(forKey: "key")
            e["frame"] = n
            if changed { e["changed"] = true }
            self.append("frames.jsonl", e)
            self.agg.add(frame: e)
            self.updateLive()
        }
    }

    // MARK: Pacing
    /// One reporting window of the renderer's frame pacing numbers (every 5 s).
    func recordPacing(_ w: PacingWindow) {
        queue.async {
            self.append("pacing.jsonl", w.json)
            self.agg.pacing.append(w)
        }
    }

    // MARK: Bitstream
    func recordBitstream(_ info: [String: Any]) {
        queue.async {
            let key = (info["nal"] as? String ?? "") + (info["raw"] as? String ?? "")
            guard !self.agg.bitstreamKeys.contains(key) else { return }
            self.agg.bitstreamKeys.insert(key)
            self.append("bitstream.jsonl", info)
            self.agg.bitstream.append(info)
            self.updateLive()
        }
    }

    // MARK: Live overlay
    private func updateLive() {
        var l: [String] = []
        let sel = agg.answer.flatMap { SDPSummary.selectedVideoCodec($0) }
        l.append("codec: \(sel ?? "-")  decoder: \(agg.lastStats["decoderImplementation"] as? String ?? "-")")
        if let f = agg.lastFrame {
            l.append("frame: \(f["width"] ?? "?")x\(f["height"] ?? "?") \(f["pixelFormat"] ?? "?") (\(f["bitDepth"].map { "\($0)-bit" } ?? "?"))")
            l.append("color: \(f["colorPrimaries"] ?? "-") / \(f["transferFunction"] ?? "-") / \(f["yCbCrMatrix"] ?? "-")  HDR meta: \(f["hdrMetadata"] as? Bool == true ? "yes" : "no")")
        }
        if let b = agg.bitstream.last {
            l.append("bitstream: \(b["profile"] ?? "?") \(b["bitDepthLuma"].map { "\($0)-bit" } ?? "") \(b["colour"] ?? "")")
        }
        let s = agg.lastStats
        func n(_ k: String) -> String { (s[k] as? NSNumber).map { "\($0)" } ?? (s[k].map { "\($0)" } ?? "-") }
        l.append("bitrate \(n("videoMbps")) Mbps (max \(String(format: "%.1f", agg.maxMbps)))  QP \(n("avgQp"))  fps \(n("fps"))")
        l.append("NACK \(n("nackCount"))  PLI \(n("pliCount"))  freezes \(n("freezeCount"))  dropped \(n("framesDropped"))  lost \(n("packetsLost"))")
        if agg.answer != nil {
            l.append("color-space ext: \(agg.answer.map { SDPSummary.hasColorSpace($0) } == true ? "negotiated" : "not negotiated")")
        }
        l.append("capture: \(runId)")
        liveLock.lock(); _live = l; liveLock.unlock()
    }

    // MARK: Finish
    func finish(reason: String) {
        queue.sync {
            guard !finished else { return }
            finished = true
            let result = agg.result(offer: agg.offer, answer: agg.answer)
            meta["endedAt"] = ISO8601DateFormatter().string(from: Date())
            meta["durationSeconds"] = Int(t)
            meta["endReason"] = reason
            meta["result"] = result
            writeJSON("run.json", meta)
            writeText("summary.md", agg.markdown(meta: meta, result: result))
            for (_, h) in handles { try? h.close() }
            handles.removeAll()
            // One line per run for the comparison table.
            let index = Self.rootURL.appendingPathComponent("runs.jsonl")
            if !FileManager.default.fileExists(atPath: index.path) { FileManager.default.createFile(atPath: index.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: index),
               let d = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(meta) as Any, options: [.sortedKeys]) {
                h.seekToEndOfFile(); h.write(d); h.write(Data("\n".utf8)); try? h.close()
            }
        }
        log("Diag", "capture finished (\(reason)): \(directory.path)")
    }

    // MARK: JSON helpers
    static func jsonSafe(_ v: Any) -> Any? {
        switch v {
        case let d as [String: Any]: return d.compactMapValues { jsonSafe($0) }
        case let d as [AnyHashable: Any]: return Dictionary(uniqueKeysWithValues: d.compactMap { k, v in jsonSafe(v).map { ("\(k)", $0) } })
        case let a as [Any]: return a.compactMap { jsonSafe($0) }
        case let s as Set<String>: return s.sorted()
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            let d = n.doubleValue
            return d.isFinite ? n : nil
        case let d as Double: return d.isFinite ? d : nil
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let data as Data: return data.map { String(format: "%02x", $0) }.joined()
        case is NSNull: return NSNull()
        default: return "\(v)"
        }
    }
}

// MARK: - Redaction

/// Strips auth material before anything is written to disk.
enum Redact {
    static let sensitiveHeader = ["authorization", "x-xbl-contract-version-token", "cookie", "set-cookie", "x-ms-cv-token", "proxy-authorization"]

    static func isSensitiveKey(_ k: String) -> Bool {
        let l = k.lowercased()
        if l == "key" { return true }   // e.g. serverDetails.srtp.key in the /configuration response
        return ["token", "authorization", "ticket", "password", "secret", "accesskey", "cookie", "credential", "signature"]
            .contains { l.contains($0) }
    }

    static func headers(_ h: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in h {
            if sensitiveHeader.contains(k.lowercased()) || isSensitiveKey(k) { out[k] = "[redacted \(v.count) chars]" }
            else { out[k] = scrub(v) }
        }
        return out
    }

    static func url(_ s: String) -> String {
        guard var c = URLComponents(string: s), let items = c.queryItems else { return s }
        c.queryItems = items.map { isSensitiveKey($0.name) ? URLQueryItem(name: $0.name, value: "[redacted]") : $0 }
        return c.string ?? s
    }

    /// JSON bodies are parsed and redacted structurally; anything else is returned as (scrubbed) text.
    static func body(_ d: Data) -> Any {
        if d.isEmpty { return "" }
        if let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { return value(obj) }
        if let s = String(data: d, encoding: .utf8) { return scrub(s) }
        return "<\(d.count) bytes binary>"
    }

    static func value(_ v: Any, key: String? = nil) -> Any {
        if let key, isSensitiveKey(key) {
            if let s = v as? String { return "[redacted \(s.count) chars]" }
            if v is [String: Any] || v is [Any] { return "[redacted]" }
        }
        switch v {
        case let d as [String: Any]:
            return Dictionary(uniqueKeysWithValues: d.map { ($0.key, value($0.value, key: $0.key)) })
        case let a as [Any]:
            return a.map { value($0) }
        case let s as String:
            // gssv embeds JSON in strings (exchangeResponse); decode it so it's readable and redactable.
            if (s.hasPrefix("{") || s.hasPrefix("[")), let inner = try? JSONSerialization.jsonObject(with: Data(s.utf8)) {
                return ["_embeddedJSON": value(inner)]
            }
            return scrub(s)
        default:
            return v
        }
    }

    /// Removes JWT-looking strings and `Bearer`/`XBL3.0` credentials from free text.
    static func scrub(_ s: String) -> String {
        var out = s
        let patterns = [#"(?i)(bearer|xbl3\.0)\s+[^\s"',]+"#, #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]*"#,
                        #"(?i)(t=|d=)[A-Za-z0-9%_\-\.\*!]{40,}"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
            }
        }
        return out
    }
}
