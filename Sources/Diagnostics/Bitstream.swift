import Foundation

/// Parses parameter sets / headers straight from the encoded stream, independent of the decoder:
/// H.264 SPS (profile, level, bit depth, chroma, VUI colour description), HEVC VPS/SPS (same plus tier),
/// SEI payload types (137 mastering display, 144 content light level, 147 alternative transfer, 4/5 user data),
/// and the VP9 keyframe colour config.
enum Bitstream {
    // MARK: Annex B
    /// Splits an Annex B buffer (00 00 01 / 00 00 00 01 start codes) into NAL units (without start codes).
    static func nalUnits(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(Int, Int)] = []   // (start code offset, payload offset)
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 3 < b.count, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        var out: [Data] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].0 : b.count
            if end > s.1 { out.append(Data(b[s.1..<end])) }
        }
        return out
    }

    /// Removes emulation-prevention bytes (00 00 03 → 00 00).
    static func rbsp(_ d: Data, from: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(d.count)
        var zeros = 0
        for (i, byte) in d.enumerated() where i >= from {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    struct BitReader {
        let b: [UInt8]
        var pos = 0
        init(_ b: [UInt8]) { self.b = b }
        var bitsLeft: Int { b.count * 8 - pos }
        mutating func u(_ n: Int) throws -> UInt64 {
            guard n <= bitsLeft else { throw ParseError.eof }
            var v: UInt64 = 0
            for _ in 0..<n {
                let bit = (b[pos >> 3] >> (7 - UInt8(pos & 7))) & 1
                v = v << 1 | UInt64(bit); pos += 1
            }
            return v
        }
        mutating func flag() throws -> Bool { try u(1) == 1 }
        mutating func ue() throws -> UInt64 {
            var zeros = 0
            while try u(1) == 0 { zeros += 1; if zeros > 31 { throw ParseError.bad } }
            return zeros == 0 ? 0 : (1 << UInt64(zeros)) - 1 + (try u(zeros))
        }
        mutating func se() throws -> Int64 {
            let k = try ue()
            return k & 1 == 1 ? Int64((k + 1) / 2) : -Int64(k / 2)
        }
        mutating func skip(_ n: Int) throws { guard n <= bitsLeft else { throw ParseError.eof }; pos += n }
    }
    enum ParseError: Error { case eof, bad }

    // MARK: Colour names (ITU-T H.273)
    static func primariesName(_ v: Int) -> String {
        [1: "BT.709", 2: "unspecified", 4: "BT.470M", 5: "BT.470BG", 6: "SMPTE170M", 7: "SMPTE240M", 8: "film", 9: "BT.2020",
         10: "SMPTE428", 11: "DCI-P3", 12: "Display-P3", 22: "EBU3213"][v] ?? "\(v)"
    }
    static func transferName(_ v: Int) -> String {
        [1: "BT.709", 2: "unspecified", 4: "gamma2.2", 5: "gamma2.8", 6: "SMPTE170M", 7: "SMPTE240M", 8: "linear", 11: "IEC61966-2-4",
         12: "BT.1361", 13: "sRGB", 14: "BT.2020-10", 15: "BT.2020-12", 16: "PQ (SMPTE2084, HDR10)", 17: "SMPTE428",
         18: "HLG (ARIB STD-B67)"][v] ?? "\(v)"
    }
    static func matrixName(_ v: Int) -> String {
        [0: "identity/RGB", 1: "BT.709", 2: "unspecified", 4: "FCC", 5: "BT.470BG", 6: "SMPTE170M (BT.601)", 7: "SMPTE240M", 8: "YCgCo",
         9: "BT.2020 NCL", 10: "BT.2020 CL", 14: "ICtCp"][v] ?? "\(v)"
    }

    // MARK: Entry point
    /// Inspects an encoded frame. Returns one info dict per interesting unit (SPS/VPS, SEI types, VP9 header).
    static func inspect(codec: String, data: Data) -> [[String: Any]] {
        switch codec.uppercased() {
        case "H264": return nalUnits(data).compactMap(h264NAL)
        case "H265": return nalUnits(data).compactMap(h265NAL)
        case "VP9": return vp9(data).map { [$0] } ?? []
        default: return []
        }
    }

    // MARK: H.264
    static func h264NAL(_ nal: Data) -> [String: Any]? {
        guard let first = nal.first else { return nil }
        let type = Int(first & 0x1f)
        if type == 7 {
            var info: [String: Any] = ["codec": "H264", "nal": "SPS", "raw": nal.prefix(48).map { String(format: "%02x", $0) }.joined()]
            do { try h264SPS(rbsp(nal, from: 1), into: &info) } catch { info["parseError"] = "\(error)" }
            return info
        }
        if type == 6 { return sei(rbsp(nal, from: 1), codec: "H264") }
        return nil
    }

    static func h264SPS(_ b: [UInt8], into info: inout [String: Any]) throws {
        var r = BitReader(b)
        let profile = Int(try r.u(8)), constraints = Int(try r.u(8)), level = Int(try r.u(8))
        _ = try r.ue()
        let profileNames = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4 Predictive"]
        var pname = profileNames[profile] ?? "profile \(profile)"
        if profile == 66, constraints & 0x40 != 0 { pname = "Constrained Baseline" }
        if profile == 100, constraints & 0x0c == 0x0c { pname = "Constrained High" }
        info["profileIdc"] = profile
        info["profile"] = "H.264 \(pname)"
        info["level"] = Double(level) / 10
        info["profileLevelId"] = String(format: "%02x%02x%02x", profile, constraints, level)
        var chroma = 1, depthL = 8, depthC = 8
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chroma = Int(try r.ue())
            if chroma == 3 { _ = try r.flag() }
            depthL = Int(try r.ue()) + 8; depthC = Int(try r.ue()) + 8
            _ = try r.flag()
            if try r.flag() {
                for i in 0..<(chroma != 3 ? 8 : 12) where try r.flag() {
                    let size = i < 6 ? 16 : 64
                    var last: Int64 = 8, next: Int64 = 8
                    for _ in 0..<size where next != 0 {
                        let delta = try r.se()
                        next = (last + delta + 256) % 256
                        if next != 0 { last = next }
                    }
                }
            }
        }
        info["chromaFormat"] = ["4:0:0", "4:2:0", "4:2:2", "4:4:4"][min(chroma, 3)]
        info["bitDepthLuma"] = depthL
        info["bitDepthChroma"] = depthC
        _ = try r.ue()
        let pocType = try r.ue()
        if pocType == 0 { _ = try r.ue() } else if pocType == 1 {
            _ = try r.flag(); _ = try r.se(); _ = try r.se()
            let n = try r.ue()
            for _ in 0..<min(n, 255) { _ = try r.se() }
        }
        info["maxRefFrames"] = Int(try r.ue())
        _ = try r.flag()
        let wMbs = Int(try r.ue()) + 1, hMap = Int(try r.ue()) + 1
        let frameMbsOnly = try r.flag()
        if !frameMbsOnly { _ = try r.flag() }
        _ = try r.flag()
        var crop = (0, 0, 0, 0)
        if try r.flag() { crop = (Int(try r.ue()), Int(try r.ue()), Int(try r.ue()), Int(try r.ue())) }
        let cropUnitX = chroma == 0 || chroma == 3 ? 1 : 2
        let cropUnitY = (chroma == 1 ? 2 : 1) * (frameMbsOnly ? 1 : 2)
        info["width"] = wMbs * 16 - cropUnitX * (crop.0 + crop.1)
        info["height"] = hMap * 16 * (frameMbsOnly ? 1 : 2) - cropUnitY * (crop.2 + crop.3)
        guard try r.flag() else { info["vui"] = false; return }
        try vuiColour(&r, into: &info)
        // timing_info
        if try r.flag() {
            let units = Double(try r.u(32)), scale = Double(try r.u(32))
            if units > 0 { info["vuiMaxFps"] = (scale / (2 * units) * 100).rounded() / 100 }
        }
    }

    /// aspect_ratio_info, overscan, video_signal_type (shared by H.264 and HEVC VUI up to the colour description).
    static func vuiColour(_ r: inout BitReader, into info: inout [String: Any]) throws {
        if try r.flag() { if try r.u(8) == 255 { try r.skip(32) } }
        if try r.flag() { _ = try r.flag() }
        if try r.flag() {
            info["videoFormat"] = Int(try r.u(3))
            info["fullRange"] = try r.flag()
            if try r.flag() {
                let p = Int(try r.u(8)), t = Int(try r.u(8)), m = Int(try r.u(8))
                info["colourPrimaries"] = p; info["transferCharacteristics"] = t; info["matrixCoefficients"] = m
                info["colour"] = "\(primariesName(p)) / \(transferName(t)) / \(matrixName(m))"
            } else { info["colour"] = "no colour description (decoder assumes BT.709/601)" }
        } else { info["colour"] = "no video_signal_type in VUI" }
        if try r.flag() { _ = try r.ue(); _ = try r.ue() }   // chroma_loc_info
    }

    static func sei(_ b: [UInt8], codec: String) -> [String: Any]? {
        var i = 0
        var types: [Int] = []
        var details: [String: Any] = [:]
        while i < b.count, b[i] != 0x80 {
            var type = 0, size = 0
            while i < b.count, b[i] == 0xff { type += 255; i += 1 }
            guard i < b.count else { break }
            type += Int(b[i]); i += 1
            while i < b.count, b[i] == 0xff { size += 255; i += 1 }
            guard i < b.count else { break }
            size += Int(b[i]); i += 1
            guard i + size <= b.count else { break }
            types.append(type)
            let p = Array(b[i..<i + size])
            func u16(_ o: Int) -> Int { o + 1 < p.count ? Int(p[o]) << 8 | Int(p[o + 1]) : 0 }
            func u32(_ o: Int) -> Int { o + 3 < p.count ? u16(o) << 16 | u16(o + 2) : 0 }
            switch type {
            case 137 where size >= 24:
                details["masteringDisplay"] = ["primariesGBR": (0..<3).map { [u16($0 * 4), u16($0 * 4 + 2)] },
                                               "whitePoint": [u16(12), u16(14)],
                                               "maxLuminanceNits": Double(u32(16)) / 10000, "minLuminanceNits": Double(u32(20)) / 10000]
            case 144 where size >= 4:
                details["contentLightLevel"] = ["maxCLL": u16(0), "maxFALL": u16(2)]
            case 147 where size >= 1:
                details["alternativeTransfer"] = transferName(Int(p[0]))
            case 4 where size >= 3:
                details["userDataRegisteredT35"] = p.prefix(8).map { String(format: "%02x", $0) }.joined()   // b5 003c = HDR10+, b5 003b = Dolby
            default: break
            }
            i += size
        }
        guard !types.isEmpty else { return nil }
        var info: [String: Any] = ["codec": codec, "nal": "SEI", "seiTypes": types, "raw": types.map(String.init).joined(separator: ",")]
        for (k, v) in details { info[k] = v }
        if details["masteringDisplay"] != nil || details["contentLightLevel"] != nil { info["hdrSEI"] = true }
        return info
    }

    // MARK: HEVC
    static func h265NAL(_ nal: Data) -> [String: Any]? {
        guard nal.count > 2 else { return nil }
        let type = Int(nal[nal.startIndex] >> 1) & 0x3f
        switch type {
        case 32:
            return ["codec": "H265", "nal": "VPS", "raw": nal.prefix(32).map { String(format: "%02x", $0) }.joined()]
        case 33:
            var info: [String: Any] = ["codec": "H265", "nal": "SPS", "raw": nal.prefix(48).map { String(format: "%02x", $0) }.joined()]
            do { try h265SPS(rbsp(nal, from: 2), into: &info) } catch { info["parseError"] = "\(error)" }
            return info
        case 39, 40:
            return sei(rbsp(nal, from: 2), codec: "H265")
        default:
            return nil
        }
    }

    static func h265SPS(_ b: [UInt8], into info: inout [String: Any]) throws {
        var r = BitReader(b)
        try r.skip(4)
        let maxSub = Int(try r.u(3))
        try r.skip(1)
        // profile_tier_level(1, maxSub)
        try r.skip(2)
        let tier = try r.flag()
        let profile = Int(try r.u(5))
        try r.skip(32 + 4 + 43 + 1)
        let level = Int(try r.u(8))
        var subProfile: [Bool] = [], subLevel: [Bool] = []
        for _ in 0..<maxSub { subProfile.append(try r.flag()); subLevel.append(try r.flag()) }
        if maxSub > 0 { for _ in maxSub..<8 { try r.skip(2) } }
        for i in 0..<maxSub {
            if subProfile[i] { try r.skip(88) }
            if subLevel[i] { try r.skip(8) }
        }
        let names = [1: "Main", 2: "Main 10", 3: "Main Still Picture", 4: "Range Extensions", 9: "SCC"]
        info["profileIdc"] = profile
        info["profile"] = "HEVC \(names[profile] ?? "profile \(profile)")"
        info["tier"] = tier ? "High" : "Main"
        info["level"] = Double(level) / 30
        _ = try r.ue()
        let chroma = Int(try r.ue())
        if chroma == 3 { _ = try r.flag() }
        let w = Int(try r.ue()), h = Int(try r.ue())
        var crop = (0, 0, 0, 0)
        if try r.flag() { crop = (Int(try r.ue()), Int(try r.ue()), Int(try r.ue()), Int(try r.ue())) }
        let sx = chroma == 1 || chroma == 2 ? 2 : 1, sy = chroma == 1 ? 2 : 1
        info["width"] = w - sx * (crop.0 + crop.1)
        info["height"] = h - sy * (crop.2 + crop.3)
        info["chromaFormat"] = ["4:0:0", "4:2:0", "4:2:2", "4:4:4"][min(chroma, 3)]
        info["bitDepthLuma"] = Int(try r.ue()) + 8
        info["bitDepthChroma"] = Int(try r.ue()) + 8
        let log2PocLsb = Int(try r.ue()) + 4
        let ordering = try r.flag()
        for _ in (ordering ? 0 : maxSub)...maxSub { _ = try r.ue(); _ = try r.ue(); _ = try r.ue() }
        for _ in 0..<6 { _ = try r.ue() }   // log2_min_luma_cb … max_transform_hierarchy_depth_intra
        if try r.flag(), try r.flag() {      // scaling_list_enabled, sps_scaling_list_data_present
            for sizeId in 0..<4 {
                var matrixId = 0
                while matrixId < 6 {
                    if !(try r.flag()) { _ = try r.ue() } else {
                        let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                        if sizeId > 1 { _ = try r.se() }
                        for _ in 0..<coefNum { _ = try r.se() }
                    }
                    matrixId += sizeId == 3 ? 3 : 1
                }
            }
        }
        _ = try r.flag(); _ = try r.flag()   // amp, sao
        if try r.flag() { try r.skip(8); _ = try r.ue(); _ = try r.ue(); _ = try r.flag() }   // pcm
        let numSets = Int(try r.ue())
        guard numSets <= 64 else { throw ParseError.bad }
        var numDeltaPocs: [Int] = []
        for idx in 0..<numSets {
            var inter = false
            if idx != 0 { inter = try r.flag() }
            if inter {
                let refIdx = idx - 1   // delta_idx_minus1 is only coded in slice headers (idx == numSets)
                _ = try r.flag(); _ = try r.ue()
                var count = 0
                for _ in 0...numDeltaPocs[refIdx] {
                    let used = try r.flag()
                    var useDelta = true
                    if !used { useDelta = try r.flag() }
                    if used || useDelta { count += 1 }
                }
                numDeltaPocs.append(count)
            } else {
                let neg = Int(try r.ue()), pos = Int(try r.ue())
                guard neg + pos <= 32 else { throw ParseError.bad }
                for _ in 0..<(neg + pos) { _ = try r.ue(); _ = try r.flag() }
                numDeltaPocs.append(neg + pos)
            }
        }
        if try r.flag() {   // long_term_ref_pics_present
            let n = Int(try r.ue())
            for _ in 0..<min(n, 32) { try r.skip(log2PocLsb + 1) }
        }
        _ = try r.flag(); _ = try r.flag()   // temporal_mvp, strong_intra_smoothing
        guard try r.flag() else { info["vui"] = false; return }
        try vuiColour(&r, into: &info)
    }

    // MARK: VP9
    static func vp9(_ data: Data) -> [String: Any]? {
        var r = BitReader([UInt8](data.prefix(64)))
        do {
            guard try r.u(2) == 2 else { return nil }
            let low = Int(try r.u(1)), high = Int(try r.u(1))
            let profile = high << 1 | low
            if profile == 3 { try r.skip(1) }
            if try r.flag() { return nil }          // show_existing_frame
            guard try r.u(1) == 0 else { return nil }  // keyframes only
            try r.skip(2)
            guard try r.u(24) == 0x498342 else { return nil }
            var depth = 8
            if profile >= 2 { depth = try r.flag() ? 12 : 10 }
            let cs = Int(try r.u(3))
            let names = ["unknown", "BT.601", "BT.709", "SMPTE170", "SMPTE240", "BT.2020", "reserved", "sRGB"]
            var info: [String: Any] = ["codec": "VP9", "nal": "keyframe", "profile": "VP9 profile \(profile)", "bitDepthLuma": depth,
                                       "colour": names[cs], "raw": "p\(profile)-\(depth)-\(cs)"]
            if cs != 7 { info["fullRange"] = try r.flag() }
            return info
        } catch { return nil }
    }
}
