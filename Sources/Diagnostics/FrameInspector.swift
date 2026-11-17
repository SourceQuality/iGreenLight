import Foundation
import CoreVideo
import WebRTC

/// Describes a decoded frame: buffer class, CVPixelBuffer format and bit depth, colour attachments and HDR metadata.
enum FrameInspector {
    static func fourCC(_ t: OSType) -> String {
        let chars = [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)]
        if chars.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(bytes: chars, encoding: .ascii) ?? "\(t)" }
        return "0x" + String(t, radix: 16)
    }

    static func bitDepth(_ fmt: OSType) -> Int? {
        if let desc = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, fmt) as? [String: Any] {
            if let b = desc[kCVPixelFormatBitsPerComponent as String] as? Int { return b }
            if let planes = desc[kCVPixelFormatPlanes as String] as? [[String: Any]],
               let b = planes.first?[kCVPixelFormatBitsPerComponent as String] as? Int { return b }
        }
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA: return 8
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return 10
        default: return nil
        }
    }

    static func isFullRange(_ fmt: OSType) -> Bool {
        [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(fmt)
    }

    static func inspect(_ frame: RTCVideoFrame) -> [String: Any] {
        var info: [String: Any] = ["bufferClass": NSStringFromClass(type(of: frame.buffer as AnyObject)),
                                   "width": Int(frame.width), "height": Int(frame.height), "rotation": frame.rotation.rawValue]
        if let cv = frame.buffer as? RTCCVPixelBuffer {
            info.merge(inspect(cv.pixelBuffer)) { a, _ in a }
        } else {
            // libwebrtc software decoders (VP8/VP9/AV1) hand over I420 (8-bit) planar buffers.
            info["pixelFormat"] = "I420 (planar, libwebrtc)"
            info["bitDepth"] = 8
            info["note"] = "no CVPixelBuffer: colour attachments unavailable (libwebrtc carries colour space in the frame, not exposed to ObjC)"
        }
        info["key"] = "\(info["bufferClass"] ?? "")|\(info["pixelFormat"] ?? "")|\(info["width"] ?? 0)x\(info["height"] ?? 0)|\(info["colorPrimaries"] ?? "")|\(info["transferFunction"] ?? "")|\(info["yCbCrMatrix"] ?? "")|\(info["hdrMetadata"] ?? false)"
        return info
    }

    static func inspect(_ pb: CVPixelBuffer) -> [String: Any] {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        var info: [String: Any] = ["pixelFormat": fourCC(fmt), "pixelBufferWidth": CVPixelBufferGetWidth(pb),
                                   "pixelBufferHeight": CVPixelBufferGetHeight(pb), "planes": CVPixelBufferGetPlaneCount(pb),
                                   "range": isFullRange(fmt) ? "full" : "video"]
        if let d = bitDepth(fmt) { info["bitDepth"] = d }
        var all: [String: Any] = [:]
        if let a = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] { all.merge(a) { x, _ in x } }
        if let a = CVBufferCopyAttachments(pb, .shouldNotPropagate) as? [String: Any] { all.merge(a) { x, _ in x } }
        func str(_ k: CFString) -> String? { all[k as String].map { "\($0)" } }
        info["colorPrimaries"] = str(kCVImageBufferColorPrimariesKey) ?? "-"
        info["transferFunction"] = str(kCVImageBufferTransferFunctionKey) ?? "-"
        info["yCbCrMatrix"] = str(kCVImageBufferYCbCrMatrixKey) ?? "-"
        if let c = str(kCVImageBufferChromaLocationTopFieldKey) { info["chromaLocation"] = c }
        if let g = all[kCVImageBufferGammaLevelKey as String] { info["gamma"] = g }
        var hdr = false
        if let m = all[kCVImageBufferMasteringDisplayColorVolumeKey as String] as? Data {
            info["masteringDisplayColorVolume"] = m.map { String(format: "%02x", $0) }.joined(); hdr = true
        }
        if let c = all[kCVImageBufferContentLightLevelInfoKey as String] as? Data {
            info["contentLightLevelInfo"] = c.map { String(format: "%02x", $0) }.joined(); hdr = true
        }
        if let a = all[kCVImageBufferAmbientViewingEnvironmentKey as String] as? Data {
            info["ambientViewingEnvironment"] = a.map { String(format: "%02x", $0) }.joined()
        }
        let tf = info["transferFunction"] as? String ?? ""
        if tf.contains("2084") || tf.contains("HLG") || tf.contains("2100") { hdr = true; info["hdrTransfer"] = true }
        info["hdrMetadata"] = hdr
        // VideoToolbox sets this when the bitstream had no colour description and it filled in defaults.
        if let g = all["ColorInfoGuessedBy"] { info["colorInfoGuessedBy"] = "\(g)" }
        // Everything else, stringified, for completeness.
        let known: Set<String> = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferMasteringDisplayColorVolumeKey, kCVImageBufferContentLightLevelInfoKey].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        var rest: [String: String] = [:]
        for (k, v) in all where !known.contains(k) { rest[k] = "\(v)".prefix(200).description }
        if !rest.isEmpty { info["otherAttachments"] = rest }
        return info
    }
}
