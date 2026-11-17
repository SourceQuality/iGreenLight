// Developer tool: compiled into debug builds only.
#if DEBUG
import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Headless SmartGlass probe: `iGreenLight --smartglass <console-ip> --smartglass-out <results.jsonl>`.
///
/// Speaks the LAN SmartGlass protocol (UDP 5050) directly to the console: discovery, authenticated connect (ECDH with the
/// console certificate, AES-128-CBC + HMAC-SHA256), LocalJoin, then asks the console to open each known service channel
/// and logs everything it sends back for a few seconds. It only listens; it never starts a legacy game stream.
/// The Xbox Live token is used in memory for the connect request and never written to disk.
enum SmartGlass {
    static var host: String? { arg("--smartglass") }
    static var outPath: String? { arg("--smartglass-out") }
    static var requested: Bool { host != nil }
    /// `--smartglass-broadcast`: also send a legacy StartGameStream request on the SystemBroadcast channel (followed by a
    /// StopGameStream) to see how the console answers.
    static var askBroadcast: Bool { CommandLine.arguments.contains("--smartglass-broadcast") }
    @MainActor static var started = false

    private static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static let services: [(String, String)] = [
        ("SystemInput", "fa20b8ca-66fb-46e0-adb6-0b978a59d35f"),
        ("SystemInputTVRemote", "d451e3b3-60bb-4c71-b3db-f994b1aca3a7"),
        ("SystemMedia", "48a9ca24-eb6d-4e12-8c43-d57469edd3cd"),
        ("SystemText", "7af3e6a2-488b-40cb-a931-79c04b7da3a0"),
        ("SystemBroadcast", "b6a117d8-f5e2-45d7-862e-8fd8e3156476"),
    ]

    static let messageTypes: [Int: String] = [
        0x1: "Ack", 0x2: "Group", 0x3: "LocalJoin", 0x5: "StopActivity", 0x19: "AuxilaryStream", 0x1a: "ActiveSurfaceChange",
        0x1b: "Navigate", 0x1c: "Json", 0x1d: "Tunnel", 0x1e: "ConsoleStatus", 0x1f: "TitleTextConfiguration",
        0x20: "TitleTextInput", 0x21: "TitleTextSelection", 0x22: "MirroringRequest", 0x23: "TitleLaunch",
        0x26: "StartChannelRequest", 0x27: "StartChannelResponse", 0x28: "StopChannel", 0x29: "System", 0x2a: "Disconnect",
        0x2e: "TitleTouch", 0x36: "PairedIdentityStateChanged", 0x37: "Unsnap", 0x38: "GameDvrRecord", 0x39: "PowerOff",
        0xf00: "MediaControllerRemoved", 0xf01: "MediaCommand", 0xf02: "MediaCommandResult", 0xf03: "MediaState",
        0xf0a: "Gamepad", 0xf2b: "SystemTextConfiguration", 0xf2c: "SystemTextInput", 0xf2e: "SystemTouch",
        0xf34: "SystemTextAck", 0xf35: "SystemTextDone",
    ]

    // MARK: - Run

