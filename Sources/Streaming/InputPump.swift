import Foundation

/// Runs on the WebRTC queue: merges controller + keyboard state and sends gamepad reports, with the mouse
/// frames collected since the last tick.
final class InputPump: @unchecked Sendable {
    private weak var rtc: WebRTCClient?
    private let keyboard: KeyboardInput
    private let mouse: MouseInput
    private var knownPads = Set<UInt8>([0])
    private var lastSent: [UInt8: GamepadFrame] = [:]
    private var lastSentAt: [UInt8: UInt64] = [:]

    init(rtc: WebRTCClient, keyboard: KeyboardInput, mouse: MouseInput) {
        self.rtc = rtc
        self.keyboard = keyboard
        self.mouse = mouse
    }

    func tick() {
        guard let rtc else { return }
        var pads = GamepadInput.shared.frames()
        if let k = keyboard.gamepadFrame() {
            if let i = pads.firstIndex(where: { $0.index == 0 }) { pads[i] = pads[i].merged(with: k) } else { pads.insert(k, at: 0) }
        }
        #if os(iOS)
        // Not while the stream menu or a dialog is up: a thumb still resting on a stick is not for the game then.
        if !GamepadInput.shared.uiOwnsInput, let t = TouchGamepad.shared.frame() {
            if let i = pads.firstIndex(where: { $0.index == 0 }) { pads[i] = pads[i].merged(with: t) } else { pads.insert(t, at: 0) }
        }
        #endif
        // Pad 0 always exists for the console (keyboard, on-screen controls, or just neutral), whatever slots the
        // controllers are in.
        if !pads.contains(where: { $0.index == 0 }) { pads.insert(GamepadFrame(), at: 0) }
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
        // A pad that went away (disconnected, or the others moved down a slot): let go of whatever it held on the
        // console, then tell the console it's gone. Pad 0 always exists (keyboard / on-screen controls).
        let gone = knownPads.subtracting(pads.map(\.index))
        for index in gone {
            var neutral = GamepadFrame()
            neutral.index = index
            toSend.append(neutral)
            lastSent[index] = nil
            lastSentAt[index] = nil
            knownPads.remove(index)
        }
        rtc.input.send(gamepads: toSend, mouse: mouse.drain())
        for index in gone { rtc.control.gamepadChanged(index: Int(index), added: false) }
    }
}
