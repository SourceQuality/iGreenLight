import Foundation
import WebRTC

/// RTCPeerConnection wrapper (Greenlight player.ts + sdp.ts + ice.ts).
final class WebRTCClient: NSObject, RTCPeerConnectionDelegate {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    let pc: RTCPeerConnection
    let queue = DispatchQueue(label: "app.igreenlight.webrtc")
    let control: ControlChannel
    let input: InputChannel
    let message: MessageChannel
    let chat: ChatChannel

    var onVideoTrack: ((RTCVideoTrack) -> Void)?
    var onAudioTrack: ((RTCAudioTrack) -> Void)?
    var onIceState: ((RTCIceConnectionState) -> Void)?
    var onConnectionState: ((RTCPeerConnectionState) -> Void)?

    private var localCandidates: [RTCIceCandidate] = []
    private var gatheringDone: CheckedContinuation<Void, Never>?
    private var gatheringComplete = false
    private let lock = NSLock()

    override init() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        config.continualGatheringPolicy = .gatherOnce
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = WebRTCClient.factory
        // The delegate is set right after super.init().
        pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!

        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .sendRecv
        pc.addTransceiver(of: .audio, init: audioInit)
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        if let video = pc.addTransceiver(of: .video, init: videoInit) {
            let prefs = WebRTCClient.videoCodecPreferences()
            if let err = WebRTCClient.setCodecPreferences(video, prefs) {
                log("WebRTC", "setCodecPreferences failed: \(err)")
            } else {
                log("WebRTC", "video codec order: \(prefs.map { "\($0.name) \($0.parameters["profile-level-id"] ?? "")" })")
            }
        }

        // Channels must exist before the offer so they're in the SDP.
        control = ControlChannel(pc: pc, queue: queue)
        input = InputChannel(pc: pc, queue: queue)
        message = MessageChannel(pc: pc, queue: queue)
        chat = ChatChannel(pc: pc, queue: queue)
        super.init()
        pc.delegate = self
    }

    /// Calls `-setCodecPreferences:error:` directly; Swift otherwise resolves to the deprecated non-throwing overload.
    static func setCodecPreferences(_ t: RTCRtpTransceiver, _ codecs: [RTCRtpCodecCapability]) -> NSError? {
        typealias Fn = @convention(c) (AnyObject, Selector, NSArray, UnsafeMutablePointer<NSError?>?) -> Bool
        let sel = NSSelectorFromString("setCodecPreferences:error:")
        guard let imp = t.method(for: sel) else { return NSError(domain: "WebRTC", code: -1) }
        var err: NSError?
        let ok = unsafeBitCast(imp, to: Fn.self)(t, sel, codecs as NSArray, &err)
        return ok ? nil : (err ?? NSError(domain: "WebRTC", code: -2))
    }

    /// H.264 High (4d) → constrained baseline (42e) → baseline (420), then FEC / VP9 / VP8 (Greenlight sdp.ts).
    static func videoCodecPreferences() -> [RTCRtpCodecCapability] {
        let caps = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        var t1: [RTCRtpCodecCapability] = [], t2: [RTCRtpCodecCapability] = [], t3: [RTCRtpCodecCapability] = [], t4: [RTCRtpCodecCapability] = []
        for c in caps {
            let name = c.name.lowercased()
            let plid = (c.parameters["profile-level-id"] ?? "").lowercased()
            if name == "h264" {
                if plid.hasPrefix("4d") { t1.append(c) } else if plid.hasPrefix("42e") { t2.append(c) } else if plid.hasPrefix("420") { t3.append(c) }
            } else if ["ulpfec", "flexfec-03", "flexfec", "vp9", "vp8"].contains(name) {
                t4.append(c)
            }
        }
        return t1 + t2 + t3 + t4
    }

    func createOffer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
                                              optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, err in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: err ?? URLError(.unknown)) }
            }
        }
        // Greenlight sdp.ts: ask for stereo Opus.
        let munged = offer.sdp.replacingOccurrences(of: "useinbandfec=1", with: "useinbandfec=1;stereo=1")
        let local = RTCSessionDescription(type: .offer, sdp: munged)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(local) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
        return munged
    }

    func setRemoteAnswer(_ sdp: String) async throws {
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(desc) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
        // Unified plan: tracks may already be available on the transceivers.
        for t in pc.transceivers {
            if let v = t.receiver.track as? RTCVideoTrack { onVideoTrack?(v) }
            if let a = t.receiver.track as? RTCAudioTrack { onAudioTrack?(a) }
        }
    }

    /// Waits until ICE gathering completes (or a timeout), returns local candidates.
    func gatheredCandidates(timeout: TimeInterval = 3) async -> [RTCIceCandidate] {
        lock.lock()
        let done = gatheringComplete
        lock.unlock()
        if !done {
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await withCheckedContinuation { c in self.lock.lock(); if self.gatheringComplete { self.lock.unlock(); c.resume() } else { self.gatheringDone = c; self.lock.unlock() } } }
                g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) }
                await g.next()
                g.cancelAll()
                self.finishGathering()
            }
        }
        lock.lock(); defer { lock.unlock() }
        return localCandidates
    }

    private func finishGathering() {
        lock.lock()
        gatheringComplete = true
        let c = gatheringDone
        gatheringDone = nil
        lock.unlock()
        c?.resume()
    }

    func addRemoteCandidate(_ sdp: String, mid: String?, index: Int32) async {
        let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pc.add(cand) { err in
                if let err { log("ICE", "addIceCandidate failed for \(sdp): \(err.localizedDescription)") }
                c.resume()
            }
        }
    }

    func stats() async -> RTCStatisticsReport {
        await withCheckedContinuation { c in pc.statistics { c.resume(returning: $0) } }
    }

    func close() {
        for ch in [control, input, message, chat] as [DataChannel] { ch.close() }
        pc.close()
    }

    // MARK: RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        log("WebRTC", "signaling state \(stateChanged.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log("WebRTC", "ICE connection state \(newState.rawValue)")
        onIceState?(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log("WebRTC", "ICE gathering state \(newState.rawValue)")
        if newState == .complete { finishGathering() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock(); localCandidates.append(candidate); lock.unlock()
        log("ICE", "local candidate: \(candidate.sdp)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log("WebRTC", "remote opened data channel \(dataChannel.label)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        log("WebRTC", "connection state \(newState.rawValue)")
        onConnectionState?(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let v = rtpReceiver.track as? RTCVideoTrack { log("WebRTC", "video track"); onVideoTrack?(v) }
        if let a = rtpReceiver.track as? RTCAudioTrack { log("WebRTC", "audio track"); onAudioTrack?(a) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate, remoteCandidate remote: RTCIceCandidate, lastReceivedMs: Int32, changeReason reason: String) {
        log("ICE", "selected pair: local \(local.sdp) <-> remote \(remote.sdp) (\(reason))")
    }
}
