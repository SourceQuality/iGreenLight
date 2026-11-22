import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import Metal

// MARK: - Scheduler

/// Decides, for frame generation, which picture is on screen at every display tick: a real frame from the stream or
/// one interpolated between two of them.
///
/// A game that runs at 30 fps usually still arrives as a 60 fps stream in which every other frame repeats the one
/// before. Only frames with new content ("unique" frames, told apart by the caller) count. They are placed on a
/// content clock (their RTP timestamps), over which lies a steady output grid at the target rate (60 or 40 Hz).
/// Each grid point between two unique frames A and B shows A, B, or an interpolated picture at the grid point's
/// phase between them, snapped to the phases the interpolator offers (halves for 60, quarters for 40).
///
/// The grid point is shown `delay` after its content time, on the clock the arrivals set. The delay is what frame
/// generation costs in latency: a picture between A and B can only be made once B is here, so the earliest grid
/// point after A has to wait for B, plus the time to make it and the network's jitter. For a 30 fps game that is
/// half a game frame (17 ms) plus that margin at 60, three quarters (25 ms) plus the margin at 40.
///
/// When the game already runs at the target rate or faster, the scheduler stands by (`active` false) and the
/// renderer draws as it does without it.
struct FrameGenScheduler {
    /// What a grid point shows: the unique frame with this id, or the picture generated for this grid index.
    enum Key: Hashable {
        case real(Int)
        case generated(Int)
    }

    /// One grid point's picture; `fallback` is shown instead while a generated picture isn't ready.
    struct Slot: Equatable {
        let show: Key
        let fallback: Key?
    }

    /// A picture to generate: at `phase` (0…1) between the previous unique frame and this one, stored as `key`.
    struct Request: Equatable {
        let key: Key
        let phase: Float
    }

    /// What an arriving frame turned out to be.
    struct Arrival: Equatable {
        /// Content time of the frame (seconds, unwrapped RTP).
        var time: Double
        /// Repeats the last unique frame (or the scheduler is standing by): nothing to place.
        var repeated: Bool
        /// Id of the unique frame (valid when not repeated).
        var id: Int
        /// Pictures to generate between the previous unique frame and this one.
        var requests: [Request]
    }

    /// No frame for this long is a stall (or the start): everything starts again from the next frame.
    static var stall: Double { 0.25 }
    /// Two unique frames further apart than this are a hitch, not motion to fill in.
    static var maxSpan: Double { 0.12 }
    /// The arrival clock is the earliest arrival over this many seconds.
    static var clockWindow: Double { 2 }

    /// Seconds between output grid points (1/60 or 1/40), and how finely the interpolator divides a span (2 or 4).
    let outputStep: Double
    let phaseGrid: Int

    private var lastRTP: UInt32?
    private var lastArrival = -Double.infinity
    /// Content time of the newest frame, in seconds.
    private var media = 0.0
    private var uniques: [(id: Int, time: Double)] = []
    private var nextId = 0
    /// (arrival, arrival − content time) of recent frames.
    private var clockSamples: [(at: Double, raw: Double)] = []
    private var plan: [Int: Slot] = [:]
    private var anchor: Double?
    private var lastK: Int?
    private var lastRelease = -Double.infinity
    private var lastTick: Double?
    private var tickSteps: [Double] = []

    /// Median time between unique frames (the game's frame time); 0 until known.
    private(set) var interval = 0.0
    /// Earliest arrival − content time over the clock window: when a frame that met no delay arrives.
    private(set) var offset: Double?
    /// 90th percentile of how much later than `offset` frames arrived.
    private(set) var jitter = 0.0
    /// Smoothed time it takes to make a generated picture, seconds.
    private(set) var cost = 0.006
    /// Content time to on-screen time, beyond the arrival clock.
    private(set) var delay = 0.0
    /// Display tick interval (median), 0 until known.
    private(set) var refresh = 0.0
    /// Generating: the game runs slower than the target.
    private(set) var active = false
    /// Grid points whose generated picture wasn't ready in time (counted by the caller via `noteLate`).
    private(set) var late = 0
    /// Id of the newest unique frame.
    var lastUniqueId: Int? { uniques.last?.id }

    init(outputStep: Double, phaseGrid: Int) {
        self.outputStep = outputStep
        self.phaseGrid = max(1, phaseGrid)
    }

