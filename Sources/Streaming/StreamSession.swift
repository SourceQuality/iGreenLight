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
    @Published var diagnosticsLines: [String] = []
    private(set) var recorder: DiagnosticsRecorder?

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
        renderer.upscaler = settings.upscaler
        renderer.deband = settings.deband
        renderer.ambient = settings.ambientBars
        renderer.edr = settings.edrExpansion
        renderer.onFrameSize = { [weak self] w, h in self?.decodedSize = (w, h) }
    }

    func start() {
        guard runTask == nil else { return }
        Self.live.add(self)
        runTask = Task { await run() }
    }

    private func run() async {
        do {
            let cloud = target.kind == .cloud
            let token = try await auth.streamToken(cloud: cloud)
            let base = auth.baseURL(cloud: cloud, token: token)
            let size = settings.requestedSize
            let osName = settings.osName
            let deviceInfo = DeviceInfo.header(osName: osName, sdk: settings.sdkProfile, width: size.width, height: size.height)
            log("Stream", "Starting \(target.kind.rawValue) session for \(target.name) on \(base), quality \(settings.quality.label) (os \(osName)), requesting \(size.width)x\(size.height)")
            if settings.diagnosticsEnabled, recorder == nil {
                recorder = DiagnosticsRecorder(meta: ["target": "\(target.kind.rawValue): \(target.name)", "host": URL(string: base)?.host ?? base,
                                                      "settings": settings.experimentalSnapshot, "deviceInfo": deviceInfo])
                DiagnosticsRecorder.current = recorder
            }
            var api = SessionAPI(baseURL: base, gsToken: token.gsToken, kind: cloud ? .cloud : .home, deviceInfo: deviceInfo)
            phase = .provisioning("Starting session…")
            _ = try await api.play(target: target.id, locale: settings.locale, osName: osName)
            self.api = api
            if stopped {
                // Closed while the play request was in flight: teardown ran before there was a session to delete.
                Self.deleteOnServer(api)
                return
            }

            try await waitForProvisioned(api)
            try checkActive()

            // Better xCloud: the session configuration includes the console's own address.
            var extra: [(String, Int)] = []
            if let cfg = try? await api.configuration() {
                // Redacted: the response carries the SRTP key, and the log is readable outside the app.
                log("Stream", "configuration: \(Redact.value(cfg))")
                if settings.consoleAddressCandidate, let sd = cfg["serverDetails"] as? [String: Any] {
                    extra = extraCandidates(sd)
                }
            }
            try checkActive()

            phase = .connecting("Negotiating WebRTC…")
            let rtc = WebRTCClient(options: .init(codec: settings.codecPreference, onlyPreferredCodec: settings.codecOnlyPreferred,
                                                  maxVideoBitrateKbps: settings.maxVideoBitrateKbps))
            self.rtc = rtc
            wire(rtc)
            let offer = try await rtc.createOffer()
            try checkActive()
            recorder?.recordSDP(offer: offer)
            let answer = try await api.exchangeSDP(offer: offer)
            try checkActive()
            recorder?.recordSDP(answer: answer)
            log("Stream", "SDP answer received (\(answer.count) bytes)")
            try await rtc.setRemoteAnswer(answer)
            try checkActive()

            phase = .connecting("Exchanging ICE candidates…")
            let local = await rtc.gatheredCandidates()
            try checkActive()
            var payload: [[String: Any]] = local.map { ["candidate": "a=" + $0.sdp, "sdpMid": $0.sdpMid ?? "0", "sdpMLineIndex": $0.sdpMLineIndex] }
            payload.append(["candidate": "a=end-of-candidates", "sdpMid": "0", "sdpMLineIndex": 0])
            let remote = try await api.exchangeICE(payload)
            try checkActive()
            log("Stream", "remote ICE: \(remote)")
            await addRemoteCandidates(remote, extra: extra, rtc: rtc)
            try checkActive()

            // ICE can connect while the candidates above are still being added; don't put the card back over the picture.
            if case .connecting = phase { phase = .connecting("Connecting to \(cloud ? "xCloud" : "console")…") }
            startKeepalive()
            startStats()
        } catch is CancellationError {
        } catch {
            // Stopping cancels the request in flight, which surfaces as URLError.cancelled, not a failure.
            if stopped { return }
            log("Stream", "Session failed: \(error)")
            fail(error.localizedDescription)
        }
    }

    /// `run()` calls this after every suspension point: once the session is stopped (or failed) nothing
    /// further may touch `phase` or start connections, timers or tasks.
    private func checkActive() throws {
        if stopped || Task.isCancelled { throw CancellationError() }
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
                guard let self, !self.stopped, !self.attachedVideo else { return }
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
        let home = target.kind == .home, alias = settings.quality.resolutionAlias
        rtc.message.onHandshake = { [weak rtc, weak self] in
            guard let rtc else { return }
            rtc.control.sendAuthorization()
            rtc.control.gamepadChanged(index: 0, added: true)
            rtc.input.sendClientMetadata()
            // Home consoles ignore the os.name profile and always start at 1440p; this is the control that works.
            if home { rtc.control.requestResolution(alias) }
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
        guard !stopped, inputTimer == nil, let rtc else { return }
        GamepadInput.shared.holdUntilReleased()
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

    /// Quality changed during the stream. Remote Play: ask the console for that tier now (the same control
    /// message as at the handshake). Cloud picks its profile when the session starts, so it applies next time.
    func applyQuality() {
        guard target.kind == .home else { return }
        let alias = settings.quality.resolutionAlias
        log("Stream", "quality changed to \(settings.quality.label); requesting \(alias)")
        recorder?.event("resolution.userRequested", ["alias": alias])
        belowTargetSeconds = 0
        holdAttempts = 0
        holdLastRequest = Date()
        rtc?.queue.async { [rtc] in rtc?.control.requestResolution(alias) }
    }

    func requestKeyframe() { rtc?.queue.async { [rtc] in rtc?.control.requestKeyframe() } }

    func sendGuideButton() { keyboard.tap("nexus") }

    // MARK: Keepalive & stats
    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, let api = self.api else { return }
                do { try await api.keepalive() } catch { log("Stream", "keepalive failed: \(error.localizedDescription)") }
            }
        }
    }

    private func startStats() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, let rtc = self.rtc else { return }
                let report = await rtc.stats()
                if let rec = self.recorder {
                    rec.recordStats(report)
                    self.diagnosticsLines = rec.liveLines
                }
                self.recoverFromFreeze(report)
                self.holdResolution()
                var s = self.statsSampler.sample(report)
                s.upscale = self.renderer.upscaleStatus
                s.serverSize = self.serverVideoSize.map { "\($0.0)x\($0.1)" }
                self.stats = s
            }
        }
    }

    /// Video packets keep arriving but no frame was decoded for a whole second: the decoder lost its reference.
    /// Ask for a keyframe (the console answers within about a second), at most once every 2 s.
    private func recoverFromFreeze(_ report: RTCStatisticsReport) {
        guard let v = report.statistics.values.first(where: { $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video" })?.values,
              let decoded = (v["framesDecoded"] as? NSNumber)?.doubleValue,
              let bytes = (v["bytesReceived"] as? NSNumber)?.doubleValue else { return }
        defer { freezeLast = (decoded, bytes) }
        guard let last = freezeLast, decoded > 0 else { return }
        if decoded == last.decoded, bytes - last.bytes > 20_000, Date().timeIntervalSince(freezeLastRequest) > 2 {
            freezeLastRequest = Date()
            log("Stream", "video frozen with data still arriving; requesting a keyframe")
            recorder?.event("freeze.keyframeRequested")
            requestKeyframe()
        }
    }
    private var freezeLast: (decoded: Double, bytes: Double)?
    private var freezeLastRequest = Date.distantPast

    func applySettings() {
        renderer.scaling = settings.scaling
        renderer.upscaler = settings.upscaler
        renderer.deband = settings.deband
        renderer.ambient = settings.ambientBars
        renderer.edr = settings.edrExpansion
    }

    /// The console lowers the stream resolution by itself (static screens, low bitrate). When it has stayed below
    /// the Quality setting for 5 s, ask for that tier again — at most once every 15 s. Remote Play only.
    private func holdResolution() {
        guard settings.holdResolution, target.kind == .home, let h = decodedSize?.1, h > 0 else { return }
        if h >= settings.quality.height { belowTargetSeconds = 0; holdAttempts = 0; return }
        belowTargetSeconds += 1
        // A console that never reaches the tier (it can't, or the link can't carry it) isn't asked for ever.
        guard holdAttempts < Self.holdMaxAttempts, belowTargetSeconds >= 5, Date().timeIntervalSince(holdLastRequest) > 15 else { return }
        holdLastRequest = Date()
        holdAttempts += 1
        let alias = settings.quality.resolutionAlias
        if holdAttempts == Self.holdMaxAttempts { log("Stream", "last attempt to hold \(settings.quality.label); the console keeps going back to \(h)p") }
        log("Stream", "stream at \(h)p, below the \(settings.quality.label) setting; requesting \(alias) again")
        recorder?.event("resolution.rerequested", ["decodedHeight": h, "alias": alias])
        rtc?.queue.async { [rtc] in rtc?.control.requestResolution(alias) }
    }
    private var belowTargetSeconds = 0
    /// Re-requests since the stream last reached the tier (or the Quality setting changed).
    private var holdAttempts = 0
    private static let holdMaxAttempts = 3
    private var holdLastRequest = Date.distantPast

    // MARK: Teardown
    private func fail(_ msg: String) {
        guard !phase.isTerminal else { return }
        phase = .failed(msg)
        recorder?.event("failed", ["message": msg])
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
        if let rec = recorder {
            let reason: String
            switch phase {
            case .ended(let m): reason = "ended: \(m)"
            case .failed(let m): reason = "failed: \(m)"
            default: reason = "stopped"
            }
            recorder = nil
            // Keep capturing for a moment so the session DELETE and the last stats land, then close the run.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if DiagnosticsRecorder.current === rec { DiagnosticsRecorder.current = nil }
                rec.finish(reason: reason)
            }
        }
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
        if let api { Self.deleteOnServer(api) }
        api = nil
    }

    // MARK: Ending the server session
    /// DELETE requests still in flight, so quitting can wait for them (`stopAllForTermination`).
    private static var pendingDeletes: [UUID: Task<Void, Never>] = [:]
    private static let live = NSHashTable<StreamSession>.weakObjects()

    private static func deleteOnServer(_ api: SessionAPI) {
        let id = UUID()
        pendingDeletes[id] = Task {
            await api.stop()
            pendingDeletes[id] = nil
        }
    }

    /// Stops every session and returns the server-side deletes that are still running. Without this, quitting
    /// mid-stream exits before the DELETE is sent and the console or cloud slot stays allocated until it times out.
    static func stopAllForTermination() -> [Task<Void, Never>] {
        live.allObjects.forEach { $0.stop() }
        return Array(pendingDeletes.values)
    }
}
