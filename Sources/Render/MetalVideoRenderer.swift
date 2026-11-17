import Foundation
import Metal
import MetalKit
import MetalFX
import CoreVideo
import WebRTC
import simd

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
    var useMetalFX = true
    /// Reported on the main queue when the decoded frame size changes.
    var onFrameSize: ((_ width: Int, _ height: Int) -> Void)?
    var onFrameRendered: (() -> Void)?
    private var lastSize = (0, 0)
    private var lastLayoutKey = ""
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
        lock.lock()
        pendingFrame = frame
        hasNewFrame = true
        lock.unlock()
    }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let frame = hasNewFrame ? pendingFrame : nil
        hasNewFrame = false
        lock.unlock()

        // Redraw the last frame on resize / mode change too, so letterboxing stays correct.
        let layoutKey = "\(view.drawableSize.width)x\(view.drawableSize.height)-\(scaling.rawValue)-\(useMetalFX)"
        if frame == nil && (rgbTexture == nil || layoutKey == lastLayoutKey) { return }
        lastLayoutKey = layoutKey
        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        if let frame { convert(frame, cmd) }
        guard let rgb = rgbTexture, let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }

        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let sw = Double(rgb.width), sh = Double(rgb.height)
        // Content rect in drawable pixels.
        var cw = dw, ch = dh
        switch scaling {
        case .stretch: break
        case .fit: let s = min(dw / sw, dh / sh); cw = sw * s; ch = sh * s
        case .zoom: let s = max(dw / sw, dh / sh); cw = sw * s; ch = sh * s
        }
        let outW = Int(cw.rounded()), outH = Int(ch.rounded())

        var source: MTLTexture = rgb
        if useMetalFX, outW >= rgb.width, outH >= rgb.height, outW * outH > rgb.width * rgb.height, outW <= 16384, outH <= 16384 {
            if let up = upscale(rgb, to: outW, outH, cmd) { source = up; metalFXActive = true } else { metalFXActive = false }
        } else { metalFXActive = false }

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

    private func convert(_ frame: RTCVideoFrame, _ cmd: MTLCommandBuffer) {
        let w = Int(frame.width), h = Int(frame.height)
        if (w, h) != lastSize {
            lastSize = (w, h)
            log("Render", "decoded frame size \(w)x\(h) (buffer \(type(of: frame.buffer)))")
            let cb = onFrameSize
            DispatchQueue.main.async { cb?(w, h) }
        }
        let target = ensureRGB(w, h)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store

        if let cv = frame.buffer as? RTCCVPixelBuffer {
            let pb = cv.pixelBuffer
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            var is709 = true
            if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                is709 = m != (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            }
            guard let y = cvTexture(pb, plane: 0, .r8Unorm), let uv = cvTexture(pb, plane: 1, .rg8Unorm),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            var p = yuvParams(fullRange: full, matrix709: is709)
            enc.setRenderPipelineState(nv12Pipeline)
            enc.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            enc.setFragmentTexture(CVMetalTextureGetTexture(uv), index: 1)
            enc.setFragmentBytes(&p, length: MemoryLayout<YUVParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            // Keep the CVMetalTextures alive until the GPU is done.
            cmd.addCompletedHandler { _ in _ = y; _ = uv }
        } else {
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
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            var p = yuvParams(fullRange: false, matrix709: true)
            enc.setRenderPipelineState(i420Pipeline)
            for (i, t) in i420Textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentBytes(&p, length: MemoryLayout<YUVParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
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
                useMetalFX = false
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
