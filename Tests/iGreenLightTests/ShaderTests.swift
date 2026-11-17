import Foundation
import Metal
import simd
import Testing
@testable import iGreenLight

/// Renders a synthetic frame through the app's compiled shaders, the same passes `MetalVideoRenderer` runs:
/// quarter-size downsample → mip chain → small ambient texture → present pass with letterbox bars.
@Suite struct ShaderTests {
    struct Output { let pixels: [UInt8]; let width: Int; let height: Int
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]))
        }
    }

    /// 640×360 source that is pure red on the left half and pure blue on the right, shown in a 640×400 (16:10) drawable.
    private func render(ambient: Bool, clearAmbientFirst: Bool = true) throws -> Output {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let lib = try device.makeDefaultLibrary(bundle: .main)
        let queue = try #require(device.makeCommandQueue())
        func pipeline(_ fragment: String, _ format: MTLPixelFormat, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
            d.fragmentFunction = lib.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat, mips: Bool = false) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: mips)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return try #require(device.makeTexture(descriptor: d))
        }
        let sw = 640, sh = 360, dw = 640, dh = 400
        let source = try texture(sw, sh, .bgra8Unorm)
        var px = [UInt8](repeating: 255, count: sw * sh * 4)
        for y in 0..<sh { for x in 0..<sw {
            let i = (y * sw + x) * 4
            px[i] = x < sw / 2 ? 0 : 255; px[i + 1] = 0; px[i + 2] = x < sw / 2 ? 255 : 0   // BGRA
        } }
        source.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: px, bytesPerRow: sw * 4)
        let mips = try texture(sw / 4, sh / 4, .bgra8Unorm, mips: true)
        let small = try texture(128, 72, .rgba16Float)
        let out = try texture(dw, dh, .bgra8Unorm)

        let cmd = try #require(queue.makeCommandBuffer())
        func pass(_ target: MTLTexture, _ state: MTLRenderPipelineState, _ textures: [MTLTexture], _ params: [SIMD4<Float>], clear: Bool) throws {
            let r = MTLRenderPassDescriptor()
            r.colorAttachments[0].texture = target
            r.colorAttachments[0].loadAction = clear ? .clear : .dontCare
            r.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            r.colorAttachments[0].storeAction = .store
            let e = try #require(cmd.makeRenderCommandEncoder(descriptor: r))
            e.setRenderPipelineState(state)
            for (i, t) in textures.enumerated() { e.setFragmentTexture(t, index: i) }
            if !params.isEmpty { var p = params; e.setFragmentBytes(&p, length: MemoryLayout<SIMD4<Float>>.stride * p.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        try pass(mips, pipeline("downsample_fragment", .bgra8Unorm), [source], [], clear: false)
        let blit = try #require(cmd.makeBlitCommandEncoder())
        blit.generateMipmaps(for: mips)
        blit.endEncoding()
        try pass(small, pipeline("ambient_fragment", .rgba16Float, blend: true), [mips], [SIMD4(1, 0, 0, 0)], clear: clearAmbientFirst)
        let ch = Float(dw) * 9 / 16   // 360: the picture's height inside the 400 px drawable
        try pass(out, pipeline("present_fragment", .bgra8Unorm), [source, small], [
            SIMD4(1, Float(dh) / ch, 0, -(Float(dh) - ch) / 2 / ch),      // uv
            SIMD4(0, 0, 0, 0),                                            // deband off, no grain
            SIMD4(1, 0.5, 0, 0),                                          // SDR
            SIMD4(ambient ? 1 : 0, 0.7, 0.4, 1.15),                       // ambient: same constants as the renderer
        ], clear: true)
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.error == nil)
        var bytes = [UInt8](repeating: 0, count: dw * dh * 4)
        out.getBytes(&bytes, bytesPerRow: dw * 4, from: MTLRegionMake2D(0, 0, dw, dh), mipmapLevel: 0)
        return Output(pixels: bytes, width: dw, height: dh)
    }

    @Test func pictureAreaIsDrawnUnchanged() throws {
        let o = try render(ambient: true)
        #expect(o.rgb(100, 200) == (255, 0, 0))
        #expect(o.rgb(540, 200) == (0, 0, 255))
        #expect(o.rgb(100, 21) == (255, 0, 0))     // first picture row below the 20 px top bar
        #expect(o.rgb(540, 378) == (0, 0, 255))    // last picture rows above the bottom bar
    }

    @Test func barsAreBlackWhenAmbientIsOff() throws {
        let o = try render(ambient: false)
        for y in [0, 10, 19, 381, 399] { for x in [0, 100, 320, 540, 639] {
            #expect(o.rgb(x, y) == (0, 0, 0), "(\(x), \(y))")
        } }
    }

    /// Both bars continue the colour of the picture next to them, dimmer than the picture and dimmer still at the
    /// screen edge. Checks every bar pixel away from the red/blue seam, so a partly black bar fails.
    @Test func barsExtendThePictureDimmedTowardsTheScreenEdge() throws {
        let o = try render(ambient: true)
        for y in Array(0..<20) + Array(380..<400) {
            for x in stride(from: 0, to: 640, by: 8) where abs(x - 320) > 60 {
                let p = o.rgb(x, y)
                let (main, other) = x < 320 ? (p.r, p.b) : (p.b, p.r)
                // 255 × 0.7 at the picture edge down to 255 × 0.4 at the screen edge, plus the 1.15 saturation boost.
                #expect(main > 80 && main < 215, "(\(x), \(y)) = \(p)")
                #expect(other < 30 && p.g < 30, "(\(x), \(y)) = \(p)")
            }
        }
        #expect(o.rgb(100, 19).r > o.rgb(100, 0).r + 30)      // top bar: brighter next to the picture
        #expect(o.rgb(540, 380).b > o.rgb(540, 399).b + 30)   // bottom bar likewise
    }
}
