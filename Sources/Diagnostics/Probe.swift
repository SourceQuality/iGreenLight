import Foundation
import WebRTC

/// Headless hypothesis runner: `iGreenLight --probe <spec.json> --probe-out <results.jsonl>` (see scripts/probe.sh).
///
/// For each probe in the spec it starts a Remote Play session, sends a crafted SDP offer, records whether the
/// console answers and which codec it picks, optionally lets media flow for a few seconds (bit depth, colour,
/// bitrate from the bitstream/frames/stats), then deletes the session. No stream window, no clicks.
///
/// Spec: `{"gapSeconds": 10, "serverId": "<optional>", "probes": [Probe…]}` where a probe may set
/// * `name`
/// * `osName`, `sdk` ("greenlight" | "current"), `size` [w, h]
/// * `deviceInfoMerge`   – deep-merged into X-MS-Device-Info
/// * `playBodyMerge`     – deep-merged into the /play body (e.g. {"settings": {"nanoVersion": "…"}})
/// * `sdpConfigMerge`    – deep-merged into the /sdp `configuration`
/// * `headers`           – extra HTTP headers on session calls
/// * `codec` (VideoCodecPreference raw value), `onlyPreferred`, `maxKbps`
/// * `wireReplace`       – [[from, to], …] literal replacements applied to the offer text sent to the console only
///                         (the local description stays valid; the answer is then recorded but not applied)
/// * `wireAppendVideo`   – extra lines appended to the m=video section on the wire
/// * `extraOffers`       – [[[from, to], …], …] further wire offers tried in the same session after the first
/// * `capabilities`      – content of the clientdevicecapabilities message
/// * `messages`          – [{"target": "/streaming/…", "content": {…}}] sent on the message channel after config
/// * `control`           – extra control-channel JSON messages; with `"afterSeconds": n` sent n s into the media phase
/// * `frameMetadata`     – {"decodeMs": 4, "renderMs": 2}: send per-frame timing feedback on the input channel
/// * `mediaSeconds`      – 0 (default) = stop after the SDP answer; >0 = connect and capture that many seconds
enum Probe {
    static var specPath: String? { arg("--probe") }
    static var outPath: String? { arg("--probe-out") }
    static var requested: Bool { specPath != nil }
    @MainActor static var started = false

    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    @MainActor
    static func run(auth: AuthManager) async {
        guard let specPath, let data = FileManager.default.contents(atPath: specPath),
              let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let probes = spec["probes"] as? [[String: Any]] else {
            log("Probe", "cannot read spec \(specPath ?? "-")"); return
        }
        let out = outPath ?? (specPath + ".results.jsonl")
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = FileHandle(forWritingAtPath: out)
        func emit(_ obj: [String: Any]) {
            if let d = try? JSONSerialization.data(withJSONObject: DiagnosticsRecorder.jsonSafe(obj) as Any, options: [.sortedKeys]) {
                handle?.write(d); handle?.write(Data("\n".utf8))
            }
        }
        // Sign in from the Keychain.
        auth.bootstrap()
        for _ in 0..<120 {
            if auth.state == .signedIn { break }
            if case .failed(let m) = auth.state { emit(["error": "auth failed: \(m)"]); return }
            if auth.state == .signedOut { emit(["error": "not signed in"]); return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard auth.state == .signedIn, let token = try? await auth.streamToken(cloud: false) else { emit(["error": "no stream token"]); return }
        let base = auth.baseURL(cloud: false, token: token)
        var serverId = spec["serverId"] as? String
        if serverId == nil {
            let consoles = (try? await ConsoleAPI.homeServers(baseURL: base, gsToken: token.gsToken)) ?? []
            serverId = (consoles.first { $0.isOn } ?? consoles.first)?.id
        }
        guard let serverId else { emit(["error": "no console found"]); return }
        let gap = spec["gapSeconds"] as? Double ?? 10
        for (i, p) in probes.enumerated() {
            if i > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1e9)) }
            let name = p["name"] as? String ?? "probe \(i)"
            log("Probe", "=== \(name) ===")
            var result = await one(p, name: name, auth: auth, base: base, token: token, serverId: serverId)
            result["name"] = name
            result["index"] = i
            emit(result)
        }
        emit(["done": true])
        try? handle?.close()
    }

    @MainActor
    static func one(_ p: [String: Any], name: String, auth: AuthManager, base: String, token: XboxAuth.StreamToken, serverId: String) async -> [String: Any] {
        var r: [String: Any] = [:]
        let t0 = Date()
        let osName = p["osName"] as? String ?? "windows"
        let sdk = SDKProfile(rawValue: p["sdk"] as? String ?? "greenlight") ?? .greenlight
        let size = (p["size"] as? [Int]).flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil } ?? (1920, 1080)
        var deviceInfo = DeviceInfo.header(osName: osName, sdk: sdk, width: size.0, height: size.1)
        if let merge = p["deviceInfoMerge"] as? [String: Any],
           let obj = (try? JSONSerialization.jsonObject(with: Data(deviceInfo.utf8))) as? [String: Any] {
            deviceInfo = String(data: HTTP.jsonBody(SessionAPI.deepMerge(obj, merge)), encoding: .utf8)!
        }
        let rec = DiagnosticsRecorder(meta: ["target": "probe: \(name)", "settings": ["probe": name, "selftest": true, "spec": p], "deviceInfo": deviceInfo])
        DiagnosticsRecorder.current = rec
        r["capture"] = rec?.runId
        var api = SessionAPI(baseURL: base, gsToken: token.gsToken, kind: .home, deviceInfo: deviceInfo)
        api.playBodyMerge = p["playBodyMerge"] as? [String: Any] ?? [:]
        api.sdpConfigMerge = p["sdpConfigMerge"] as? [String: Any] ?? [:]
        api.extraHeaders = p["headers"] as? [String: String] ?? [:]
        var rtc: WebRTCClient?
        var track: RTCVideoTrack?
        let tap = SelfTest.FrameTap()
        do {
            _ = try await api.play(target: serverId, locale: AppSettings.shared.locale, osName: osName)
            try await api.waitForProvisioned(pollNanoseconds: 700_000_000, maxPolls: 60, transferToken: { try await auth.transferToken() })
            r["provisionSeconds"] = round1(Date().timeIntervalSince(t0))
            if let cfg = try? await api.configuration() { r["configurationKeys"] = cfg.keys.sorted() }

            let pref = VideoCodecPreference(rawValue: p["codec"] as? String ?? "h264High") ?? .h264High
            let client = try WebRTCClient(options: .init(codec: pref, onlyPreferredCodec: p["onlyPreferred"] as? Bool ?? false,
                                                    maxVideoBitrateKbps: p["maxKbps"] as? Int ?? 0))
            rtc = client
            client.message.deviceCapabilities = p["capabilities"] as? [String: Any] ?? [:]
            client.message.extraMessages = (p["messages"] as? [[String: Any]] ?? []).compactMap { m in
                (m["target"] as? String).map { ($0, m["content"] as? [String: Any] ?? [:]) }
            }
            let controlExtras = p["control"] as? [[String: Any]] ?? []
            client.message.onHandshake = { [weak client] in
                guard let client else { return }
                client.control.sendAuthorization()
                client.control.gamepadChanged(index: 0, added: true)
                client.input.sendClientMetadata()
                for c in controlExtras where c["afterSeconds"] == nil { client.control.sendJSON(c) }
            }
            if let fm = p["frameMetadata"] as? [String: Any] {
                let decodeMs = (fm["decodeMs"] as? NSNumber)?.doubleValue ?? 4, renderMs = (fm["renderMs"] as? NSNumber)?.doubleValue ?? 2
                tap.onFrame = { [weak client] frame in
                    let ts = UInt32(bitPattern: frame.timeStamp)
                    client?.queue.async { client?.input.sendFrameMetadata(rtpTimestamp: ts, decodeMs: decodeMs, renderMs: renderMs) }
                }
            } else { tap.onFrame = nil }
            client.onVideoTrack = { t in if track == nil { track = t; t.add(tap) } }

            let offer = try await client.createOffer()
            let replace = (p["wireReplace"] as? [[String]] ?? []).filter { $0.count == 2 }
            let append = p["wireAppendVideo"] as? [String] ?? []
            var wireSets: [[[String]]] = [replace]
            wireSets += (p["extraOffers"] as? [[[String]]] ?? [])
            var answers: [[String: Any]] = []
            var firstAnswer: String?
            for (n, set) in wireSets.enumerated() {
                var wire = offer
                for pair in set where pair.count == 2 {
                    if pair[0] == "@label" { continue }
                    if pair[0] == "@imageattr" {
                        // The official client's 1080p limiter: an imageattr line after every fmtp (pair[1] = "1920x1080").
                        let wh = pair[1].split(separator: "x").map(String.init)
                        if wh.count == 2, let re = try? NSRegularExpression(pattern: "a=fmtp:(\\w+)([^\\r\\n]*)") {
                            wire = re.stringByReplacingMatches(in: wire, range: NSRange(wire.startIndex..., in: wire),
                                                               withTemplate: "a=fmtp:$1$2\r\na=imageattr:$1 recv [x=[0:\(wh[0])],y=[0:\(wh[1])],fps=[0:60]]")
                        }
                        continue
                    }
                    if pair[0] == "@codecs" { wire = rewriteVideoCodecs(wire, pair[1]) }
                    else if pair[0] == "@appendVideo" { wire = appendToVideo(wire, pair[1].components(separatedBy: "|")) }
                    else { wire = wire.replacingOccurrences(of: pair[0], with: pair[1]) }
                }
                if n == 0, !append.isEmpty { wire = appendToVideo(wire, append) }
                if n == 0 { rec?.recordSDP(offer: wire) }
                var a: [String: Any] = ["offerVideo": videoLines(wire)]
                if let label = set.first(where: { $0.first == "@label" })?.last { a["label"] = label }
                do {
                    let (sdp, response) = try await api.exchangeSDPDetailed(offer: wire, requestId: "\(n + 1)")
                    if let sdp {
                        if n == 0 { firstAnswer = sdp; rec?.recordSDP(answer: sdp) }
                        let s = SDPSummary(sdp)
                        a["accepted"] = true
                        a["selected"] = SDPSummary.selectedVideoCodec(s) ?? "-"
                        a["answerVideo"] = videoLines(sdp)
                        a["colorSpaceExt"] = SDPSummary.hasColorSpace(s)
                    } else {
                        a["accepted"] = false
                    }
                    var other = response
                    other.removeValue(forKey: "sdp"); other.removeValue(forKey: "debugInfo")
                    a["response"] = other.mapValues { "\($0)".prefix(300).description }
                } catch { a["accepted"] = false; a["error"] = "\(error)".prefix(300).description }
                answers.append(a)
            }
            r["offers"] = answers
            r["accepted"] = answers.first?["accepted"] ?? false
            r["selected"] = answers.first?["selected"] ?? "-"

            let media = p["mediaSeconds"] as? Int ?? 0
            if media > 0, let answer = firstAnswer {
                if !replace.isEmpty || !append.isEmpty { r["note"] = "wire offer differs from local description; applying the answer may fail" }
                try await client.setRemoteAnswer(answer)
                let remote = try await api.exchangeICE(await client.localCandidatePayload())
                for c in remote {
                    guard let (sdp, mid, index) = ICEHelper.remoteCandidate(c) else { continue }
                    await client.addRemoteCandidate(sdp, mid: mid, index: index)
                }
                for second in 0..<(media + 6) {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    // Control messages with "afterSeconds": n are sent n seconds into the media phase.
                    for var c in controlExtras where (c["afterSeconds"] as? Int) == second {
                        c["afterSeconds"] = nil
                        rec?.event("probe.control", ["second": second, "message": c])
                        client.control.sendJSON(c)
                    }
                    rec?.recordStats(await client.stats())
                }
                r["framesDecoded"] = tap.frames
            }
        } catch {
            r["error"] = "\(error)".prefix(400).description
        }
        if let track { track.remove(tap) }
        if let rtc { rtc.queue.async { rtc.control.gamepadChanged(index: 0, added: false) }; try? await Task.sleep(nanoseconds: 200_000_000); rtc.close() }
        await api.stop()
        rec?.finish(reason: "probe")
        DiagnosticsRecorder.current = nil
        // Pull the media facts out of the finished capture.
        if let rec, let d = FileManager.default.contents(atPath: rec.directory.appendingPathComponent("run.json").path),
           let run = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let res = run["result"] as? [String: Any] {
            let sps = (res["bitstream"] as? [[String: Any]] ?? []).filter { $0["nal"] as? String == "SPS" }
            if !sps.isEmpty {
                r["sps"] = sps.map { "\($0["profile"] ?? "?") \($0["width"] ?? "?")x\($0["height"] ?? "?") \($0["bitDepthLuma"] ?? "?")-bit, \($0["colour"] ?? "-")" }
            }
            let sei = (res["bitstream"] as? [[String: Any]] ?? []).filter { $0["nal"] as? String == "SEI" }.compactMap { $0["seiTypes"] }
            if !sei.isEmpty { r["seiTypes"] = sei }
            for k in ["pixelFormats", "colorInfo", "hdrMetadataSeen", "statsResolutions", "videoMbps", "unhandledMessages", "serverReportedVideoSizes"] {
                if let v = res[k], !((v as? [Any])?.isEmpty ?? false), !((v as? [String: Any])?.isEmpty ?? false) { r[k] = v }
            }
        }
        r["seconds"] = round1(Date().timeIntervalSince(t0))
        return r
    }

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// rtpmap/fmtp/b= lines of the video section, for compact reporting.
    static func videoLines(_ sdp: String) -> [String] {
        var inVideo = false
        var out: [String] = []
        for line in sdp.components(separatedBy: "\r\n") {
            if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video"); if inVideo { out.append(line) }; continue }
            if inVideo, line.hasPrefix("a=rtpmap") || line.hasPrefix("a=fmtp") || line.hasPrefix("b=") || line.hasPrefix("a=x-") { out.append(line) }
        }
        return out
    }

    /// `["@codecs", "H265 profile-id=2;tier-flag=0|H264 profile-level-id=42e01f;packetization-mode=1"]`:
    /// replaces the video section's codec list (payload types 96, 97, …) with exactly these, each with the usual rtcp-fb.
    static func rewriteVideoCodecs(_ sdp: String, _ spec: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let m = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else { return sdp }
        let end = lines[(m + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.count
        var section = lines[(m + 1)..<end].filter { !$0.hasPrefix("a=rtpmap:") && !$0.hasPrefix("a=fmtp:") && !$0.hasPrefix("a=rtcp-fb:") }
        var pts: [String] = []
        for (i, entry) in spec.components(separatedBy: "|").enumerated() {
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty else { continue }
            let pt = "\(96 + i)"
            pts.append(pt)
            section.append("a=rtpmap:\(pt) \(name.contains("/") ? name : name + "/90000")")
            if !["ulpfec", "red", "rtx"].contains(name.lowercased()) {
                for fb in ["goog-remb", "transport-cc", "ccm fir", "nack", "nack pli"] { section.append("a=rtcp-fb:\(pt) \(fb)") }
            }
            if parts.count > 1 { section.append("a=fmtp:\(pt) \(parts[1])") }
        }
        var mline = lines[m].split(separator: " ").prefix(3).map(String.init)
        mline += pts
        lines.replaceSubrange(m..<end, with: [mline.joined(separator: " ")] + section)
        return lines.joined(separator: "\r\n")
    }

    static func appendToVideo(_ sdp: String, _ extra: [String]) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let m = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else { return sdp }
        let end = lines[(m + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.count
        lines.insert(contentsOf: extra, at: end)
        return lines.joined(separator: "\r\n")
    }
}
