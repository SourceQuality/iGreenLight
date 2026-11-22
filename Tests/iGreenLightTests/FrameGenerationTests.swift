import Testing
@testable import iGreenLight

/// Plays a stream through `FrameGenScheduler` with every generated picture ready at once, and records what reaches
/// the screen at each display tick.
private struct GenSim {
    struct Shown { let at: Double; let content: Double; let generated: Bool }

    var scheduler: FrameGenScheduler
    var shown: [Shown] = []
    var phases: [Float] = []
    var requestsSeen = 0

    /// `gameFPS` frames inside a `streamFPS` stream (the rest repeat), arriving `latency` + up to `jitter` after
    /// capture, shown on a `displayHz` display, for `seconds`.
    init(mode: FrameGenMode, gameFPS: Double, streamFPS: Double = 60, displayHz: Double, seconds: Double = 4,
         latency: Double = 0.04, jitter: Double = 0.004, gapAt: Double? = nil) {
        scheduler = FrameGenScheduler(outputStep: mode.outputStep, phaseGrid: mode.phaseGrid)
        var content: [FrameGenScheduler.Key: (time: Double, generated: Bool)] = [:]
        var lastUnique: Double?
        var lastShownKey: FrameGenScheduler.Key?
        var lastGameFrame = -1
        let frames = Int(seconds * streamFPS)
        var i = 0, k = 0
        // A repeatable spread of arrival delays in [0, jitter).
        func spread(_ n: Int) -> Double { Double((n &* 7919) % 97) / 97 * jitter }
        func arrival(_ n: Int) -> Double {
            var t = 1 + Double(n) / streamFPS + latency + spread(n)
            if let gapAt, Double(n) / streamFPS >= gapAt { t += 0.5 }
            return t
        }
        while i < frames || k < Int(seconds * displayHz) {
            let tick = 1.0003 + Double(k) / displayHz
            if i < frames, arrival(i) <= tick {
                let game = Int((Double(i) * gameFPS / streamFPS + 1e-9).rounded(.down))
                let a = scheduler.arrived(rtp: UInt32(i) &* UInt32(90_000 / streamFPS), at: arrival(i), repeated: game == lastGameFrame)
                lastGameFrame = game
                if !a.repeated {
                    content[.real(a.id)] = (a.time, false)
                    for r in a.requests {
                        let prev = lastUnique ?? a.time
                        content[r.key] = (prev + Double(r.phase) * (a.time - prev), true)
                        phases.append(r.phase)
                    }
                    requestsSeen += a.requests.count
                    lastUnique = a.time
                }
                i += 1
            } else {
                if let slot = scheduler.due(at: tick), slot.show != lastShownKey, let c = content[slot.show] {
                    shown.append(Shown(at: tick, content: c.time, generated: c.generated))
                    lastShownKey = slot.show
                }
                k += 1
            }
        }
    }

    /// What was shown after the first second (warm-up).
    var settled: [Shown] { shown.filter { $0.at > 2.2 } }
}

struct FrameGenSchedulerTests {
    @Test func thirtyInSixtyBecomesAnEvenSixty() {
        let sim = GenSim(mode: .fps60, gameFPS: 30, displayHz: 60)
        #expect(sim.scheduler.active)
        #expect(abs(sim.scheduler.interval - 1.0 / 30) < 1e-6)
        let s = sim.settled
        #expect(s.count > 100)
        // Every new picture is one output step further in the game's time, and half of them are generated.
        let steps = zip(s.dropFirst(), s).map { $0.content - $1.content }
        let even = steps.filter { abs($0 - 1.0 / 60) < 1e-4 }.count
        #expect(Double(even) / Double(steps.count) > 0.97)
        let generated = s.filter(\.generated).count
        #expect(abs(Double(generated) / Double(s.count) - 0.5) < 0.05)
        #expect(Set(sim.phases) == [0.5])
    }

