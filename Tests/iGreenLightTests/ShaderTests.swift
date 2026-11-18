import Foundation
import Metal
import simd
import Testing
@testable import iGreenLight

/// Renders a synthetic frame through the app's compiled shaders, the same passes `MetalVideoRenderer` runs:
/// quarter-size downsample → mip chain → small ambient texture and its mips → present pass with letterbox bars.
@Suite struct ShaderTests {
    struct Output { let pixels: [UInt8]; let width: Int; let height: Int
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]))
        }
    }

    /// 640×360 source that is pure red on the left half and pure blue on the right, fitted into the drawable:
    /// 640×400 (16:10) with the picture centred unless told otherwise. `anchorY` 0 puts the picture at the top.
    private func render(ambient: Bool, clearAmbientFirst: Bool = true, dw: Int = 640, dh: Int = 400, anchorY: Float = 0.5) throws -> Output {
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
        let sw = 640, sh = 360
        let source = try texture(sw, sh, .bgra8Unorm)
        var px = [UInt8](repeating: 255, count: sw * sh * 4)
        for y in 0..<sh { for x in 0..<sw {
            let i = (y * sw + x) * 4
            px[i] = x < sw / 2 ? 0 : 255; px[i + 1] = 0; px[i + 2] = x < sw / 2 ? 255 : 0   // BGRA
        } }
        source.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: px, bytesPerRow: sw * 4)
        let mips = try texture(sw / 4, sh / 4, .bgra8Unorm, mips: true)
        let small = try texture(32, 18, .rgba16Float, mips: true)
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
        let blit2 = try #require(cmd.makeBlitCommandEncoder())
        blit2.generateMipmaps(for: small)
        blit2.endEncoding()
        let scale = min(Float(dw) / Float(sw), Float(dh) / Float(sh)), cw = Float(sw) * scale, ch = Float(sh) * scale
        try pass(out, pipeline("present_fragment", .bgra8Unorm), [source, small], [
            SIMD4(Float(dw) / cw, Float(dh) / ch, -(Float(dw) - cw) / 2 / cw, -(Float(dh) - ch) * anchorY / ch),   // uv
            SIMD4(0, 0, 0, 0),                                            // deband off, no grain
            SIMD4(1, 0.5, 0, 0),                                          // SDR
            SIMD4(ambient ? 1 : 0, 0.75, 0.3, 1.15),                      // ambient: same constants as the renderer
            SIMD4(0, 0, 0, 0),                                            // no sharpening
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

    /// Both bars glow in the colour of the picture next to them, dimmer than the picture and dimmer still at the
    /// screen edge. Checks every bar pixel well away from the red/blue seam, so a partly black bar fails.
    @Test func barsGlowInTheColourOfTheNearestEdgeAndDimOutwards() throws {
        let o = try render(ambient: true)
        for y in Array(0..<20) + Array(380..<400) {
            for x in stride(from: 0, to: 640, by: 8) where abs(x - 320) > 200 {
                let p = o.rgb(x, y)
                let (main, other) = x < 320 ? (p.r, p.b) : (p.b, p.r)
                // 255 × 0.75 at the picture edge, about 17 % less 20 px (0.056 picture heights) out, plus the 1.15 saturation boost.
                #expect(main > 150 && main < 225, "(\(x), \(y)) = \(p)")
                #expect(other < 10 && p.g < 10, "(\(x), \(y)) = \(p)")
            }
        }
        #expect(o.rgb(100, 19).r > o.rgb(100, 0).r + 25)      // top bar: brighter next to the picture
        #expect(o.rgb(540, 380).b > o.rgb(540, 399).b + 25)   // bottom bar likewise
    }

    /// Portrait with the picture at the top (the on-screen gamepad below it): the one tall bar starts in the
    /// picture's colours and fades smoothly to black. No reflection of the picture and nothing lit far from it.
    @Test func aTallBarBelowATopAnchoredPictureFadesToBlack() throws {
        let o = try render(ambient: true, dw: 360, dh: 800, anchorY: 0)   // picture: rows 0..<202.5
        #expect(o.rgb(40, 100) == (255, 0, 0))
        #expect(o.rgb(320, 100) == (0, 0, 255))
        #expect(o.rgb(40, 204).r > 150 && o.rgb(320, 204).b > 150)
        var last = 255
        for y in 204..<800 {
            let p = o.rgb(40, y)
            #expect(p.r <= last && p.g < 10 && p.b < 10, "(40, \(y)) = \(p)")   // only ever dimmer, never the other half's blue
            last = p.r
        }
        for y in stride(from: 520, to: 800, by: 20) { for x in [0, 90, 180, 270, 359] {   // 1.5 picture heights out and beyond
            let p = o.rgb(x, y)
            #expect(p.r <= 3 && p.g <= 3 && p.b <= 3, "(\(x), \(y)) = \(p)")
        } }
    }
}
