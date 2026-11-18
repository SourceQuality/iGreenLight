import Foundation
import Metal
import MetalKit
// The iOS Simulator SDK has no MetalFX; there the renderer falls back to bilinear.
#if canImport(MetalFX)
import MetalFX
#endif
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
    private var presentPipelineEDR: MTLRenderPipelineState!
    private var downsamplePipeline: MTLRenderPipelineState!
    private var ambientPipeline: MTLRenderPipelineState!

    private let lock = NSLock()
    private var pendingFrame: RTCVideoFrame?
    private var hasNewFrame = false

    private var rgbTexture: MTLTexture?
    private var upscaledTexture: MTLTexture?
    #if canImport(MetalFX)
    private var scaler: MTLFXSpatialScaler?
    #endif
    private var scalerKey: (Int, Int, Int, Int) = (0, 0, 0, 0)
    private var i420Textures: [MTLTexture] = []

    var scaling: ScalingMode = .fit
    var upscaler: Upscaler = .metalFX {
        didSet { if upscaler != .videoToolbox, #available(macOS 26.0, iOS 26.0, *) { vtsr?.reset() } }
    }
    /// Smooth 8-bit banding in flat gradients (present pass).
    var deband = true
    /// Which colour space the layer was last tagged for (nil: not yet, so the first draw sets it).
    private var colorTaggedEDR: Bool?
    /// SDR→EDR highlight expansion. `.off` keeps the 8-bit SDR drawable.
    var edr: EDRExpansion = .off
    /// Fill the letterbox bars (Fit mode) with a blurred, mirrored extension of the picture instead of black.
    var ambient = true
    /// Where a picture shorter than the view sits vertically: 0.5 centred, 0 at the top (a tall window with the
    /// on-screen gamepad below the picture).
    var pictureAnchorY: Double = 0.5
    /// Quarter-size copy of the frame with a full mip chain; source for `ambientTexture`.
    private var ambientMips: MTLTexture?
    /// ~128 px wide, temporally smoothed copy of the frame that the bars are drawn from.
    /// Float so the running average converges instead of sticking a few 8-bit steps short.
    private var ambientTexture: MTLTexture?
    private var ambientPrimed = false
    private var frameSeed: Float = 0
    private var useMetalFX: Bool { upscaler != .off }
    /// `VTSuperResolution` on macOS 26+, nil otherwise (stored untyped because of availability).
    private let vtsrBox: AnyObject? = {
        if #available(macOS 26.0, iOS 26.0, *) { return VTSuperResolution() }
        return nil
    }()
    @available(macOS 26.0, iOS 26.0, *)
    private var vtsr: VTSuperResolution? { vtsrBox as? VTSuperResolution }
    private var vtStatus: String {
        if #available(macOS 26.0, iOS 26.0, *) { return vtsr?.lastStatus ?? "-" }
        #if os(macOS)
        return "needs macOS 26"
        #else
        return "needs iOS 26"
        #endif
    }
    /// Human-readable description of the current upscaling chain (for the stats overlay).
    private(set) var upscaleStatus = "-"
    var timingSummary: String { timing.current }
    /// Reported on the main queue when the decoded frame size changes.
    var onFrameSize: ((_ width: Int, _ height: Int) -> Void)?
    private var lastSize = (0, 0)
    private var lastLayoutKey = ""
    private var loggedFirstFrame = false
    private var loggedFirstDraw = false
    private var loggedFormat = false
    private let timing = FrameTiming()
    private(set) var framesRendered = 0
    private(set) var metalFXActive = false

    struct SetupError: LocalizedError {
        let errorDescription: String?
    }

    /// Throws when Metal or the app's shaders can't be set up, so the stream can say so instead of crashing.
    init(_: Void = ()) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SetupError(errorDescription: "Metal isn't available on this device, so the stream can't be drawn.")
        }
        self.device = device
        commandQueue = queue
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        let lib = try device.makeDefaultLibrary(bundle: .main)
        func pipeline(_ frag: String, _ fmt: MTLPixelFormat, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
            d.fragmentFunction = lib.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = fmt
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        nv12Pipeline = try pipeline("nv12_fragment", .bgra8Unorm)
        i420Pipeline = try pipeline("i420_fragment", .bgra8Unorm)
        presentPipeline = try pipeline("present_fragment", .bgra8Unorm)
        presentPipelineEDR = try pipeline("present_fragment", .rgba16Float)
        downsamplePipeline = try pipeline("downsample_fragment", .bgra8Unorm)
        ambientPipeline = try pipeline("ambient_fragment", .rgba16Float, blend: true)
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        colorTaggedEDR = nil   // a new view's layer is untagged
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
        DiagnosticsRecorder.current?.recordFrame(frame)
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
        // Switch the drawable between 8-bit SDR and float extended-linear sRGB when the EDR setting changes.
        let wantEDR = edr != .off
        // The SDR drawable is tagged sRGB: an untagged (nil) layer is not colour-matched, so a P3 display would
        // show the BT.709 picture in its own wider gamut, oversaturated. `colorTaggedEDR` starts nil so the tag
        // is also set on the first draw with EDR off, when the pixel format never changes. The layer is set
        // directly: MTKView's own `colorspace` (macOS only) is just an alias of the layer's.
        if wantEDR != (view.colorPixelFormat == .rgba16Float) { view.colorPixelFormat = wantEDR ? .rgba16Float : .bgra8Unorm }
        if colorTaggedEDR != wantEDR, let layer = view.layer as? CAMetalLayer {
            colorTaggedEDR = wantEDR
            layer.wantsExtendedDynamicRangeContent = wantEDR
            layer.colorspace = CGColorSpace(name: wantEDR ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
            log("Render", "drawable \(wantEDR ? "rgba16Float, extended linear sRGB (EDR)" : "bgra8Unorm, sRGB (SDR, colour-matched)")")
        }
        // Headroom the display can show right now (1 = none; it moves with brightness and ambient light).
        #if os(macOS)
        let headroom = Float(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        #else
        let headroom = Float(view.window?.windowScene?.screen.currentEDRHeadroom ?? 1)
        #endif
        let peak = wantEDR ? max(1, min(edr.peak, headroom)) : 1

        let layoutKey = "\(view.drawableSize.width)x\(view.drawableSize.height)-\(scaling.rawValue)-\(upscaler.rawValue)-\(deband)-\(edr.rawValue)-\(ambient)-\(pictureAnchorY)"
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
        if let f = frame {
            vtActive = convert(f, cmd, targetWidth: outW, targetHeight: outH)
        }
        guard let rgb = rgbTexture, let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }

        // Ambient bars: only when Fit leaves at least a pixel of bar. Updated per decoded frame (and once when just enabled).
        let wantAmbient = ambient && scaling == .fit && (dw - cw >= 1 || dh - ch >= 1)
        if !wantAmbient { ambientPrimed = false }
        else if frame != nil || !ambientPrimed { updateAmbient(from: rgb, cmd) }
        let ambientSource = wantAmbient && ambientPrimed ? ambientTexture : nil

        var source: MTLTexture = rgb
        if useMetalFX, outW >= rgb.width, outH >= rgb.height, outW * outH > rgb.width * rgb.height, outW <= 16384, outH <= 16384 {
            if let up = upscale(rgb, to: outW, outH, cmd) { source = up; metalFXActive = true } else { metalFXActive = false }
        } else { metalFXActive = false }
        if frame != nil {
            var parts: [String] = []
            if upscaler == .videoToolbox { parts.append(vtActive ? "VT ML \(vtStatus)" : "VT ML: \(vtStatus)") }
            parts.append(metalFXActive ? "MetalFX \(rgb.width)x\(rgb.height)→\(outW)x\(outH)" : "bilinear \(rgb.width)x\(rgb.height)→\(outW)x\(outH)")
            if deband { parts.append("deband") }
            if wantAmbient { parts.append("ambient bars") }
            if wantEDR { parts.append(String(format: "EDR ×%.1f (headroom %.1f)", peak, headroom)) }
            upscaleStatus = parts.joined(separator: ", ")
        }

        // Map drawable uv -> content uv.
        // Deband radius is 16 pixels of the decoded frame, whatever the upscale; threshold ≈ 1.5 steps of 8-bit;
        // grain is ±0.5 of an 8-bit step, enough to dither the smoothed gradient back into the 8-bit drawable.
        if frame != nil { frameSeed = Float((framesRendered &* 37) % 1024) }
        var params = PresentParams(
            uv: SIMD4(Float(dw / cw), Float(dh / ch), Float(-(dw - cw) / 2 / cw), Float(-(dh - ch) * (ch < dh ? pictureAnchorY : 0.5) / ch)),
            deband: SIMD4(16 / Float(rgb.width), 16 / Float(rgb.height), deband ? 1.5 / 255 : 0, 1.0 / 255),
            edr: SIMD4(peak, 0.5, frameSeed, wantEDR ? 1 : 0),
            ambient: SIMD4(ambientSource != nil ? 1 : 0, 0.7, 0.4, 1.15))
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(wantEDR ? presentPipelineEDR : presentPipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentTexture(ambientSource ?? source, index: 1)
        enc.setFragmentBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
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
        }
    }

    /// Mirrors `PresentParams` in Shaders.metal.
    private struct PresentParams {
        var uv: SIMD4<Float>
        var deband: SIMD4<Float>
        var edr: SIMD4<Float>
        var ambient: SIMD4<Float>
    }

    // MARK: Ambient bars
    /// rgb → quarter size (box) → mip chain → ~128 px texture, blended 25 % per frame over the previous result.
    private func updateAmbient(from rgb: MTLTexture, _ cmd: MTLCommandBuffer) {
        let mw = max(1, rgb.width / 4), mh = max(1, rgb.height / 4)
        if ambientMips?.width != mw || ambientMips?.height != mh || ambientTexture == nil {
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: mw, height: mh, mipmapped: true)
            md.usage = [.renderTarget, .shaderRead]
            md.storageMode = .private
            ambientMips = device.makeTexture(descriptor: md)
            let aw = min(128, mw), ah = max(1, Int((Double(aw) * Double(mh) / Double(mw)).rounded()))
            let ad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: aw, height: ah, mipmapped: false)
            ad.usage = [.renderTarget, .shaderRead]
            ad.storageMode = .private
            ambientTexture = device.makeTexture(descriptor: ad)
            ambientPrimed = false
        }
        guard let mips = ambientMips, let target = ambientTexture else { return }

        let down = MTLRenderPassDescriptor()
        down.colorAttachments[0].texture = mips
        down.colorAttachments[0].loadAction = .dontCare
        down.colorAttachments[0].storeAction = .store
        guard let e1 = cmd.makeRenderCommandEncoder(descriptor: down) else { return }
        e1.setRenderPipelineState(downsamplePipeline)
        e1.setFragmentTexture(rgb, index: 0)
        e1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e1.endEncoding()
        if mips.mipmapLevelCount > 1, let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: mips)
            blit.endEncoding()
        }

        let acc = MTLRenderPassDescriptor()
        acc.colorAttachments[0].texture = target
        // Clear, not dontCare: the blend multiplies the old contents by 0 on the first frame, and stale
        // float memory can hold NaN (NaN × 0 = NaN), which would stay in the running average for good.
        acc.colorAttachments[0].loadAction = ambientPrimed ? .load : .clear
        acc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        acc.colorAttachments[0].storeAction = .store
        guard let e2 = cmd.makeRenderCommandEncoder(descriptor: acc) else { return }
        var p = SIMD4<Float>(ambientPrimed ? 0.25 : 1, 0, 0, 0)
        e2.setRenderPipelineState(ambientPipeline)
        e2.setFragmentTexture(mips, index: 0)
        e2.setFragmentBytes(&p, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e2.endEncoding()
        ambientPrimed = true
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
        if let base = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer {
            var pb = base
            if !loggedFormat {
                loggedFormat = true
                log("Render", "decoder pixel format \(fourCC(CVPixelBufferGetPixelFormatType(pb)))")
            }
            let srcFmt = CVPixelBufferGetPixelFormatType(pb)
            let eightBit = srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if eightBit, upscaler == .videoToolbox, #available(macOS 26.0, iOS 26.0, *), VTSuperResolution.isSupported,
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
            let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            // 10-bit biplanar (x420/xf20, from HEVC Main 10) samples as 16-bit MSB-aligned planes; normalised values match 8-bit closely enough.
            let tenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            var is709 = true
            if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                is709 = m != (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            }
            guard let y = cvTexture(pb, plane: 0, tenBit ? .r16Unorm : .r8Unorm), let uv = cvTexture(pb, plane: 1, tenBit ? .rg16Unorm : .rg8Unorm),
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
        #if canImport(MetalFX)
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
        #else
        return nil
        #endif
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