    @Test func thirtyInSixtyBecomesFortyOnA120HzDisplay() {
        let sim = GenSim(mode: .fps40, gameFPS: 30, displayHz: 120)
        #expect(sim.scheduler.active)
        let s = sim.settled
        #expect(s.count > 60)
        let steps = zip(s.dropFirst(), s).map { $0.content - $1.content }
        #expect(Double(steps.filter { abs($0 - 0.025) < 1e-4 }.count) / Double(steps.count) > 0.97)
        // On screen every third refresh: 25 ms.
        let onScreen = zip(s.dropFirst(), s).map { $0.at - $1.at }
        #expect(Double(onScreen.filter { abs($0 - 0.025) < 0.002 }.count) / Double(onScreen.count) > 0.9)
        #expect(Set(sim.phases).isSubset(of: [0.25, 0.5, 0.75]))
        // One real frame in four, three generated.
        #expect(abs(Double(s.filter(\.generated).count) / Double(s.count) - 0.75) < 0.05)
    }

    @Test func aGameAtTheTargetRateIsLeftAlone() {
        let sim = GenSim(mode: .fps60, gameFPS: 60, displayHz: 120)
        #expect(!sim.scheduler.active)
        #expect(sim.requestsSeen == 0)
        #expect(sim.shown.isEmpty)
        // 60 is above the 40 fps mode's rate too.
        #expect(!GenSim(mode: .fps40, gameFPS: 60, displayHz: 120).scheduler.active)
    }

    @Test func theDelayIsWhatTheEarliestGeneratedPictureWaitsFor() {
        // 30 → 60: the picture half a game frame after A waits for B, 16.7 ms, plus the margin (4…30 ms).
        let sixty = GenSim(mode: .fps60, gameFPS: 30, displayHz: 60).scheduler
        #expect(sixty.delay >= 1.0 / 60 + 0.004 - 1e-9 && sixty.delay <= 1.0 / 60 + 0.03 + 1e-9)
        // 30 → 40: the picture a quarter after A waits three quarters, 25 ms.
        let forty = GenSim(mode: .fps40, gameFPS: 30, displayHz: 120).scheduler
        #expect(forty.delay >= 0.025 + 0.004 - 1e-9 && forty.delay <= 0.025 + 0.03 + 1e-9)
    }

    @Test func twentyFpsOnlyAsksForPhasesTheInterpolatorHas() {
        let sim = GenSim(mode: .fps60, gameFPS: 20, displayHz: 60)
        #expect(sim.scheduler.active)
        #expect(Set(sim.phases) == [0.5])
        // Pictures never go back in the game's time.
        let s = sim.settled
        #expect(zip(s.dropFirst(), s).allSatisfy { $0.content > $1.content })
    }

    @Test func aStallStartsAgain() {
        let sim = GenSim(mode: .fps60, gameFPS: 30, displayHz: 60, seconds: 4, gapAt: 2)
        // Generating again after the half-second gap, with an even cadence in the last second.
        #expect(sim.scheduler.active)
        let tail = sim.shown.filter { $0.at > 4.0 }
        #expect(tail.count > 40)
        let steps = zip(tail.dropFirst(), tail).map { $0.content - $1.content }
        #expect(Double(steps.filter { abs($0 - 1.0 / 60) < 1e-4 }.count) / Double(steps.count) > 0.95)
    }

    @Test func nothingIsInterpolatedAcrossACut() {
        var s = FrameGenScheduler(outputStep: 1.0 / 60, phaseGrid: 2)
        var t = 1.0
        for i in 0..<30 { _ = s.arrived(rtp: UInt32(i * 3000), at: t, repeated: false); t += 1.0 / 30 }
        #expect(s.active)
        let normal = s.arrived(rtp: UInt32(30 * 3000), at: t, repeated: false)
        #expect(normal.requests.map(\.phase) == [0.5])
        t += 1.0 / 30
        let cut = s.arrived(rtp: UInt32(31 * 3000), at: t, repeated: false, cut: true)
        #expect(cut.requests.isEmpty)
    }