    /// The delay the current estimates call for: the wait for the next unique frame from the earliest grid point
    /// that needs it (one interpolator step after A), plus jitter and the time to make the picture.
    var targetDelay: Double {
        let margin = min(max(jitter + cost + 0.002, 0.004), 0.030)
        return interval * (1 - 1 / Double(phaseGrid)) + margin
    }

    /// A decoded frame arrived. `repeated`: its picture is (nearly) the same as the last unique frame's. `cut`: it
    /// is so different that nothing should be interpolated towards it (a scene change).
    mutating func arrived(rtp: UInt32, at now: Double, repeated: Bool, cut: Bool = false) -> Arrival {
        let step = lastRTP.map { Double(Int32(truncatingIfNeeded: rtp &- $0)) / 90_000 }
        let stalled = now - lastArrival > Self.stall
        lastRTP = rtp; lastArrival = now
        var repeated = repeated
        if let step, step > 0, step < Self.stall, !stalled {
            media += step
        } else {
            // The first frame, a stall, or timestamps that stand still or jump: start again from this frame.
            restart()
            repeated = false
        }

        clockSamples.append((now, now - media))
        while let first = clockSamples.first, now - first.at > Self.clockWindow { clockSamples.removeFirst() }
        let offset = clockSamples.map(\.raw).min() ?? 0
        self.offset = offset
        let lateness = clockSamples.map { $0.raw - offset }.sorted()
        jitter = lateness[min(lateness.count - 1, Int(Double(lateness.count) * 0.9))]

        if repeated, !uniques.isEmpty { return Arrival(time: media, repeated: true, id: uniques.last!.id, requests: []) }

        let prev = uniques.last
        let id = nextId
        nextId += 1
        uniques.append((id, media))
        if uniques.count > 9 { uniques.removeFirst() }
        let steps = zip(uniques.dropFirst(), uniques).map { $0.time - $1.time }.filter { $0 > 0 && $0 < Self.maxSpan }
        interval = steps.count >= 3 ? steps.sorted()[steps.count / 2] : 0

        // Hysteresis, so a game that hovers near the target doesn't flip in and out.
        let wasActive = active
        if interval > 0 {
            if !active, interval >= outputStep * 1.25 { active = true }
            else if active, interval <= outputStep * 1.1 { active = false }
        } else {
            active = false
        }
        if !active {
            anchor = nil; lastK = nil; plan.removeAll()
            return Arrival(time: media, repeated: false, id: id, requests: [])
        }
        if !wasActive || anchor == nil {
            // The grid starts at this frame.
            anchor = media; lastK = nil; plan.removeAll()
            delay = targetDelay
            plan[0] = Slot(show: .real(id), fallback: nil)
            return Arrival(time: media, repeated: false, id: id, requests: [])
        }

        var requests: [Request] = []
        guard let anchor, let prev else { return Arrival(time: media, repeated: false, id: id, requests: []) }
        let span = media - prev.time
        let fill = span > 0 && span <= Self.maxSpan && !cut
        let q = Double(phaseGrid)
        // Grid points in (A, B]: each shows A, B or a generated picture.
        var k = Int(((prev.time - anchor) / outputStep).rounded(.down)) + 1
        while true {
            let c = anchor + Double(k) * outputStep
            if c > media + 1e-6 { break }
            let snapped = fill ? ((c - prev.time) / span * q).rounded() / q : 1
            if snapped <= 0 {
                plan[k] = Slot(show: .real(prev.id), fallback: nil)
            } else if snapped >= 1 {
                plan[k] = Slot(show: .real(id), fallback: nil)
            } else {
                let phase = Float(snapped)
                let key: Key
                if let same = requests.first(where: { $0.phase == phase }) { key = same.key } else {
                    key = .generated(k)
                    requests.append(Request(key: key, phase: phase))
                }
                plan[k] = Slot(show: key, fallback: .real(prev.id))
            }
            k += 1
        }
        return Arrival(time: media, repeated: false, id: id, requests: requests)
    }

