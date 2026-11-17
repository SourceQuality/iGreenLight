import Foundation
import WebRTC

struct StreamTarget: Hashable, Codable, Identifiable {
    enum Kind: String, Codable { case home, cloud }
    let kind: Kind
    let id: String       // serverId (home) or titleId (cloud)
    let name: String
}

/// One Remote Play / xCloud session. Port of Greenlight's stream page + streammanager + player flow.
@MainActor
final class StreamSession: ObservableObject {
    enum Phase: Equatable {
        case starting
        case provisioning(String)
        case queued(String)
        case connecting(String)
        case streaming
        case ended(String)
        case failed(String)

        var isTerminal: Bool { if case .ended = self { return true }; if case .failed = self { return true }; return false }
    }

    struct Dialog: Identifiable { let id: String; let title: String; let text: String; let buttons: [String] }

    @Published var phase: Phase = .starting
    @Published var stats = StreamStats()
    @Published var dialog: Dialog?
    @Published var serverVideoSize: (Int, Int)?
    @Published var decodedSize: (Int, Int)?

    let target: StreamTarget
    let renderer = MetalVideoRenderer()
    let keyboard = KeyboardInput()
    private let auth: AuthManager
    private let settings = AppSettings.shared
    private var api: SessionAPI?
    private var rtc: WebRTCClient?
    private var runTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var inputTimer: DispatchSourceTimer?
    private var attachedVideo = false
    private var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?
    private var stopped = false
    private var statsSampler = StatsSampler()