    @Test func aRepeatIsNotANewFrame() {
        var s = FrameGenScheduler(outputStep: 1.0 / 60, phaseGrid: 2)
        let first = s.arrived(rtp: 0, at: 1, repeated: false)
        let again = s.arrived(rtp: 1500, at: 1 + 1.0 / 60, repeated: true)
        #expect(again.repeated)
        #expect(again.id == first.id)
        #expect(s.lastUniqueId == first.id)
    }
}

struct LumaProbeTests {
    @Test func meanAbsoluteDifference() {
        #expect(LumaProbe.meanAbsDiff([10, 20, 30, 40], [10, 20, 30, 40]) == 0)
        #expect(LumaProbe.meanAbsDiff([10, 20, 30, 40], [12, 18, 30, 44]) == 2)
        #expect(LumaProbe.meanAbsDiff([1], [1, 2]) == .infinity)
    }

    @Test func changedSamplesCountBigStepsOnly() {
        let c = LumaProbe.compare([10, 20, 30, 40], [17, 28, 30, 140])
        #expect(c.changed == 2)   // +7 doesn't count, +8 and +100 do
    }
}

struct FrameGenQuietScreenTests {
    /// A menu whose changes are too small for the samples: every frame looks like a repeat. The screen must still
    /// update every few frames, not only when something big moves (seen on a console: once a second).
    @Test func smallChangesStillGetThrough() {
        var s = FrameGenScheduler(outputStep: 1.0 / 60, phaseGrid: 2)
        var t = 1.0, rtp: UInt32 = 0
        // A 30 fps game first, so frame generation is active when the menu opens.
        for i in 0..<60 { _ = s.arrived(rtp: rtp, at: t, repeated: i % 2 == 1); t += 1.0 / 60; rtp &+= 1500 }
        #expect(s.active)
        var uniques: [Double] = []
        for _ in 0..<60 {
            let a = s.arrived(rtp: rtp, at: t, repeated: true)
            if !a.repeated { uniques.append(a.time) }
            t += 1.0 / 60; rtp &+= 1500
        }
        // One second of "repeats": a picture goes through about every 133 ms (the first 60 Hz frame past 120 ms).
        #expect(uniques.count >= 6)
        #expect(zip(uniques.dropFirst(), uniques).allSatisfy { $0 - $1 < 0.14 })
    }
}

import CoreVideo
import CoreMedia
import Metal

/// The real interpolator on this machine: a square that moves between two frames is found halfway in the picture
/// made at phase 0.5. 40 px per frame: well inside what the model follows at 720p (measured on an M5 Max: exact up
/// to about 40 px, drifting towards B at 60–100, a cross-fade from about 120). Skipped where the system has no interpolator (older OS, some virtual machines).
struct VTFrameInterpolatorTests {
    static var available: Bool {
        if #available(macOS 26.0, iOS 26.0, *) { return VTFrameInterpolator.isSupported }
        return false
    }

