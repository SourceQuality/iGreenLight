import Foundation
#if os(macOS)
import AppKit
#else
import GameController
#endif

/// The mouse half of mouse-and-keyboard mode (Greenlight input/mousekeyboard.ts): relative movement, buttons and
/// the wheel, sent as mouse frames on the input channel.
///
/// Movement is summed between ticks of the input loop (`drain()`), so a 1000 Hz mouse doesn't send 1000 packets a
/// second; a button change is queued on its own, so a click shorter than one tick isn't lost.
///
/// Mac: the pointer is captured by clicking the picture (hidden and detached from the cursor, so it can't leave the
/// window) and released with ⌘, by the stream menu, or when the window loses focus.
/// iPhone / iPad: a connected mouse is read through `GCMouse` while the mode is on.
final class MouseInput: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [MouseFrame] = []
    private var dx: Float = 0, dy: Float = 0, wheelX: Float = 0, wheelY: Float = 0
    private var buttons: UInt8 = 0
    private var _enabled = false

    /// Greenlight doubles the browser's movement values; kept so the pointer speed matches.
    private static let movementScale: Float = 2
    /// One wheel notch in Windows units (WHEEL_DELTA).
    private static let wheelNotch: Float = 120

    /// Mouse-and-keyboard mode is on. Set on the main thread.
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set {
            lock.lock(); _enabled = newValue; lock.unlock()
            if !newValue { release() }
        }
    }

    /// The frames since the last call, oldest first. Called by the input loop.
    func drain() -> [MouseFrame] {
        lock.lock(); defer { lock.unlock() }
        flushMotion()
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
        lock.lock(); dx += x * Self.movementScale; dy += y * Self.movementScale; lock.unlock()
    }

    /// In wheel notches.
    private func scroll(_ x: Float, _ y: Float) {
        lock.lock(); wheelX += x * Self.wheelNotch; wheelY += y * Self.wheelNotch; lock.unlock()
    }

    /// Bit 0 left, bit 1 right, bit 2 middle (the browser's `MouseEvent.buttons`, which Greenlight sends).
    private func setButtons(_ b: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard b != buttons else { return }
        flushMotion()
        buttons = b
        queue.append(MouseFrame(x: 0, y: 0, buttons: b))
    }

    /// Lets go of every button and forgets movement that wasn't sent yet.
    private func reset() {
        lock.lock(); defer { lock.unlock() }
        dx = 0; dy = 0; wheelX = 0; wheelY = 0
        if buttons != 0 { buttons = 0; queue.append(MouseFrame(x: 0, y: 0, buttons: 0)) }
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
        observers = [
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
    }

    /// A click on the picture: hide the pointer and keep it in place while the game has it.
    func capture() {
        guard enabled, !captured, monitor != nil else { return }
        captured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }

    func release() {
        if captured {
            captured = false
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
    func release() { reset() }
    #endif
}
