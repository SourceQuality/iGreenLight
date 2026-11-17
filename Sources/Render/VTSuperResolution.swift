import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import Metal

/// ML super-resolution using VideoToolbox's `VTLowLatencySuperResolutionScaler` (macOS 26+).
///
/// The low-latency scaler is designed for real-time video, but it only accepts small sources
/// (on Apple silicon at the time of writing: up to 1280 px on the long side for 1.5x, 960 px for 2x,
/// 480 px for 4x) and only `420v` (video-range NV12) input. So in practice it upgrades a 720p stream
/// to 1080p; MetalFX / bilinear then covers the rest of the way to the drawable.
///
/// Sessions load an ML model, which can take longer than a frame, so they're created off the render
/// thread. Until one is ready (or when the stream's size isn't supported), `process` returns nil and the
/// caller renders the frame without it.
@available(macOS 26.0, *)
final class VTSuperResolution: @unchecked Sendable {
    struct Key: Hashable { let width: Int; let height: Int; let scale: Float }

    private final class Session {
        let key: Key
        let processor = VTFrameProcessor()
        var srcPool: CVPixelBufferPool?
        var dstPool: CVPixelBufferPool?
        var transfer: VTPixelTransferSession?
        var ready = false
        init(key: Key) { self.key = key }
    }

    static var isSupported: Bool { VTLowLatencySuperResolutionScalerConfiguration.isSupported }

    private let lock = NSLock()
    private var session: Session?
    private var pendingKey: Key?
    private var failedKeys = Set<Key>()
    private let setupQueue = DispatchQueue(label: "app.igreenlight.vtsr", qos: .userInitiated)
    private(set) var lastStatus = "off"

    /// Largest supported factor for this source that doesn't overshoot the target size too much.
    static func scaleFactor(width: Int, height: Int, targetWidth: Int, targetHeight: Int) -> Float? {
        let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
        let need = max(Float(targetWidth) / Float(width), Float(targetHeight) / Float(height))
        guard need > 1.05 else { return nil }
        // Prefer the biggest factor that doesn't exceed what the screen needs; otherwise the smallest one.
        return factors.filter { $0 <= need + 0.01 }.max() ?? factors.min()
    }

    /// Encodes ML upscaling of `source` into `cmd`. Returns the upscaled (420v) pixel buffer, or nil to fall back.
    func process(_ source: CVPixelBuffer, pts: CMTime, targetWidth: Int, targetHeight: Int, cmd: MTLCommandBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        guard let scale = Self.scaleFactor(width: w, height: h, targetWidth: targetWidth, targetHeight: targetHeight) else {
            lastStatus = "n/a for \(w)x\(h) (max 1280 px source)"
            return nil
        }
        let key = Key(width: w, height: h, scale: scale)

        lock.lock()
        let s = session
        let isReady = s?.key == key && s?.ready == true
        if !isReady && pendingKey != key && !failedKeys.contains(key) {
            pendingKey = key
            setupQueue.async { [weak self] in self?.startSession(key) }
        }
        lock.unlock()
        guard isReady, let s else {
            lastStatus = failedKeys.contains(key) ? "failed for \(w)x\(h)" : "loading model for \(w)x\(h) ×\(scale)…"
            return nil
        }

        // The scaler wants video-range NV12 in IOSurface-backed buffers from its own attributes.
        guard let src = convert(source, s), let dst = buffer(from: s.dstPool) else { return nil }
        guard let srcFrame = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
              let dstFrame = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts) else { return nil }
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: srcFrame, destinationFrame: dstFrame)
        s.processor.process(with: cmd, parameters: params)
        lastStatus = "\(w)x\(h) → \(CVPixelBufferGetWidth(dst))x\(CVPixelBufferGetHeight(dst)) (×\(scale))"
        return dst
    }

    private func startSession(_ key: Key) {
        let t0 = Date()
        let s = Session(key: key)
        let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: key.width, frameHeight: key.height, scaleFactor: key.scale)
        do {
            try s.processor.startSession(configuration: cfg)
            s.srcPool = Self.pool(cfg.sourcePixelBufferAttributes)
            s.dstPool = Self.pool(cfg.destinationPixelBufferAttributes)
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s.transfer)
            s.ready = s.srcPool != nil && s.dstPool != nil
            log("Render", "VT low-latency super-resolution ready for \(key.width)x\(key.height) ×\(key.scale) in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
        } catch {
            log("Render", "VT super-resolution session failed for \(key): \(error)")
        }
        lock.lock()
        if pendingKey == key { pendingKey = nil }
        if s.ready {
            let old = session
            session = s
            lock.unlock()
            old?.processor.endSession()
        } else {
            failedKeys.insert(key)
            lock.unlock()
        }
    }

    private static func pool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
        var attrs = attrs
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private func buffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// WebRTC's VideoToolbox decoder gives full-range NV12 (420f); the scaler needs 420v.
    private func convert(_ source: CVPixelBuffer, _ s: Session) -> CVPixelBuffer? {
        guard let out = buffer(from: s.srcPool), let transfer = s.transfer else { return nil }
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: out)
        return status == noErr ? out : nil
    }

    func reset() {
        lock.lock()
        let s = session
        session = nil
        failedKeys.removeAll()
        lock.unlock()
        s?.processor.endSession()
        lastStatus = "off"
    }
}