    /// A full-range NV12 frame (what WebRTC's decoder gives), black with a white 80 px square at `x`.
    static func frame(squareAt x: Int, width: Int = 1280, height: Int = 720) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height { for col in 0..<width {
            y[row * yStride + col] = (col >= x && col < x + 80 && row >= 320 && row < 400) ? 235 : 16
        } }
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(height / 2) { for i in 0..<width { uv[row * uvStride + i] = 128 } }
        return buffer
    }

    /// Horizontal centre of the bright pixels in rows 320…400.
    static func centroid(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var sum = 0.0, weight = 0.0
        for row in 320..<400 { for col in 0..<CVPixelBufferGetWidth(pb) {
            let v = Double(y[row * stride + col])
            if v > 128 { sum += Double(col) * v; weight += v }
        } }
        return weight > 0 ? sum / weight : -1
    }

    @Test(.enabled(if: available)) func aMovingSquareIsFoundHalfway() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let interpolator = VTFrameInterpolator()
        let a = try Self.frame(squareAt: 200), b = try Self.frame(squareAt: 240)
        // The model loads off the caller's thread.
        var waited = 0
        while !interpolator.prepare(width: 1280, height: 720, grid: 2), waited < 100 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        let ca = try #require(interpolator.convert(a)), cb = try #require(interpolator.convert(b))
        #expect(CVPixelBufferGetPixelFormatType(ca) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cmd = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let out = try #require(interpolator.interpolate(previous: ca, previousTime: CMTime(value: 0, timescale: 90_000), source: cb,
                                                        sourceTime: CMTime(value: 3000, timescale: 90_000), phases: [0.5], cmd: cmd))
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)
        #expect(out.count == 1)
        let centre = Self.centroid(out[0])
        // Square centres: 240 in A, 280 in B; halfway is 260.
        #expect(abs(Self.centroid(ca) - 240) < 2)
        #expect(abs(centre - 260) < 4, "square found at \(centre)")
    }
}

struct FrameGenStabilityTests {
    /// 30 fps game in a 60 fps stream, `seconds` long, with `misread` returning true for frames whose repeat flag
    /// is read wrong. Returns the scheduler and how often `active` changed after it first came on.
    static func run(seconds: Double, misread: (Int) -> Bool = { _ in false }) -> (FrameGenScheduler, Int) {
        var s = FrameGenScheduler(outputStep: 1.0 / 60, phaseGrid: 2)
        var switches = 0, was = false, seen = false
        for i in 0..<Int(seconds * 60) {
            let repeated = i % 2 == 1 && !misread(i)
            _ = s.arrived(rtp: UInt32(i * 1500), at: 1 + Double(i) / 60, repeated: repeated)
            if s.active != was { if seen { switches += 1 }; seen = true; was = s.active }
        }
        return (s, switches)
    }

    @Test func oneBadEstimateDoesNotSwitchItOff() {
        // A third of a second in which every repeat reads as new (the game looks like 60 fps), as seen on a console.
        let (s, switches) = Self.run(seconds: 4) { $0 >= 120 && $0 < 140 }
        #expect(s.active)
        #expect(switches == 0)
    }

    @Test func aRealSpeedUpStillSwitchesItOff() {
        // From frame 120 on the game really runs at 60: off within about a second.
        let (s, _) = Self.run(seconds: 3) { $0 >= 120 }
        #expect(!s.active)
    }
}

struct FrameGenMarginTests {
    @Test func theMarginFollowsWhenPicturesWereReady() {
        var s = FrameGenScheduler(outputStep: 1.0 / 60, phaseGrid: 2)
        var t = 1.0
        for i in 0..<60 { _ = s.arrived(rtp: UInt32(i * 1500), at: t, repeated: i % 2 == 1); t += 1.0 / 60 }
        #expect(s.active)
        let offset = try! #require(s.offset)
        // Pictures ready 20 ms after their frame's earliest arrival, one in ten at 30 ms.
        for i in 0..<100 { s.noteReady(at: offset + 2 + (i % 10 == 0 ? 0.030 : 0.020), contentTime: 2) }
        #expect(abs(s.readyLag - 0.020) < 1e-9)
        // The 95th percentile (30 ms) + 2 ms, on top of half a game frame.
        #expect(abs(s.margin - 0.032) < 1e-9)
        #expect(abs(s.targetDelay - (1.0 / 60 + 0.032)) < 1e-6)
    }

    @Test func theMarginIsCapped() {
        var s = FrameGenScheduler(outputStep: 1.0 / 60, phaseGrid: 2)
        _ = s.arrived(rtp: 0, at: 1, repeated: false)
        let offset = try! #require(s.offset)
        for _ in 0..<20 { s.noteReady(at: offset + 0.15, contentTime: 0) }
        #expect(s.margin == 0.060)
    }
}
