import Foundation

/// Runs on the WebRTC queue: merges controller + keyboard state and sends gamepad reports.
final class InputPump: @unchecked Sendable {
    private weak var rtc: WebRTCClient?
    private let keyboard: KeyboardInput
    private var knownPads = Set<UInt8>([0])
    private var lastSent: [UInt8: GamepadFrame] = [:]
    private var lastSentAt: [UInt8: UInt64] = [:]

    init(rtc: WebRTCClient, keyboard: KeyboardInput) {
        self.rtc = rtc
        self.keyboard = keyboard
    }

    func tick() {
        guard let rtc else { return }
        var pads = GamepadInput.shared.frames()
        if let k = keyboard.gamepadFrame() {
            if let i = pads.firstIndex(where: { $0.index == 0 }) { pads[i] = pads[i].merged(with: k) } else { pads.insert(k, at: 0) }
        }
        #if os(iOS)
        if let t = TouchGamepad.shared.frame() {
            if let i = pads.firstIndex(where: { $0.index == 0 }) { pads[i] = pads[i].merged(with: t) } else { pads.insert(t, at: 0) }
        }
        #endif
        if pads.isEmpty { pads = [GamepadFrame()] }
        let now = DispatchTime.now().uptimeNanoseconds
        var toSend: [GamepadFrame] = []
        for p in pads {
            if !knownPads.contains(p.index) {
                knownPads.insert(p.index)
                rtc.control.gamepadChanged(index: Int(p.index), added: true)
            }
            let changed = lastSent[p.index] != p
            let due = now &- (lastSentAt[p.index] ?? 0) > 16_000_000
            if changed || due {
                toSend.append(p)
                lastSent[p.index] = p
                lastSentAt[p.index] = now
            }
        }
        rtc.input.send(gamepads: toSend)
    }
}