    /// A display tick: the grid point that became due, or nil when nothing new is due (or standing by).
    mutating func due(at now: Double) -> Slot? {
        if let last = lastTick, now > last {
            tickSteps.append(now - last)
            if tickSteps.count > 9 { tickSteps.removeFirst() }
            refresh = tickSteps.sorted()[tickSteps.count / 2]
        }
        lastTick = now
        guard active, let anchor, let offset else { return nil }
        // Follow the estimates slowly: a jump in the delay is a jump in the picture.
        let target = targetDelay
        delay += max(-0.0005, min(0.0005, target - delay))
        // As in `FramePacer`: on the tick one output step after the last release a grid point may go a little
        // early, so that one due near a tick boundary doesn't flip between two ticks.
        let onCadence = now - lastRelease >= outputStep - refresh / 2
        let early = onCadence ? min(refresh / 2, outputStep / 4) : 0
        let c = now + early - offset - delay
        let k = Int(((c - anchor) / outputStep + 1e-9).rounded(.down))
        if let lastK, k <= lastK { return nil }
        lastK = k
        lastRelease = now
        for old in plan.keys where old < k { plan[old] = nil }
        if let slot = plan[k] { return slot }
        // Not planned (B is late, or just started): the newest unique frame at or before the grid point.
        let ck = anchor + Double(k) * outputStep
        if let u = uniques.last(where: { $0.time <= ck + 1e-6 }) { return Slot(show: .real(u.id), fallback: nil) }
        return nil
    }

    /// A generated picture took this long from request to done.
    mutating func noteCost(_ seconds: Double) {
        guard seconds > 0, seconds < 0.1 else { return }
        cost += (seconds - cost) * 0.1
    }

    /// A grid point's generated picture wasn't ready when it was due.
    mutating func noteLate() { late += 1 }

    private mutating func restart() {
        uniques.removeAll()
        clockSamples.removeAll()
        plan.removeAll()
        anchor = nil; lastK = nil
        interval = 0
        active = false
        media = 0
    }
}

// MARK: - Repeated frames

/// Sparse luma samples of a frame, for telling a repeated frame from new content and a scene cut from motion.
enum LumaProbe {
    static let columns = 64, rows = 36
    /// Mean absolute luma difference (8-bit code values) at or below which a frame repeats the last one. A
    /// repeated frame the encoder sends as a skip decodes to the same pixels; one it refines differs by a little.
    static let repeatThreshold = 0.75
    /// At or above this the frame is a cut: interpolating towards it would only blend two pictures.
    static let cutThreshold = 40.0

    /// `columns` × `rows` luma samples (8-bit; the top byte of a 10-bit plane), nil for an unsupported buffer.
    static func sample(_ pb: CVPixelBuffer) -> [UInt8]? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let bytesPerSample: Int
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: bytesPerSample = 1
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: bytesPerSample = 2
        default: return nil
        }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w >= columns, h >= rows else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: columns * rows)
        for r in 0..<rows {
            let y = (2 * r + 1) * h / (2 * rows)
            for c in 0..<columns {
                let x = (2 * c + 1) * w / (2 * columns)
                // Little-endian 16-bit samples hold the value in the top bits: the high byte is the 8-bit value.
                out[r * columns + c] = bytes[y * stride + x * bytesPerSample + (bytesPerSample - 1)]
            }
        }
        return out
    }

    static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0
        for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}

// MARK: - Interpolator

#if !targetEnvironment(simulator)
/// Apple's ML frame interpolation, `VTLowLatencyFrameInterpolation` (macOS 26+ / iOS 26+).
///
/// It takes two frames and makes pictures between them at phases on a grid of (2^n − 1) points: n = 1 offers 0.5
/// (enough for 30 → 60), n = 2 offers 0.25, 0.5 and 0.75 (30 → 40). Sources up to 1920 × 1080 (asked of the system
/// on macOS 27+), `420v` only. On an M5 Max at 1080p one picture takes 8.6 ms with n = 1 and 17 ms with n = 2;
/// at 720p, 3 and 6 ms.
///
/// As with `VTSuperResolution`, a session loads a model, which can take longer than a frame, so it is started off
/// the frame's path; until it is ready nothing is generated.
@available(macOS 26.0, iOS 26.0, *)
final class VTFrameInterpolator: @unchecked Sendable {
    struct Key: Hashable { let width: Int; let height: Int; let grid: Int }

