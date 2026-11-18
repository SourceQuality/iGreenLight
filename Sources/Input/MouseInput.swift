import Foundation
#if os(macOS)
import AppKit
#endif
import GameController

/// The mouse, in one of two modes.
///
/// `.native` is the mouse half of mouse-and-keyboard mode (Greenlight input/mousekeyboard.ts): relative movement,
/// buttons and the wheel, sent as mouse frames on the input channel, for games that support a mouse.
/// `.stick` is for the rest: movement becomes the right stick of gamepad 0 (see `MouseStick`), the left button the
/// right trigger, the right button the left trigger and the middle button a click of the right stick.
///
/// Movement is summed between ticks of the input loop (`drain()`), so a 1000 Hz mouse doesn't send 1000 packets a
/// second; a button change is queued on its own, so a click shorter than one tick isn't lost.
///
/// Mac: the pointer is captured (hidden and detached from the cursor, so it can't leave the window) by clicking the
/// picture, or by itself while the stream is full screen, and released with ⌘, by the stream menu, or when the
/// window loses focus. In stick mode a real mouse is read through `GCMouse` instead of the window's events: that is
/// the mouse's own movement, without the pointer acceleration macOS adds (which would be applied on top of a
/// mapping that already works on speed), and it arrives on its own queue instead of waiting for the main thread
/// between frames. A trackpad isn't a `GCMouse`, so it still comes through the window's events.
/// iPhone / iPad: a connected mouse is read through `GCMouse` while the mode is on.
final class MouseInput: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [MouseFrame] = []
    private var dx: Float = 0, dy: Float = 0, wheelX: Float = 0, wheelY: Float = 0
    private var buttons: UInt8 = 0
    private var _mode = Mode.off
    private var stick = MouseStick()
    private var announced = false
    #if os(macOS)
    /// Lock held: the same as `captured`, for the raw mouse's queue.
    private var capturedForRaw = false
    private var lastRawAt = 0.0
    private var announcedRaw = false
    /// A mouse count as the units the stick mapping works in (about what a slow movement comes to in points).
    private static let rawScale: Float = 0.25
    private let rawQueue = DispatchQueue(label: "app.igreenlight.mouse", qos: .userInteractive)
    #endif

    enum Mode { case off, native, stick }

    /// Greenlight doubles the browser's movement values; kept so the pointer speed matches.
    private static let movementScale: Float = 2
    /// One wheel notch in Windows units (WHEEL_DELTA).
    private static let wheelNotch: Float = 120

    /// What the mouse does for the game. Set on the main thread.
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set {
            guard newValue != mode else { return }
            // Let go of what is held in the old mode before the new one starts.
            reset()
            lock.lock(); _mode = newValue; lock.unlock()
            if newValue == .off { release() } else { autoCapture() }
        }
    }
    private var enabled: Bool { mode != .off }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// Stick mode: the mouse as part of gamepad 0, or nil while it has nothing to add. Called by the input loop.
    func stickFrame() -> GamepadFrame? {
        lock.lock(); defer { lock.unlock() }
        guard _mode == .stick else { return nil }
        let settings = AppSettings.shared
        stick.fullSpeed = MouseStick.fullSpeed(sensitivity: settings.mouseAimSensitivity)
        stick.deadZone = Float(min(50, max(0, settings.mouseAimDeadZone))) / 100
        stick.curve = MouseStick.curve(setting: settings.mouseAimCurve)
        let v = stick.value(at: Self.now())
        guard v.x != 0 || v.y != 0 || buttons != 0 else { return nil }
        // Once per capture: shows in the log that the mouse is reaching the gamepad.
        if !announced {
            announced = true
            log("Input", "mouse aim: first output, stick \(String(format: "%.2f, %.2f", v.x, -v.y)), buttons \(buttons)")
        }
        var f = GamepadFrame()
        f.rightX = v.x
        f.rightY = -v.y
        if buttons & 1 != 0 { f.rightTrigger = 1 }
        if buttons & 2 != 0 { f.leftTrigger = 1 }
        if buttons & 4 != 0 { f.rightThumb = true }
        return f
    }

    /// The frames since the last call, oldest first. Called by the input loop.
    func drain() -> [MouseFrame] {
        lock.lock(); defer { lock.unlock() }
        // Outside native mode nothing is added, but a button release queued on the way out still has to go.
        if _mode == .native { flushMotion() }
        let out = queue
        queue.removeAll(keepingCapacity: true)
        return out
    }

    /// Lock held. Turns the summed movement into one frame; the fraction left over carries to the next.
    private func flushMotion() {
        let x = Int32(dx.rounded(.towardZero)), y = Int32(dy.rounded(.towardZero))
        let wx = Int32(wheelX.rounded(.towardZero)), wy = Int32(wheelY.rounded(.towardZero))
        guard x != 0 || y != 0 || wx != 0 || wy != 0 else { return }
        dx -= Float(x); dy -= Float(y); wheelX -= Float(wx); wheelY -= Float(wy)
        queue.append(MouseFrame(x: x, y: y, wheelX: wx, wheelY: wy, buttons: buttons))
    }

    /// `x`, `y` in the platform's units; +y is down, as on the wire.
    private func move(_ x: Float, _ y: Float) {
        lock.lock(); defer { lock.unlock() }
        if _mode == .stick {
            let now = Self.now()
            #if os(macOS)
            // A mouse that reports raw movement is read there; this would count it twice.
            if now - lastRawAt < 0.5 { return }
            #endif
            stick.add(dx: x, dy: y, at: now)
            return
        }
        dx += x * Self.movementScale; dy += y * Self.movementScale
    }

    /// In wheel notches.
    private func scroll(_ x: Float, _ y: Float) {
        lock.lock(); defer { lock.unlock() }
        // A controller has nothing like a wheel.
        guard _mode == .native else { return }
        wheelX += x * Self.wheelNotch; wheelY += y * Self.wheelNotch
    }

    /// Bit 0 left, bit 1 right, bit 2 middle (the browser's `MouseEvent.buttons`, which Greenlight sends).
    private func setButtons(_ b: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard b != buttons else { return }
        if _mode == .stick { buttons = b; return }
        flushMotion()
        buttons = b
        queue.append(MouseFrame(x: 0, y: 0, buttons: b))
    }

    /// Lets go of every button and forgets movement that wasn't sent yet.
    private func reset() {
        lock.lock(); defer { lock.unlock() }
        dx = 0; dy = 0; wheelX = 0; wheelY = 0
        stick.reset()
        announced = false
        if buttons != 0 {
            buttons = 0
            if _mode == .native { queue.append(MouseFrame(x: 0, y: 0, buttons: 0)) }
        }
    }

    deinit { stop() }

    #if os(macOS)
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// The pointer belongs to the game. Main thread.
    private(set) var captured = false

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp, .scrollWheel, .flagsChanged]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            guard let self, self.captured else { return e }
            switch e.type {
            case .flagsChanged:
                // ⌘ gives the pointer back (and lets ⌘Q, ⌘W, ⌃⌘F through as before).
                if e.modifierFlags.contains(.command) { self.release() }
                return e
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                self.move(Float(e.deltaX), Float(e.deltaY))
            case .scrollWheel:
                // A wheel reports notches; a trackpad or Magic Mouse reports points (about ten to a notch).
                let unit: Float = e.hasPreciseScrollingDeltas ? 0.1 : 1
                self.scroll(Float(e.scrollingDeltaX) * unit, Float(e.scrollingDeltaY) * unit)
            default:
                self.setButtons(UInt8(truncatingIfNeeded: NSEvent.pressedMouseButtons))
            }
            return nil
        }
        let nc = NotificationCenter.default
        GCMouse.mice().forEach(attachRaw)
        observers = [
            nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
                if let m = n.object as? GCMouse { self?.attachRaw(m) }
            },
            // Back in front, or just gone full screen: the game has the mouse again without a click.
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
                if (n.object as? NSWindow) === StreamWindow.current { self?.autoCapture() }
            },
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] n in
                if (n.object as? NSWindow) === StreamWindow.current { self?.autoCapture() }
            },
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
                if (n.object as? NSWindow) === StreamWindow.current { self?.release() }
            },
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.release() },
        ]
    }

    func stop() {
        release()
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        GCMouse.mice().forEach { $0.mouseInput?.mouseMovedHandler = nil }
    }

    private func attachRaw(_ mouse: GCMouse) {
        mouse.handlerQueue = rawQueue
        // GameController reports +y as up.
        mouse.mouseInput?.mouseMovedHandler = { [weak self] _, x, y in self?.rawMove(x, -y) }
    }

    /// On the raw mouse's queue.
    private func rawMove(_ x: Float, _ y: Float) {
        lock.lock(); defer { lock.unlock() }
        guard _mode == .stick, capturedForRaw else { return }
        let now = Self.now()
        lastRawAt = now
        stick.add(dx: x * Self.rawScale, dy: y * Self.rawScale, at: now)
        if !announcedRaw { announcedRaw = true; log("Input", "mouse aim: reading the mouse's raw movement") }
    }

    /// Full screen and in front, with no menu or dialog up: the mouse is the game's without asking.
    func autoCapture() {
        guard let w = StreamWindow.current, w.isKeyWindow, w.styleMask.contains(.fullScreen),
              !GamepadInput.shared.uiOwnsInput else { return }
        capture()
    }

    /// A click on the picture: hide the pointer and keep it in place while the game has it.
    func capture() {
        guard enabled, !captured, monitor != nil else { return }
        log("Input", "pointer captured, mouse mode \(mode)")
        captured = true
        lock.lock(); capturedForRaw = true; lock.unlock()
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }

    func release() {
        if captured {
            log("Input", "pointer released")
            captured = false
            lock.lock(); capturedForRaw = false; lock.unlock()
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
        reset()
    }
    #else
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        GCMouse.mice().forEach(attach)
        observer = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
            if let m = n.object as? GCMouse { self?.attach(m) }
        }
    }

    private var active: Bool { enabled && !GamepadInput.shared.uiOwnsInput }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        // GameController reports +y as up; the wire format has +y down.
        input.mouseMovedHandler = { [weak self] _, x, y in
            guard let self, self.active else { return }
            self.move(x, -y)
        }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            guard let self, self.active else { return }
            self.scroll(x, y)
        }
        let changed: GCControllerButtonValueChangedHandler = { [weak self, weak input] _, _, _ in
            guard let self, let input, self.active else { return }
            var b: UInt8 = 0
            if input.leftButton.isPressed { b |= 1 }
            if input.rightButton?.isPressed == true { b |= 2 }
            if input.middleButton?.isPressed == true { b |= 4 }
            self.setButtons(b)
        }
        input.leftButton.pressedChangedHandler = changed
        input.rightButton?.pressedChangedHandler = changed
        input.middleButton?.pressedChangedHandler = changed
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.scroll.valueChangedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
        }
        reset()
    }

    /// There is no pointer to capture on iOS; the mouse is read whenever the mode is on.
    func capture() {}
    func autoCapture() {}
    func release() { reset() }
    #endif
}
