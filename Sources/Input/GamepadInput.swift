import Foundation
import GameController
import CoreHaptics

/// GameController-based gamepad source (replaces Greenlight input/gamepad.ts, which polls the Gamepad API).
final class GamepadInput: @unchecked Sendable {
    static let shared = GamepadInput()

    private let lock = NSLock()
    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]
    private var players: [ObjectIdentifier: CHHapticAdvancedPatternPlayer] = [:]
    var deadzone: Float = 0.08
    var onControllersChanged: (() -> Void)?

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { log("Gamepad", "connected: \(c.vendorName ?? "?") (\(c.productCategory))") }
            self?.onControllersChanged?()
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { log("Gamepad", "disconnected: \(c.vendorName ?? "?")") }
            self?.onControllersChanged?()
        }
        GCController.startWirelessControllerDiscovery {}
    }

    /// Up to four extended gamepads, in a stable order.
    var controllers: [GCController] {
        Array(GCController.controllers().filter { $0.extendedGamepad != nil }.prefix(4))
    }

    var controllerNames: [String] { controllers.map { $0.vendorName ?? "Controller" } }

    private func dz(_ v: Float) -> Float { abs(v) < deadzone ? 0 : v }

    private var _uiOwnsInput = false
    private var waitingForRelease = false
    /// The app's own UI (in-stream menu, a dialog) is using the controller: the console gets neutral pads meanwhile,
    /// and afterwards until every button has been let go, so the press that closed the menu doesn't reach the game.
    var uiOwnsInput: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _uiOwnsInput }
        set { lock.lock(); _uiOwnsInput = newValue; if newValue { waitingForRelease = true }; lock.unlock() }
    }
    /// Same hold-off at the start of a stream, for the A press that started it.
    func holdUntilReleased() { lock.lock(); waitingForRelease = true; lock.unlock() }

    func frames() -> [GamepadFrame] {
        let frames = liveFrames()
        lock.lock(); defer { lock.unlock() }
        guard _uiOwnsInput || waitingForRelease else { return frames }
        if !_uiOwnsInput, frames.allSatisfy({ $0.buttonMask == 0 && $0.leftTrigger == 0 && $0.rightTrigger == 0 }) {
            waitingForRelease = false
            return frames
        }
        return frames.map { var n = GamepadFrame(); n.index = $0.index; return n }
    }

    private func liveFrames() -> [GamepadFrame] {
        controllers.enumerated().compactMap { i, c in
            guard let g = c.extendedGamepad else { return nil }
            var f = GamepadFrame()
            f.index = UInt8(i)
            f.a = g.buttonA.isPressed; f.b = g.buttonB.isPressed; f.x = g.buttonX.isPressed; f.y = g.buttonY.isPressed
            f.leftShoulder = g.leftShoulder.isPressed; f.rightShoulder = g.rightShoulder.isPressed
            f.leftThumb = g.leftThumbstickButton?.isPressed ?? false
            f.rightThumb = g.rightThumbstickButton?.isPressed ?? false
            f.menu = g.buttonMenu.isPressed
            f.view = g.buttonOptions?.isPressed ?? false
            f.nexus = g.buttonHome?.isPressed ?? false
            f.dpadUp = g.dpad.up.isPressed; f.dpadDown = g.dpad.down.isPressed
            f.dpadLeft = g.dpad.left.isPressed; f.dpadRight = g.dpad.right.isPressed
            // GameController: +Y is up, same as the Xbox wire format.
            f.leftX = dz(g.leftThumbstick.xAxis.value); f.leftY = dz(g.leftThumbstick.yAxis.value)
            f.rightX = dz(g.rightThumbstick.xAxis.value); f.rightY = dz(g.rightThumbstick.yAxis.value)
            f.leftTrigger = g.leftTrigger.value; f.rightTrigger = g.rightTrigger.value
            // Greenlight: View + Menu together opens the guide on controllers without a reachable home button.
            if f.view && f.menu { f.view = false; f.menu = false; f.nexus = true }
            return f
        }
    }

    /// Plays a rumble report from the console (Greenlight gamepad.ts handleVibration).
    func vibrate(_ v: InputChannel.Vibration) {
        guard AppSettings.shared.vibration else { return }
        let list = controllers
        let id: ObjectIdentifier
        let makeEngine: () -> CHHapticEngine?
        if v.gamepadIndex < list.count, let haptics = list[v.gamepadIndex].haptics {
            id = ObjectIdentifier(list[v.gamepadIndex])
            makeEngine = { haptics.createEngine(withLocality: .default) }
        } else {
            #if os(iOS)
            // No controller (on-screen controls): rumble with the phone's own Taptic Engine.
            guard list.isEmpty, v.gamepadIndex == 0, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
            id = ObjectIdentifier(self)
            makeEngine = {
                let e = try? CHHapticEngine()
                e?.playsHapticsOnly = true
                return e
            }
            #else
            return
            #endif
        }
        lock.lock(); defer { lock.unlock() }
        do {
            let engine: CHHapticEngine
            if let e = engines[id] { engine = e } else {
                guard let e = makeEngine() else { return }
                e.isAutoShutdownEnabled = true
                try e.start()
                engines[id] = e
                engine = e
            }
            let intensity = max(v.leftMotor, v.rightMotor, v.leftTrigger, v.rightTrigger)
            try? players[id]?.stop(atTime: CHHapticTimeImmediate)
            guard intensity > 0, v.durationMs > 0 else { players[id] = nil; return }
            let sharp = v.rightMotor > v.leftMotor ? 0.8 : 0.3
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, intensity)),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharp))],
                                      relativeTime: Double(v.delayMs) / 1000, duration: Double(v.durationMs) / 1000)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            players[id] = player
        } catch {
            log("Gamepad", "haptics error: \(error.localizedDescription)")
        }
    }
}