    @MainActor
    static func run(auth: AuthManager) async {
        guard let host else { return }
        let out = outPath ?? NSTemporaryDirectory() + "smartglass.jsonl"
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = FileHandle(forWritingAtPath: out)
        let t0 = Date()
        let emit: @Sendable ([String: Any]) -> Void = { obj in
            var o = obj; o["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
            if let d = try? JSONSerialization.data(withJSONObject: DiagnosticsRecorder.jsonSafe(o) as Any, options: [.sortedKeys]) {
                handle?.write(d); handle?.write(Data("\n".utf8))
            }
        }
        auth.bootstrap()
        for _ in 0..<120 {
            if auth.state == .signedIn { break }
            if case .failed(let m) = auth.state { emit(["error": "auth failed: \(m)"]); return }
            if auth.state == .signedOut { emit(["error": "not signed in"]); return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let web = auth.webToken, !web.uhs.isEmpty else { emit(["error": "no xboxlive.com XSTS token"]); return }
        let uhs = web.uhs, jwt = web.Token
        emit(["step": "auth", "tokenChars": jwt.count])
        await Task.detached { session(host: host, uhs: uhs, jwt: jwt, emit: emit) }.value
    }

    // MARK: - Session

    private static func session(host: String, uhs: String, jwt: String, emit: ([String: Any]) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { emit(["error": "socket failed"]); return }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(5050).bigEndian; inet_pton(AF_INET, host, &addr.sin_addr)
        func send(_ d: Data) {
            _ = d.withUnsafeBytes { p in withUnsafePointer(to: &addr) { a in
                a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p.baseAddress, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        }
        func recv() -> Data? {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            return n > 0 ? Data(buf[0..<n]) : nil
        }

        // 1. Discovery
        var w = Writer(); w.u16(0xDD00); w.u16(10); w.u16(0); w.u16(0); w.u32(8); w.u16(0); w.u16(2)
        send(w.data)
        guard let disc = recv(), disc.count > 12, disc.u16(0) == 0xDD01 else { emit(["error": "no discovery response"]); return }
        var r = Reader(disc, 6)
        let flags = r.u32(), deviceType = r.u16(), name = r.sgString(), uuid = r.sgString(), lastError = r.u32()
        let certLen = Int(r.u16()); let cert = r.bytes(certLen)
        guard let secCert = SecCertificateCreateWithData(nil, cert as CFData), let key = SecCertificateCopyKey(secCert),
              let pub = SecKeyCopyExternalRepresentation(key, nil) as Data? else { emit(["error": "cannot read console certificate key"]); return }
        let subject = SecCertificateCopySubjectSummary(secCert) as String? ?? "-"
        emit(["step": "discovery", "flags": String(flags, radix: 16), "deviceType": deviceType, "name": name, "consoleId": uuid,
              "lastError": lastError, "certSubject": subject, "certBytes": certLen, "publicKeyBytes": pub.count])

        // 2. Key agreement (curve chosen by the console certificate).
        let secret: Data, myPub: Data, keyType: UInt16
        do {
            switch pub.count {
            case 65: let k = P256.KeyAgreement.PrivateKey()
                secret = try k.sharedSecretFromKeyAgreement(with: .init(x963Representation: pub)).withUnsafeBytes { Data($0) }
                myPub = k.publicKey.x963Representation.dropFirst(); keyType = 0
            case 97: let k = P384.KeyAgreement.PrivateKey()
                secret = try k.sharedSecretFromKeyAgreement(with: .init(x963Representation: pub)).withUnsafeBytes { Data($0) }
                myPub = k.publicKey.x963Representation.dropFirst(); keyType = 1
            case 133: let k = P521.KeyAgreement.PrivateKey()
                secret = try k.sharedSecretFromKeyAgreement(with: .init(x963Representation: pub)).withUnsafeBytes { Data($0) }
                myPub = k.publicKey.x963Representation.dropFirst(); keyType = 2
            default: emit(["error": "unexpected public key size \(pub.count)"]); return
            }
        } catch { emit(["error": "ECDH failed: \(error)"]); return }
        let derived = Data(SHA512.hash(data: Data(hex: "d637f1aae2f0418c") + secret + Data(hex: "a8f81a574e228ab7")))
        let crypto = Crypto(encKey: derived.subdata(in: 0..<16), ivKey: derived.subdata(in: 16..<32), hashKey: derived.subdata(in: 32..<64))

        // 3. Connect request (fragmented when the token is long).
        let clientUUID = UUID()
        func connectPacket(hash: String, token: String, num: UInt32, start: UInt32, end: UInt32) -> Data {
            var iv = Data(count: 16); _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            var prot = Writer(); prot.sgString(hash); prot.sgString(token); prot.u32(num); prot.u32(start); prot.u32(end)
            var unprot = Writer(); unprot.raw(clientUUID.bytes); unprot.u16(keyType); unprot.raw(Data(myPub)); unprot.raw(iv)
            var head = Writer(); head.u16(0xCC00); head.u16(UInt16(unprot.data.count)); head.u16(UInt16(prot.data.count)); head.u16(2)
            let body = head.data + unprot.data + crypto.encrypt(prot.data, iv: iv)
            return body + crypto.hmac(body)
        }
        var packets: [Data] = []
        let maxChunk = 900
        if uhs.count + jwt.count <= maxChunk {
            packets = [connectPacket(hash: uhs, token: jwt, num: 0, start: 0, end: 1)]
        } else {
            var chunks: [String] = []; var rest = Substring(jwt); var first = true
            while !rest.isEmpty {
                let n = first ? maxChunk - uhs.count : maxChunk; first = false
                chunks.append(String(rest.prefix(n))); rest = rest.dropFirst(n)
            }
            for (i, c) in chunks.enumerated() {
                packets.append(connectPacket(hash: i == 0 ? uhs : "", token: c, num: UInt32(i), start: 0, end: UInt32(chunks.count)))
            }
        }
        emit(["step": "connect.send", "fragments": packets.count, "curve": ["P-256", "P-384", "P-521"][Int(keyType)]])
        for p in packets { send(p); usleep(20_000) }

        var participant: UInt32 = 0
        var connected = false
        for _ in 0..<6 {
            guard let d = recv() else { continue }
            guard d.u16(0) == 0xCC01, d.count >= 8 + 16 + 32 else { emit(["step": "connect.unexpected", "hex": d.prefix(64).hexString]); continue }
            let unprotLen = Int(d.u16(2)), protLen = Int(d.u16(4))
            let iv = d.subdata(in: 8..<8 + 16)
            let enc = d.subdata(in: 8 + unprotLen..<d.count - 32)
            let plain = crypto.decrypt(enc, iv: iv).prefix(protLen)
            var pr = Reader(Data(plain), 0)
            let result = pr.u16(), pairing = pr.u16(); participant = pr.u32()
            emit(["step": "connect.response", "result": result, "resultName": ["success", "unknown error", "anonymous connections disabled", "device limit exceeded", "SmartGlass disabled", "user auth failed", "sign-in failed", "sign-in timed out", "sign-in required"][safe: Int(result)] ?? "?",
                  "pairingState": pairing, "participantId": participant, "hmacValid": crypto.hmac(d.dropLast(32)) == d.suffix(32)])
            connected = result == 0
            break
        }
        guard connected else { emit(["step": "end", "reason": "not connected"]); return }

        // 4. Messages
        var seq: UInt32 = 0
        func message(_ type: Int, channel: UInt64, needAck: Bool, payload: Data) {
            seq += 1
            var h = Writer(); h.u16(0xD00D); h.u16(UInt16(payload.count)); h.u32(seq); h.u32(0); h.u32(participant)
            h.u16(UInt16(2 << 14 | (needAck ? 1 << 13 : 0) | type)); h.u64(channel)
            let iv = crypto.iv(seed: h.data.prefix(16))
            let body = h.data + crypto.encrypt(payload, iv: iv)
            send(body + crypto.hmac(body))
        }
        var lj = Writer(); lj.u16(3); lj.u16(1920); lj.u16(1080); lj.u16(96); lj.u16(96); lj.u64(UInt64.max); lj.u32(15); lj.u32(6); lj.u32(2)
        lj.sgString("iGreenLight-probe")
        message(0x3, channel: 0, needAck: true, payload: lj.data)
        emit(["step": "localJoin.send"])

        var channelNames: [UInt64: String] = [0: "core"]
        var requested = false
        var broadcastAsked = false, broadcastStopped = false, broadcastChannel: UInt64 = 0, broadcastAt: Date?
        let deadline = Date().addingTimeInterval(14)
        let start = Date()
        while Date() < deadline {
            if !requested, Date().timeIntervalSince(start) > 1.5 {
                requested = true
                for (i, s) in services.enumerated() {
                    var p = Writer(); p.u32(UInt32(i + 1)); p.u32(0); p.raw(UUID(uuidString: s.1)!.bytes); p.u32(0)
                    message(0x26, channel: 0, needAck: true, payload: p.data)
                }
                emit(["step": "startChannel.send", "services": services.map { $0.0 }])
            }
            if askBroadcast, !broadcastAsked, let ch = channelNames.first(where: { $0.value == "SystemBroadcast" })?.key {
                broadcastAsked = true; broadcastChannel = ch; broadcastAt = Date()
                let config: [String: String] = [
                    "audioFecType": "0", "audioSyncPolicy": "1", "audioSyncMaxLatency": "170", "audioSyncDesiredLatency": "40",
                    "audioSyncMinLatency": "10", "audioSyncCompressLatency": "100", "audioSyncCompressFactor": "0.99",
                    "audioSyncLengthenFactor": "1.01", "audioBufferLengthHns": "10000000",
                    "enableOpusChatAudio": "true", "enableDynamicBitrate": "false", "enableAudioChat": "true",
                    "enableVideoFrameAcks": "false", "enableOpusAudio": "false",
                    "dynamicBitrateUpdateMs": "5000", "dynamicBitrateScaleFactor": "1",
                    "inputReadsPerSecond": "120", "videoFecType": "0", "videoFecLevel": "3",
                    "videoMaximumWidth": "3840", "videoMaximumHeight": "2160", "videoMaximumFrameRate": "60",
                    "videoPacketUtilization": "0", "videoPacketDefragTimeoutMs": "16", "sendKeyframesOverTCP": "false",
                    "udpSubBurstGroups": "5", "udpBurstDurationMs": "11", "udpMaxSendPacketsInWinsock": "250",
                    "urcpType": "0", "urcpFixedRate": "-1", "urcpMaximumRate": "10000000", "urcpMinimumRate": "256000",
                    "urcpMaximumWindow": "1310720", "urcpKeepAliveTimeoutMs": "0",
                ]
                let obj: [String: Any] = ["type": 1, "reQueryPreviewStatus": true, "configuration": config]
                let text = String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
                var p = Writer(); p.sgString(text)
                message(0x1c, channel: ch, needAck: true, payload: p.data)
                emit(["step": "broadcast.start.send", "bytes": text.count, "seq": seq])
            }
            if let at = broadcastAt, !broadcastStopped, Date().timeIntervalSince(at) > 6 {
                broadcastStopped = true
                var p = Writer(); p.sgString("{\"type\":2}")
                message(0x1c, channel: broadcastChannel, needAck: true, payload: p.data)
                emit(["step": "broadcast.stop.send", "seq": seq])
            }
            guard let d = recv(), d.count >= 26 + 32, d.u16(0) == 0xD00D else { continue }
            let protLen = Int(d.u16(2)), rseq = d.u32(4), fl = Int(d.u16(16)), channel = d.u64(18)
            let type = fl & 0x0fff, needAck = fl & 0x2000 != 0, fragment = fl & 0x1000 != 0
            let iv = crypto.iv(seed: d.prefix(16))
            let plain = Data(crypto.decrypt(d.subdata(in: 26..<d.count - 32), iv: iv).prefix(protLen))
            var info: [String: Any] = ["step": "recv", "type": messageTypes[type] ?? String(format: "0x%x", type), "seq": rseq,
                                       "channel": channelNames[channel] ?? "\(channel)", "bytes": plain.count, "fragment": fragment]
            var pr = Reader(plain, 0)
            switch type {
            case 0x1e:
                info["liveTvProvider"] = pr.u32(); info["osMajor"] = pr.u32(); info["osMinor"] = pr.u32(); info["osBuild"] = pr.u32()
                info["locale"] = pr.sgString()
                var titles: [[String: Any]] = []
                for _ in 0..<Int(pr.u16()) {
                    let id = pr.u32(), disp = pr.u16(); _ = pr.bytes(32); let aum = pr.sgString()
                    titles.append(["titleId": String(id, radix: 16), "hasFocus": disp & 0x8000 != 0, "location": disp & 0x7fff, "aum": aum])
                }
                info["activeTitles"] = titles
            case 0x27:
                let req = Int(pr.u32()), ch = pr.u64(), result = pr.u32()
                let svc = services[safe: req - 1]?.0 ?? "?"
                if result == 0 { channelNames[ch] = svc }
                info["service"] = svc; info["channelId"] = ch; info["result"] = result
            case 0x1c:
                info["json"] = pr.sgString()
            case 0x1:
                info["lowWatermark"] = pr.u32()
                info["processed"] = (0..<min(64, Int(pr.u32()))).map { _ in pr.u32() }
                info["rejected"] = (0..<min(64, Int(pr.u32()))).map { _ in pr.u32() }
            default:
                info["hex"] = plain.prefix(160).hexString
                let text = String(decoding: plain.filter { $0 >= 32 && $0 < 127 }, as: UTF8.self)
                if text.count > 6 { info["ascii"] = String(text.prefix(300)) }
            }
            emit(info)
            if needAck {
                var a = Writer(); a.u32(rseq); a.u32(1); a.u32(rseq); a.u32(0)
                message(0x1, channel: 0x1000000000000000, needAck: false, payload: a.data)
            }
        }
        // 5. Disconnect politely.
        var dc = Writer(); dc.u32(0); dc.u32(0); dc.u32(participant)   // reason, error code, participant id
        message(0x2a, channel: 0, needAck: false, payload: dc.data)
        emit(["step": "end", "reason": "done", "channels": channelNames.values.sorted()])
    }

    // MARK: - Helpers

    struct Crypto {
        let encKey: Data, ivKey: Data, hashKey: Data
        func hmac(_ d: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: d, using: SymmetricKey(data: hashKey))) }
        func iv(seed: Data) -> Data { aes(seed, key: ivKey, iv: nil, op: CCOperation(kCCEncrypt), ecb: true) }
        func encrypt(_ d: Data, iv: Data) -> Data {
            var p = d; let rem = d.count % 16
            if rem != 0 { let n = 16 - rem; p.append(contentsOf: [UInt8](repeating: UInt8(n), count: n)) }
            return aes(p, key: encKey, iv: iv, op: CCOperation(kCCEncrypt), ecb: false)
        }
        func decrypt(_ d: Data, iv: Data) -> Data {
            d.count % 16 == 0 && !d.isEmpty ? aes(d, key: encKey, iv: iv, op: CCOperation(kCCDecrypt), ecb: false) : Data()
        }
        private func aes(_ d: Data, key: Data, iv: Data?, op: CCOperation, ecb: Bool) -> Data {
            var out = [UInt8](repeating: 0, count: d.count + 16); var n = 0
            let ivBytes = [UInt8](iv ?? Data(count: 16))
            _ = d.withUnsafeBytes { dp in key.withUnsafeBytes { kp in
                CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(ecb ? kCCOptionECBMode : 0), kp.baseAddress, key.count, ivBytes,
                        dp.baseAddress, d.count, &out, out.count, &n) } }
            return Data(out[0..<n])
        }
    }

    struct Writer {
        var data = Data()
        mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
        mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
        mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
        mutating func raw(_ d: Data) { data.append(d) }
        mutating func sgString(_ s: String) { let b = Data(s.utf8); u16(UInt16(b.count)); data.append(b); data.append(0) }
    }

    struct Reader {
        let d: Data; var o: Int
        init(_ d: Data, _ o: Int) { self.d = Data(d); self.o = o }
        mutating func bytes(_ n: Int) -> Data { let e = min(d.count, o + max(0, n)); let r = o < e ? d.subdata(in: o..<e) : Data(); o = e; return r }
        mutating func u16() -> UInt16 { let b = bytes(2); return b.count == 2 ? UInt16(b[0]) << 8 | UInt16(b[1]) : 0 }
        mutating func u32() -> UInt32 { UInt32(u16()) << 16 | UInt32(u16()) }
        mutating func u64() -> UInt64 { UInt64(u32()) << 32 | UInt64(u32()) }
        mutating func sgString() -> String { let n = Int(u16()); let s = String(decoding: bytes(n), as: UTF8.self); _ = bytes(1); return s }
    }
}

private extension Data {
    init(hex: String) {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); d.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        self = d
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) << 8 | UInt16(self[startIndex + o + 1]) }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) << 16 | UInt32(u16(o + 2)) }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) << 32 | UInt64(u32(o + 4)) }
}

private extension UUID {
    var bytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