    private final class Session {
        let key: Key
        let processor = VTFrameProcessor()
        var srcPool: CVPixelBufferPool?
        var dstPool: CVPixelBufferPool?
        var transfer: VTPixelTransferSession?
        var ready = false
        init(key: Key) { self.key = key }
    }

    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    /// Largest source the interpolator takes: longest side and pixel count.
    static var limits: (dimension: Int, pixels: Int) {
        if #available(macOS 27.0, iOS 27.0, *),
           let d = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1),
           let p = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1), d > 0, p > 0 {
            return (d, p)
        }
        return (1920, 1920 * 1080)
    }

    static func supports(width: Int, height: Int) -> Bool {
        let l = limits
        return max(width, height) <= l.dimension && width * height <= l.pixels
    }

    private let lock = NSLock()
    private var session: Session?
    private var pendingKey: Key?
    private var failedKeys = Set<Key>()
    private let setupQueue = DispatchQueue(label: "app.igreenlight.vtfi", qos: .userInitiated)
    private(set) var lastStatus = "off"

    /// True when a session for this size and grid is ready; otherwise starts one and returns false.
    func prepare(width: Int, height: Int, grid: Int) -> Bool {
        let key = Key(width: width, height: height, grid: grid)
        lock.lock()
        let isReady = session?.key == key && session?.ready == true
        let failed = failedKeys.contains(key)
        if !isReady, pendingKey != key, !failed {
            pendingKey = key
            setupQueue.async { [weak self] in self?.startSession(key) }
        }
        lock.unlock()
        if !isReady { lastStatus = failed ? "failed for \(width)x\(height)" : "loading model for \(width)x\(height)…" }
        return isReady
    }

    /// The decoder's buffer in the format and memory the interpolator takes (WebRTC's decoder gives 420f).
    func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock(); let s = session; lock.unlock()
        guard let s, s.ready, let transfer = s.transfer, let out = Self.buffer(from: s.srcPool) else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: out) == noErr else { return nil }
        CVBufferPropagateAttachments(source, out)
        return out
    }

    /// Encodes pictures at `phases` between `previous` and `source` (both from `convert`) into `cmd`.
    func interpolate(previous: CVPixelBuffer, previousTime: CMTime, source: CVPixelBuffer, sourceTime: CMTime,
                     phases: [Float], cmd: MTLCommandBuffer) -> [CVPixelBuffer]? {
        lock.lock(); let s = session; lock.unlock()
        guard let s, s.ready, !phases.isEmpty else { return nil }
        let span = CMTimeSubtract(sourceTime, previousTime)
        var outputs: [CVPixelBuffer] = [], frames: [VTFrameProcessorFrame] = []
        for p in phases {
            guard let pb = Self.buffer(from: s.dstPool) else { return nil }
            CVBufferPropagateAttachments(source, pb)
            let t = CMTimeAdd(previousTime, CMTimeMultiplyByFloat64(span, multiplier: Double(p)))
            guard let f = VTFrameProcessorFrame(buffer: pb, presentationTimeStamp: t) else { return nil }
            outputs.append(pb); frames.append(f)
        }
        guard let prev = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousTime),
              let src = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: sourceTime),
              let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: src, previousFrame: prev, interpolationPhase: phases,
                                                                    destinationFrames: frames) else { return nil }
        s.processor.process(with: cmd, parameters: params)
        lastStatus = "\(s.key.width)x\(s.key.height)"
        return outputs
    }

    private func startSession(_ key: Key) {
        let t0 = Date()
        let s = Session(key: key)
        if let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: key.width, frameHeight: key.height,
                                                                 numberOfInterpolatedFrames: key.grid == 4 ? 2 : 1) {
            do {
                try s.processor.startSession(configuration: cfg)
                s.srcPool = Self.pool(cfg.sourcePixelBufferAttributes)
                s.dstPool = Self.pool(cfg.destinationPixelBufferAttributes)
                VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s.transfer)
                s.ready = s.srcPool != nil && s.dstPool != nil && s.transfer != nil
                log("Render", "VT frame interpolation ready for \(key.width)x\(key.height), \(key.grid == 4 ? "quarter" : "half") phases, in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
            } catch {
                log("Render", "VT frame interpolation session failed for \(key): \(error)")
            }
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
        // Enough for the pictures waiting to be shown, the one on screen and the one being made.
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private static func buffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
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
#else
/// The Simulator SDK doesn't ship the interpolator.
@available(macOS 26.0, iOS 26.0, *)
final class VTFrameInterpolator: @unchecked Sendable {
    static var isSupported: Bool { false }
    static var limits: (dimension: Int, pixels: Int) { (0, 0) }
    static func supports(width: Int, height: Int) -> Bool { false }
    let lastStatus = "not available in the Simulator"
    func prepare(width: Int, height: Int, grid: Int) -> Bool { false }
    func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? { nil }
    func interpolate(previous: CVPixelBuffer, previousTime: CMTime, source: CVPixelBuffer, sourceTime: CMTime,
                     phases: [Float], cmd: MTLCommandBuffer) -> [CVPixelBuffer]? { nil }
    func reset() {}
}
#endif
