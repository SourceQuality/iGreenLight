import Foundation
import Metal
import MetalKit
import MetalFX
import CoreVideo
import WebRTC
import simd
import CoreMedia
import QuartzCore

/// Receives decoded frames from libwebrtc, converts YUV→RGB on the GPU and upscales with MetalFX Spatial.
///
/// Pipeline: CVPixelBuffer (NV12 from VideoToolbox) → CVMetalTexture planes → RGB texture at
/// source size → MTLFXSpatialScaler to the on-screen content size → present pass (fit/zoom/stretch).
final class MetalVideoRenderer: NSObject, RTCVideoRenderer, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var nv12Pipeline: MTLRenderPipelineState!
    private var i420Pipeline: MTLRenderPipelineState!
    private var presentPipeline: MTLRenderPipelineState!

    private let lock = NSLock()
    private var pendingFrame: RTCVideoFrame?
    private var hasNewFrame = false

    private var rgbTexture: MTLTexture?
    private var upscaledTexture: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey: (Int, Int, Int, Int) = (0, 0, 0, 0)
    private var i420Textures: [MTLTexture] = []

    var scaling: ScalingMode = .fit
    var upscaler: Upscaler = .metalFX {
        didSet { if upscaler != .videoToolbox, #available(macOS 26.0, *) { vtsr?.reset() } }
    }
    private var useMetalFX: Bool { upscaler != .off }
    /// `VTSuperResolution` on macOS 26+, nil otherwise (stored untyped because of availability).
    private let vtsrBox: AnyObject? = {
        if #available(macOS 26.0, *) { return VTSuperResolution() }
        return nil
    }()
    @available(macOS 26.0, *)
    private var vtsr: VTSuperResolution? { vtsrBox as? VTSuperResolution }
    private var vtStatus: String {
        if #available(macOS 26.0, *) { return vtsr?.lastStatus ?? "-" }
        return "needs macOS 26"
    }
    /// Human-readable description of the current upscaling chain (for the stats overlay).
    private(set) var upscaleStatus = "-"
    var timingSummary: String { timing.current }
    /// Reported on the main queue when the decoded frame size changes.
    var onFrameSize: ((_ width: Int, _ height: Int) -> Void)?
    var onFrameRendered: (() -> Void)?
    private var lastSize = (0, 0)
    private var lastLayoutKey = ""
    private var loggedFirstFrame = false
    private var loggedFirstDraw = false
    private var loggedFormat = false
    private let timing = FrameTiming()
    private(set) var framesRendered = 0
    private(set) var metalFXActive = false

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        let lib = device.makeDefaultLibrary()!
        func pipeline(_ frag: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
            d.fragmentFunction = lib.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = fmt
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        nv12Pipeline = pipeline("nv12_fragment", .bgra8Unorm)
        i420Pipeline = pipeline("i420_fragment", .bgra8Unorm)
        presentPipeline = pipeline("present_fragment", .bgra8Unorm)
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
        view.autoResizeDrawable = true
    }

    // MARK: RTCVideoRenderer (called on the decoder thread)
    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        if !loggedFirstFrame { loggedFirstFrame = true; log("Render", "first frame from WebRTC: \(frame.width)x\(frame.height) \(type(of: frame.buffer))") }
        lock.lock()
        pendingFrame = frame
        hasNewFrame = true
        lock.unlock()
    }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if !loggedFirstDraw { loggedFirstDraw = true; log("Render", "first draw, drawable \(view.drawableSize)") }
        lock.lock()
        let frame = hasNewFrame ? pendingFrame : nil
        hasNewFrame = false
        lock.unlock()

        // Redraw the last frame on resize / mode change too, so letterboxing stays correct.
        let layoutKey = "\(view.drawableSize.width)x\(view.drawableSize.height)-\(scaling.rawValue)-\(upscaler.rawValue)"
        if frame == nil && (rgbTexture == nil || layoutKey == lastLayoutKey) { return }
        lastLayoutKey = layoutKey
        guard let cmd = commandQueue.makeCommandBuffer() else { return }

        // Content rect in drawable pixels (aspect from the decoded frame).
        let dw = Double(view.drawableSize.width), dh = Double(view.drawableSize.height)
        let sw = Double(frame.map { Int($0.width) } ?? rgbTexture?.width ?? 1)
        let sh = Double(frame.map { Int($0.height) } ?? rgbTexture?.height ?? 1)
        var cw = dw, ch = dh
        switch scaling {
        case .stretch: break
        case .fit: let s = min(dw / sw, dh / sh); cw = sw * s; ch = sh * s
        case .zoom: let s = max(dw / sw, dh / sh); cw = sw * s; ch = sh * s
        }
        let outW = Int(cw.rounded()), outH = Int(ch.rounded())

        let encodeStart = CACurrentMediaTime()
        var vtActive = false
        if let frame { vtActive = convert(frame, cmd, targetWidth: outW, targetHeight: outH) }
        guard let rgb = rgbTexture, let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }

        var source: MTLTexture = rgb
        if useMetalFX, outW >= rgb.width, outH >= rgb.height, outW * outH > rgb.width * rgb.height, outW <= 16384, outH <= 16384 {
            if let up = upscale(rgb, to: outW, outH, cmd) { source = up; metalFXActive = true } else { metalFXActive = false }
        } else { metalFXActive = false }
        if frame != nil {
            var parts: [String] = []
            if upscaler == .videoToolbox { parts.append(vtActive ? "VT ML \(vtStatus)" : "VT ML: \(vtStatus)") }
            parts.append(metalFXActive ? "MetalFX \(rgb.width)x\(rgb.height)→\(outW)x\(outH)" : "bilinear \(rgb.width)x\(rgb.height)→\(outW)x\(outH)")
            upscaleStatus = parts.joined(separator: ", ")
        }

        // Map drawable uv -> content uv.
        var params = SIMD4<Float>(Float(dw / cw), Float(dh / ch), Float(-(dw - cw) / 2 / cw), Float(-(dh - ch) / 2 / ch))
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(presentPipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        if frame != nil {
            let label = upscaleStatus
            cmd.addCompletedHandler { [weak self] cb in
                self?.timing.add(gpu: (cb.gpuEndTime - cb.gpuStartTime) * 1000,
                                 total: (CACurrentMediaTime() - encodeStart) * 1000, label: label)
            }
        }
        cmd.commit()
        if frame != nil {
            framesRendered += 1
            onFrameRendered?()
        }
    }

    // MARK: YUV -> RGB
    private struct YUVParams {
        var matrix: simd_float3x3
        var offset: SIMD3<Float>
        var scale: SIMD3<Float>
    }

    private func yuvParams(fullRange: Bool, matrix709: Bool) -> YUVParams {
        // BT.709 or BT.601 YCbCr→RGB.
        let m: simd_float3x3 = matrix709
            ? simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)))
            : simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.3441, 1.772), SIMD3(1.402, -0.7141, 0)))
        if fullRange {
            return YUVParams(matrix: m, offset: SIMD3(0, 0.5, 0.5), scale: SIMD3(1, 1, 1))
        }
        return YUVParams(matrix: m, offset: SIMD3(16.0 / 255, 0.5, 0.5), scale: SIMD3(255.0 / 219, 255.0 / 224, 255.0 / 224))
    }

    private func ensureRGB(_ w: Int, _ h: Int) -> MTLTexture {
        if let t = rgbTexture, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        rgbTexture = t
        return t
    }

    /// Converts the frame to RGB in `rgbTexture`. Returns true when VideoToolbox ML upscaling was applied.
    private func convert(_ frame: RTCVideoFrame, _ cmd: MTLCommandBuffer, targetWidth: Int, targetHeight: Int) -> Bool {
        var vtApplied = false
        let w = Int(frame.width), h = Int(frame.height)
        if (w, h) != lastSize {
            lastSize = (w, h)
            log("Render", "decoded frame size \(w)x\(h) (buffer \(type(of: frame.buffer)))")
            let cb = onFrameSize
            DispatchQueue.main.async { cb?(w, h) }
        }
        if let cv = frame.buffer as? RTCCVPixelBuffer {
            var pb = cv.pixelBuffer
            if !loggedFormat {
                loggedFormat = true
                log("Render", "decoder pixel format \(fourCC(CVPixelBufferGetPixelFormatType(pb)))")
            }
            if upscaler == .videoToolbox, #available(macOS 26.0, *), VTSuperResolution.isSupported,
               let up = vtsr?.process(pb, pts: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
                                      targetWidth: targetWidth, targetHeight: targetHeight, cmd: cmd) {
                pb = up
                vtApplied = true
            }
            let target = ensureRGB(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            var is709 = true
            if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                is709 = m != (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            }
            guard let y = cvTexture(pb, plane: 0, .r8Unorm), let uv = cvTexture(pb, plane: 1, .rg8Unorm),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return vtApplied }
            var p = yuvParams(fullRange: full, matrix709: is709)
            enc.setRenderPipelineState(nv12Pipeline)
            enc.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            enc.setFragmentTexture(CVMetalTextureGetTexture(uv), index: 1)
            enc.setFragmentBytes(&p, length: MemoryLayout<YUVParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            // Keep the CVMetalTextures alive until the GPU is done.
            let keep = pb
            cmd.addCompletedHandler { _ in _ = y; _ = uv; _ = keep }
        } else {
            let target = ensureRGB(w, h)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            let i420 = frame.buffer.toI420()
            let cw = Int(i420.chromaWidth), ch = Int(i420.chromaHeight)
            if i420Textures.count != 3 || i420Textures[0].width != w || i420Textures[0].height != h {
                i420Textures = [(w, h), (cw, ch), (cw, ch)].map { size in
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size.0, height: size.1, mipmapped: false)
                    d.usage = .shaderRead
                    return device.makeTexture(descriptor: d)!
                }
            }
            i420Textures[0].replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: i420.dataY, bytesPerRow: Int(i420.strideY))
            i420Textures[1].replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: i420.dataU, bytesPerRow: Int(i420.strideU))
            i420Textures[2].replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: i420.dataV, bytesPerRow: Int(i420.strideV))
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            var p = yuvParams(fullRange: false, matrix709: true)
            enc.setRenderPipelineState(i420Pipeline)
            for (i, t) in i420Textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentBytes(&p, length: MemoryLayout<YUVParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        return vtApplied
    }

    private func fourCC(_ t: OSType) -> String {
        String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)], encoding: .ascii) ?? "\(t)"
    }

    private func cvTexture(_ pb: CVPixelBuffer, plane: Int, _ fmt: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, plane, &tex)
        return tex
    }

    // MARK: MetalFX
    private func upscale(_ input: MTLTexture, to w: Int, _ h: Int, _ cmd: MTLCommandBuffer) -> MTLTexture? {
        let key = (input.width, input.height, w, h)
        if scaler == nil || scalerKey != key {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = input.width; d.inputHeight = input.height
            d.outputWidth = w; d.outputHeight = h
            d.colorTextureFormat = input.pixelFormat
            d.outputTextureFormat = .bgra8Unorm
            d.colorProcessingMode = .perceptual
            guard MTLFXSpatialScalerDescriptor.supportsDevice(device), let s = d.makeSpatialScaler(device: device) else {
                log("Render", "MetalFX spatial scaler unavailable")
                return nil
            }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = s.outputTextureUsage.union(.shaderRead)
            td.storageMode = .private
            upscaledTexture = device.makeTexture(descriptor: td)
            scaler = s
            scalerKey = key
            log("Render", "MetalFX spatial \(input.width)x\(input.height) -> \(w)x\(h)")
        }
        guard let s = scaler, let out = upscaledTexture else { return nil }
        s.colorTexture = input
        s.outputTexture = out
        s.encode(commandBuffer: cmd)
        return out
    }
}

/// Rolling per-frame render cost: GPU time of the command buffer, and wall time from the start of
/// encoding (incl. the CPU-side 420f→420v transfer for VT) until the GPU finished.
final class FrameTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var gpu: [Double] = [], total: [Double] = []
    private(set) var summary = "-"

    func add(gpu g: Double, total t: Double, label: String) {
        lock.lock(); defer { lock.unlock() }
        gpu.append(g); total.append(t)
        guard gpu.count >= 120 else { return }
        func avg(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let sorted = total.sorted()
        summary = String(format: "gpu %.2f ms (max %.2f), encode→done %.2f ms (p95 %.2f)",
                         avg(gpu), gpu.max() ?? 0, avg(total), sorted[Int(Double(sorted.count) * 0.95)])
        log("Timing", "\(label): \(summary)")
        gpu.removeAll(); total.removeAll()
    }

    var current: String { lock.lock(); defer { lock.unlock() }; return summary }
}
