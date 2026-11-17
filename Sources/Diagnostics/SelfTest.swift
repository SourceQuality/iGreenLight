import Foundation
import WebRTC
import VideoToolbox
import CoreMedia

/// `iGreenLight --diagnostics-selftest`: exercises the diagnostics capture with no console and no Microsoft traffic.
///
/// 1. Redaction: a fake gssv exchange with tokens goes through `recordHTTP`; the files are checked for the secrets.
/// 2. Loopback WebRTC: the app's `WebRTCClient` (with the app decoder factory + codec preferences) talks to a local
///    peer that plays "server" — encodes a synthetic video source, answers the data-channel handshake, sends a
///    ServerMetadata input report and a message type the app doesn't handle. One capture run per codec preference.
/// 3. HEVC: encodes 10-bit HEVC Main 10 with BT.2020/PQ + HDR10 metadata through VideoToolbox, feeds the Annex B
///    stream into the app's H265 decoder and checks the decoded CVPixelBuffer (x420, PQ attachments).
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--diagnostics-selftest") }

    static func out(_ s: String) { print(s); log("SelfTest", s) }

    @MainActor
    static func run() async {
        setvbuf(stdout, nil, _IONBF, 0)
        out("diagnostics root: \(DiagnosticsRecorder.rootURL.path)")
        var failures: [String] = []
        failures += redaction()
        let only = ProcessInfo.processInfo.environment["SELFTEST_ONLY"]
        if only == nil || only == "loopback" { for pref in [VideoCodecPreference.h264High, .h264Main, .hevcMain10, .vp9p0, .vp9p2, .av1] {
            failures += await loopback(pref, bitrateKbps: pref == .h264High ? 8000 : 0)
        } }
        if only == nil || only == "hevc" { failures += await hevcMain10() }
        out(failures.isEmpty ? "SELFTEST PASSED" : "SELFTEST FAILED:\n  " + failures.joined(separator: "\n  "))
    }

    // MARK: 1. Redaction
    static func redaction() -> [String] {
        guard let rec = DiagnosticsRecorder(meta: ["target": "selftest: redaction", "settings": ["test": "redaction", "selftest": true]]) else { return ["recorder init"] }
        let secretJWT = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzZWxmdGVzdHNlY3JldCJ9.c2lnbmF0dXJlc2VsZnRlc3Q"
        let gs = "GSTOKEN-SELFTEST-SECRET-123456"
        rec.recordHTTP(method: "POST", url: "https://uks.core.gssv-play-prodxhome.xboxlive.com/v5/sessions/home/ABC/connect?token=QUERYSECRET",
                       headers: ["Authorization": "Bearer " + gs, "X-MS-Device-Info": "{\"dev\":{}}", "Content-Type": "application/json"],
                       body: Data("{\"userToken\":\"\(secretJWT)\",\"other\":\"keep-me\"}".utf8), status: 202,
                       responseHeaders: ["Set-Cookie": "a=SECRETCOOKIE"], response: Data("{\"ok\":true,\"note\":\"Bearer \(gs)\"}".utf8), error: nil, ms: 12)
        rec.recordHTTP(method: "GET", url: "https://x/v5/sessions/home/ABC/sdp", headers: ["Authorization": "Bearer " + gs], body: nil, status: 200,
                       responseHeaders: [:], response: Data(#"{"exchangeResponse":"{\"sdp\":\"v=0\",\"status\":\"success\"}","errorDetails":{}}"#.utf8), error: nil, ms: 3)
        rec.finish(reason: "selftest")
        let text = (try? String(contentsOf: rec.directory.appendingPathComponent("http.jsonl"), encoding: .utf8)) ?? ""
        var f: [String] = []
        for s in [secretJWT, gs, "QUERYSECRET", "SECRETCOOKIE"] where text.contains(s) { f.append("redaction leaked \(s.prefix(12))…") }
        if !text.contains("keep-me") { f.append("redaction removed a non-secret field") }
        if !text.contains("_embeddedJSON") { f.append("exchangeResponse not decoded") }
        out("redaction: \(f.isEmpty ? "ok" : "FAIL") (\(rec.directory.lastPathComponent))")
        return f
    }

    // MARK: 2. Loopback
    final class FakeServer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        var pc: RTCPeerConnection!
        var candidates: [RTCIceCandidate] = []
        var channels: [RTCDataChannel] = []
        let lock = NSLock()
        lazy var source = factory.videoSource()
        lazy var capturer = RTCVideoCapturer(delegate: source)

        override init() {
            super.init()
            let cfg = RTCConfiguration()
            cfg.sdpSemantics = .unifiedPlan
            cfg.bundlePolicy = .maxBundle
            pc = factory.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        }

        func answer(_ offer: String) async throws -> String {
            try await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer))
            let track = factory.videoTrack(with: source, trackId: "selftest-video")
            // Reject audio so the client never opens CoreAudio (mic permission would block a terminal-launched run).
            for t in pc.transceivers where t.mediaType == .audio {
                var err: NSError?
                t.setDirection(.inactive, error: &err)
            }
            for t in pc.transceivers where t.mediaType == .video {
                t.sender.track = track
                var err: NSError?
                t.setDirection(.sendOnly, error: &err)
            }
            let a = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await pc.setLocalDescription(a)
            return a.sdp
        }

        func pushFrame(_ i: Int, width: Int = 1280, height: Int = 720) {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let p = y.assumingMemoryBound(to: UInt8.self)
                for row in 0..<height { memset(p + row * stride, Int32((row + i * 4) & 0xff), width) }
            }
            if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pb), rotation: ._0, timeStampNs: Int64(i) * 33_333_333)
            source.capturer(capturer, didCapture: frame)
        }

        // Delegates
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            lock.lock(); candidates.append(candidate); lock.unlock()
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
            lock.lock(); channels.append(dataChannel); lock.unlock()
            dataChannel.delegate = self
        }
        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            guard dataChannel.readyState == .open, dataChannel.label == "input" else { return }
            // ServerMetadata report: type 16, then height, width (u32 LE) at offsets 2 and 6.
            var b: [UInt8] = [16, 0]
            for v in [UInt32(1080), UInt32(1920)] { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
            dataChannel.sendData(RTCDataBuffer(data: Data(b), isBinary: true))
            dataChannel.sendData(RTCDataBuffer(data: Data([0x00, 0x04, 1, 2, 3]), isBinary: true))   // unknown report type 0x400
        }
        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
            guard dataChannel.label == "message",
                  let obj = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any], obj["type"] as? String == "Handshake" else { return }
            func send(_ o: [String: Any]) { dataChannel.sendData(RTCDataBuffer(data: try! JSONSerialization.data(withJSONObject: o), isBinary: true)) }
            send(["type": "HandshakeAck", "id": obj["id"] ?? "", "cv": "0"])
            send(["type": "SelfTestUnknownType", "payload": 1])
            send(["type": "Message", "target": "/streaming/selftest/unhandledTarget", "content": "{\"x\":1}", "id": "1", "cv": ""])
        }
    }

    final class FrameTap: NSObject, RTCVideoRenderer {
        var frames = 0
        var onFrame: ((RTCVideoFrame) -> Void)?
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            frames += 1
            onFrame?(frame)
            DiagnosticsRecorder.current?.recordFrame(frame)
        }
    }

    @MainActor
    static func loopback(_ pref: VideoCodecPreference, bitrateKbps: Int) async -> [String] {
        guard let rec = DiagnosticsRecorder(meta: ["target": "selftest: loopback \(pref.rawValue)",
                                                   "settings": ["codecPreference": pref.rawValue, "maxVideoBitrateKbps": bitrateKbps, "selftest": true]]) else {
            return ["recorder init"]
        }
        DiagnosticsRecorder.current = rec
        defer { DiagnosticsRecorder.current = nil }
        var f: [String] = []
        let client = WebRTCClient(options: .init(codec: pref, onlyPreferredCodec: false, maxVideoBitrateKbps: bitrateKbps))
        let server = FakeServer()
        let tap = FrameTap()
        var track: RTCVideoTrack?
        client.onVideoTrack = { t in if track == nil { track = t; t.add(tap) } }
        do {
            let offer = try await client.createOffer()
            rec.recordSDP(offer: offer)
            let answer = try await server.answer(offer)
            rec.recordSDP(answer: answer)
            try await client.setRemoteAnswer(answer)
            out("  answer set; adding candidates")
            for c in await client.gatheredCandidates() { try? await server.pc.add(c) }
            out("  client candidates added")
            try? await Task.sleep(nanoseconds: 500_000_000)
            server.lock.lock(); let sc = server.candidates; server.lock.unlock()
            for c in sc { await client.addRemoteCandidate(c.sdp, mid: c.sdpMid, index: c.sdpMLineIndex) }
            out("  server candidates added (\(sc.count)); pushing frames")
            for second in 0..<7 {
                for i in 0..<30 {
                    if second == 0, i < 2 { out("  push \(i)") }
                    server.pushFrame(second * 30 + i)
                    if second == 0, i < 2 { out("  pushed \(i)") }
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
                if second == 0 { out("  stats…") }
                rec.recordStats(await client.stats())
                out("  second \(second): \(tap.frames) frames")
            }
        } catch { f.append("\(pref.rawValue): \(error)") }
        track?.remove(tap)
        client.close(); server.pc.close()
        rec.finish(reason: "selftest")
        // Checks
        let dir = rec.directory
        func read(_ n: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)) ?? "" }
        let run = (try? JSONSerialization.jsonObject(with: Data(read("run.json").utf8))) as? [String: Any] ?? [:]
        let result = run["result"] as? [String: Any] ?? [:]
        for file in ["offer.sdp", "answer.sdp", "sdp-summary.json", "sdp-summary.txt", "datachannels.jsonl", "stats.jsonl", "frames.jsonl", "summary.md", "stats-raw-first.json"]
            where read(file).isEmpty { f.append("\(pref.rawValue): \(file) missing/empty") }
        if tap.frames == 0 { f.append("\(pref.rawValue): no decoded frames") }
        if (result["serverReportedVideoSizes"] as? [String])?.contains("1920x1080") != true { f.append("\(pref.rawValue): ServerMetadata not captured") }
        let unhandled = (result["unhandledMessages"] as? [String] ?? []).joined(separator: "; ")
        if !unhandled.contains("SelfTestUnknownType") || !unhandled.contains("unhandledTarget") || !unhandled.contains("0x400") {
            f.append("\(pref.rawValue): unhandled message types not listed (\(unhandled))")
        }
        if bitrateKbps > 0, !read("offer.sdp").contains("b=AS:\(bitrateKbps)") { f.append("\(pref.rawValue): b=AS not in offer") }
        let sel = result["selectedVideoCodec"] as? String ?? "-"
        func j(_ k: String) -> String { (result[k] as? [String])?.joined(separator: ", ") ?? "-" }
        out("loopback \(pref.rawValue): selected \(sel); decoded \(tap.frames) frames; formats [\(j("pixelFormats"))]; colour [\(j("colorInfo"))]; "
            + "stats codecs [\(j("statsCodecs"))], decoder [\(j("decoderImplementations"))], sizes [\(j("decodedSizes"))], "
            + "bitstream \((result["bitstream"] as? [[String: Any]] ?? []).compactMap { $0["profile"] as? String }); "
            + "color-space ext \(result["colorSpaceExtensionNegotiated"] ?? "-") (\(dir.lastPathComponent))")
        return f
    }

    // MARK: 3. HEVC Main 10 / PQ through the app's H265 decoder
    @MainActor
    static func hevcMain10() async -> [String] {
        guard let rec = DiagnosticsRecorder(meta: ["target": "selftest: HEVC Main10 PQ decode", "settings": ["selftest": true]]) else { return ["recorder init"] }
        DiagnosticsRecorder.current = rec
        defer { DiagnosticsRecorder.current = nil }
        var f: [String] = []
        let (w, h) = (1920, 1080)
        var session: VTCompressionSession?
        let enc: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC,
                                         encoderSpecification: enc as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else {
            return ["HEVC encoder unavailable"]
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_2020)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        // HDR10 static metadata: BT.2020 primaries, D65, 1000 / 0.0001 nits; MaxCLL 1000, MaxFALL 400 (big-endian, per SEI 137/144 layout).
        let mdcv: [UInt16] = [8500, 39850, 6550, 2300, 35400, 14600, 15635, 16450]
        var mdcvData = Data(); for v in mdcv { withUnsafeBytes(of: v.bigEndian) { mdcvData.append(contentsOf: $0) } }
        for v in [UInt32(10_000_000), UInt32(1)] { withUnsafeBytes(of: v.bigEndian) { mdcvData.append(contentsOf: $0) } }
        var cll = Data(); for v in [UInt16(1000), UInt16(400)] { withUnsafeBytes(of: v.bigEndian) { cll.append(contentsOf: $0) } }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MasteringDisplayColorVolume, value: mdcvData as CFData)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ContentLightLevelInfo, value: cll as CFData)

        let factory = AppVideoDecoderFactory()
        guard let info = factory.supportedCodecs().first(where: { $0.name == "H265" && $0.parameters["profile-id"] == "2" }),
              let decoder = factory.createDecoder(info) else { return ["H265 decoder not created"] }
        var decoded: [CVPixelBuffer] = []
        let lock = NSLock()
        decoder.setCallback { frame in
            DiagnosticsRecorder.current?.recordFrame(frame)
            if let cv = frame.buffer as? RTCCVPixelBuffer { lock.lock(); decoded.append(cv.pixelBuffer); lock.unlock() }
        }
        _ = decoder.startDecode(withNumberOfCores: 1)
        for i in 0..<30 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            for plane in 0..<2 {
                if let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) {
                    let rows = CVPixelBufferGetHeightOfPlane(pb, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                    let p = base.assumingMemoryBound(to: UInt16.self)
                    for r in 0..<rows { for c in 0..<(stride / 2) { p[r * stride / 2 + c] = plane == 0 ? UInt16(((r + c + i * 8) % 876 + 64) << 6) : UInt16(512 << 6) } }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            var annexB: Data?
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
                                                     infoFlagsOut: nil) { status, _, sample in
                if status == noErr, let sample { annexB = annexBFromSample(sample) }
            }
            if st == noErr { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts) }
            guard let annexB else { f.append("HEVC encode frame \(i) failed"); break }
            let img = RTCEncodedImage()
            img.buffer = annexB
            img.frameType = i == 0 ? .videoFrameKey : .videoFrameDelta
            img.timeStamp = UInt32(i * 3000)
            img.encodedWidth = Int32(w); img.encodedHeight = Int32(h)
            let r = decoder.decode(img, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: Int64(i * 33))
            if r != 0 { f.append("HEVC decode returned \(r) on frame \(i)") ; break }
        }
        VTCompressionSessionInvalidate(session)
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = decoder.release()
        rec.finish(reason: "selftest")
        lock.lock(); let frames = decoded; lock.unlock()
        if frames.isEmpty { f.append("HEVC: no frames decoded") }
        if let pb = frames.first {
            let i = FrameInspector.inspect(pb)
            if i["pixelFormat"] as? String != "x420" { f.append("HEVC: decoded format \(i["pixelFormat"] ?? "?"), expected x420") }
            if i["hdrMetadata"] as? Bool != true { f.append("HEVC: HDR attachments not seen (\(i["transferFunction"] ?? "-"))") }
            out("hevc main10: \(frames.count) frames, \(i["pixelFormat"] ?? "?") \(i["bitDepth"] ?? "?")-bit, \(i["colorPrimaries"] ?? "-") / \(i["transferFunction"] ?? "-") / \(i["yCbCrMatrix"] ?? "-"), mdcv \(i["masteringDisplayColorVolume"] != nil), cll \(i["contentLightLevelInfo"] != nil) (\(rec.directory.lastPathComponent))")
        }
        let bs = (try? String(contentsOf: rec.directory.appendingPathComponent("bitstream.jsonl"), encoding: .utf8)) ?? ""
        out("hevc bitstream: " + bs.split(separator: "\n").prefix(4).joined(separator: " | "))
        if !bs.contains("Main 10") { f.append("HEVC: SPS parse didn't find Main 10") }
        if !bs.contains("PQ") { f.append("HEVC: SPS VUI transfer PQ not parsed") }
        return f
    }

    /// CMSampleBuffer (length-prefixed HEVC, parameter sets in the format description) → Annex B with VPS/SPS/PPS on keyframes.
    static func annexBFromSample(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var out = Data()
        let start = Data([0, 0, 0, 1])
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if isKey {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                                                                   parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr { out.append(start); out.append(ptr, count: size) }
            }
        }
        var length = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr) == noErr,
              let dataPtr else { return nil }
        let bytes = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
        var o = 0
        while o + 4 <= length {
            let n = Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3])
            o += 4
            guard o + n <= length else { break }
            out.append(start); out.append(bytes + o, count: n)
            o += n
        }
        return out
    }
}