    init(target: StreamTarget, auth: AuthManager) {
        self.target = target
        self.auth = auth
        renderer.scaling = settings.scaling
        renderer.useMetalFX = settings.metalFX
        renderer.onFrameSize = { [weak self] w, h in self?.decodedSize = (w, h) }
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    private func run() async {
        do {
            let cloud = target.kind == .cloud
            let token = try await auth.streamToken(cloud: cloud)
            let base = auth.baseURL(cloud: cloud, token: token)
            let size = settings.requestedSize
            let deviceInfo = DeviceInfo.header(quality: settings.quality, width: size.width, height: size.height)
            log("Stream", "Starting \(target.kind.rawValue) session for \(target.name) on \(base), quality \(settings.quality.label) (os \(settings.quality.osName)), requesting \(size.width)x\(size.height)")
            var api = SessionAPI(baseURL: base, gsToken: token.gsToken, kind: cloud ? .cloud : .home, deviceInfo: deviceInfo)
            phase = .provisioning("Starting session…")
            _ = try await api.play(target: target.id, locale: settings.locale, osName: settings.quality.osName)
            self.api = api

            try await waitForProvisioned(api)
            if stopped { return }

            // Better xCloud: the session configuration includes the console's own address.
            var extra: [(String, Int)] = []
            if let cfg = try? await api.configuration() {
                log("Stream", "configuration: \(cfg)")
                if settings.consoleAddressCandidate, let sd = cfg["serverDetails"] as? [String: Any] {
                    extra = extraCandidates(sd)
                }
            }

            phase = .connecting("Negotiating WebRTC…")
            let rtc = WebRTCClient()
            self.rtc = rtc
            wire(rtc)
            let offer = try await rtc.createOffer()
            let answer = try await api.exchangeSDP(offer: offer)
            log("Stream", "SDP answer received (\(answer.count) bytes)")
            try await rtc.setRemoteAnswer(answer)

            phase = .connecting("Exchanging ICE candidates…")
            let local = await rtc.gatheredCandidates()
            var payload: [[String: Any]] = local.map { ["candidate": "a=" + $0.sdp, "sdpMid": $0.sdpMid ?? "0", "sdpMLineIndex": $0.sdpMLineIndex] }
            payload.append(["candidate": "a=end-of-candidates", "sdpMid": "0", "sdpMLineIndex": 0])
            let remote = try await api.exchangeICE(payload)
            log("Stream", "remote ICE: \(remote)")
            await addRemoteCandidates(remote, extra: extra, rtc: rtc)

            phase = .connecting("Connecting to \(cloud ? "xCloud" : "console")…")
            startKeepalive()
            startStats()
        } catch is CancellationError {
        } catch {
            log("Stream", "Session failed: \(error)")
            fail(error.localizedDescription)
        }
    }

    private func waitForProvisioned(_ api: SessionAPI) async throws {
        var sentConnect = false
        var fetchedWait = false
        while !stopped {
            let s = try await api.state()
            let state = s["state"] as? String ?? "?"
            switch state {
            case "Provisioned":
                log("Stream", "Provisioned")
                return
            case "ReadyToConnect":
                if !sentConnect {
                    sentConnect = true
                    phase = .provisioning("Authorizing with console…")
                    let t = try await auth.transferToken()
                    try await api.connect(userToken: t)
                    log("Stream", "sent /connect transfer token")
                }
            case "WaitingForResources":
                if !fetchedWait, target.kind == .cloud {
                    fetchedWait = true
                    if let w = try? await api.waitTime(titleId: target.id), let secs = w["estimatedTotalWaitTimeInSeconds"] as? Int {
                        phase = .queued("In queue — about \(max(1, secs / 60)) min")
                    } else { phase = .queued("Waiting for a server…") }
                }
            case "Failed":
                let details = s["errorDetails"] as? [String: Any]
                throw HTTPError(status: 0, url: "state", body: (details?["message"] as? String) ?? (details?["code"] as? String) ?? "Session failed: \(s)")
            default:
                phase = .provisioning(state == "Provisioning" ? "Waking up \(target.kind == .home ? "console" : "server")…" : state)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func extraCandidates(_ sd: [String: Any]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        func port(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap(Int.init) }
        if let ip = sd["ipV4Address"] as? String, ICEHelper.isIPv4(ip), let p = port(sd["ipV4Port"]), p > 0 { out.append((ip, p)) }
        if let ip = sd["ipAddress"] as? String, ICEHelper.isIPv4(ip) {
            if let p = port(sd["port"]), p > 0 { out.append((ip, p)) }
            out.append((ip, 9002))
        }
        var seen = Set<String>()
        out = out.filter { seen.insert("\($0.0):\($0.1)").inserted }
        log("ICE", "console address candidates from serverDetails: \(out)")
        return out
    }

    private func addRemoteCandidates(_ remote: [[String: Any]], extra: [(String, Int)], rtc: WebRTCClient) async {
        var foundation = 10
        var defaultMid = "0"
        var defaultIndex: Int32 = 0
        for c in remote {
            guard let raw = c["candidate"] as? String else { continue }
            if raw.contains("end-of-candidates") { continue }
            let mid = (c["sdpMid"] as? String) ?? (c["sdpMid"] as? Int).map(String.init) ?? "0"
            let index = Int32((c["sdpMLineIndex"] as? Int) ?? Int((c["sdpMLineIndex"] as? String) ?? "0") ?? 0)
            defaultMid = mid; defaultIndex = index
            let sdp = ICEHelper.stripPrefix(raw)
            let parts = sdp.split(separator: " ")
            if parts.count > 4, parts[4].hasPrefix("2001"), let t = ICEHelper.teredo(String(parts[4])) {
                log("ICE", "Teredo \(parts[4]) -> \(t.ip):\(t.port)")
                await rtc.addRemoteCandidate(ICEHelper.hostCandidate(foundation: foundation, ip: t.ip, port: 9002), mid: mid, index: index)
                await rtc.addRemoteCandidate(ICEHelper.hostCandidate(foundation: foundation + 1, ip: t.ip, port: t.port), mid: mid, index: index)
                foundation += 2
            }
            await rtc.addRemoteCandidate(sdp, mid: mid, index: index)
        }
        for (ip, port) in extra {
            await rtc.addRemoteCandidate(ICEHelper.hostCandidate(foundation: foundation, ip: ip, port: port), mid: defaultMid, index: defaultIndex)
            foundation += 1
        }
    }

    // MARK: WebRTC wiring
    private func wire(_ rtc: WebRTCClient) {
        let renderer = self.renderer
        rtc.onVideoTrack = { [weak self] track in
            Task { @MainActor in
                guard let self, !self.attachedVideo else { return }
                self.attachedVideo = true
                // RTCVideoTrack removes its renderers in dealloc, so keep the wrapper alive.
                self.videoTrack = track
                track.add(renderer)
                log("Stream", "video track attached to Metal renderer")
            }
        }
        rtc.onAudioTrack = { [weak self] track in
            track.isEnabled = true
            Task { @MainActor in self?.audioTrack = track }
        }
        rtc.onIceState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .connected, .completed:
                    if case .connecting = self.phase { self.phase = .streaming }
                case .failed:
                    self.fail("Could not connect (ICE failed). Check that the console is reachable and Remote Play is enabled.")
                case .disconnected:
                    log("Stream", "ICE disconnected (may recover)")
                default: break
                }
            }
        }
        rtc.onConnectionState = { [weak self] state in
            Task { @MainActor in
                if state == .closed || state == .failed, let self, !self.phase.isTerminal, !self.stopped {
                    self.fail("Connection closed")
                }
            }
        }

        rtc.message.requestedSize = settings.requestedSize
        rtc.message.onHandshake = { [weak rtc, weak self] in
            guard let rtc else { return }
            rtc.control.sendAuthorization()
            rtc.control.gamepadChanged(index: 0, added: true)
            rtc.input.sendClientMetadata()
            Task { @MainActor in self?.startInputLoop() }
        }
        rtc.message.onServerDisconnect = { [weak self] in
            Task { @MainActor in self?.end("The \(self?.target.kind == .home ? "console" : "server") ended the session.") }
        }
        rtc.message.onDialog = { [weak self] id, title, text, buttons in
            Task { @MainActor in self?.dialog = Dialog(id: id, title: title, text: text, buttons: buttons) }
        }
        rtc.input.onVibration = { v in GamepadInput.shared.vibrate(v) }
        rtc.input.onServerVideoSize = { [weak self] w, h in
            Task { @MainActor in
                self?.serverVideoSize = (w, h)
                let req = AppSettings.shared.requestedSize
                log("Stream", "server reports video \(w)x\(h); we requested \(req.width)x\(req.height)")
            }
        }
        rtc.control.onOpen = { log("Stream", "control channel open") }
    }

    func answerDialog(_ d: Dialog, result: Int) {
        rtc?.queue.async { [rtc] in rtc?.message.completeTransaction(d.id, ["Result": result]) }
        dialog = nil
    }

    // MARK: Input
    private func startInputLoop() {
        guard inputTimer == nil, let rtc else { return }
        keyboard.mkbMode = false
        keyboard.onKeyboardFrame = { [weak rtc] k in rtc?.queue.async { rtc?.input.send(keyboard: [k]) } }
        keyboard.start()
        let pump = InputPump(rtc: rtc, keyboard: keyboard)
        let timer = DispatchSource.makeTimerSource(queue: rtc.queue)
        // Poll at 250 Hz; send on change, with a 16 ms heartbeat (Greenlight loops every 16 ms).
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        timer.setEventHandler { pump.tick() }
        timer.resume()
        inputTimer = timer
    }

    func requestKeyframe() { rtc?.queue.async { [rtc] in rtc?.control.requestKeyframe() } }

    func sendGuideButton() { keyboard.tap("nexus") }

    // MARK: Keepalive & stats
    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let api = self.api else { return }
                do { try await api.keepalive() } catch { log("Stream", "keepalive failed: \(error.localizedDescription)") }
            }
        }
    }

    private func startStats() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let rtc = self.rtc else { return }
                let report = await rtc.stats()
                var s = self.statsSampler.sample(report)
                s.metalFX = self.renderer.metalFXActive
                s.serverSize = self.serverVideoSize.map { "\($0.0)x\($0.1)" }
                self.stats = s
            }
        }
    }

    func applySettings() {
        renderer.scaling = settings.scaling
        renderer.useMetalFX = settings.metalFX
    }

    // MARK: Teardown
    private func fail(_ msg: String) {
        guard !phase.isTerminal else { return }
        phase = .failed(msg)
        teardown()
    }

    private func end(_ msg: String) {
        guard !phase.isTerminal else { return }
        phase = .ended(msg)
        teardown()
    }

    func stop() {
        guard !stopped else { return }
        log("Stream", "Stopping session")
        if !phase.isTerminal { phase = .ended("Disconnected") }
        teardown()
    }

    private func teardown() {
        stopped = true
        runTask?.cancel()
        keepaliveTask?.cancel()
        statsTask?.cancel()
        inputTimer?.cancel(); inputTimer = nil
        keyboard.stop()
        if let t = videoTrack { t.remove(renderer) }
        videoTrack = nil; audioTrack = nil
        if let rtc {
            rtc.queue.async { rtc.control.gamepadChanged(index: 0, added: false) }
            rtc.queue.asyncAfter(deadline: .now() + 0.2) { rtc.close() }
        }
        let api = self.api
        Task.detached { await api?.stop() }
    }
}
