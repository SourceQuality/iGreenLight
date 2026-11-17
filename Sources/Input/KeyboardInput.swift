import Foundation
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#else
import GameController
#endif

/// Key codes of the platform's keyboard events: Carbon virtual key codes on the Mac, USB HID usages
/// (what `GCKeyboard` reports) on iOS.
private enum Key {
    #if os(macOS)
    static let letters: [Int] = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
    /// 0…9
    static let digits: [Int] = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static let fkeys: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
    static let `return` = kVK_Return, space = kVK_Space, delete = kVK_Delete, escape = kVK_Escape, tab = kVK_Tab
    static let up = kVK_UpArrow, down = kVK_DownArrow, left = kVK_LeftArrow, right = kVK_RightArrow
    static let leftBracket = kVK_ANSI_LeftBracket, rightBracket = kVK_ANSI_RightBracket, minus = kVK_ANSI_Minus, equal = kVK_ANSI_Equal
    static let home = kVK_Home
    static let shift = kVK_Shift, rightShift = kVK_RightShift, control = kVK_Control, rightControl = kVK_RightControl
    static let option = kVK_Option, rightOption = kVK_RightOption
    #else
    static let letters: [Int] = Array(0x04...0x1D)
    /// 0…9 (HID orders them 1…9, 0)
    static let digits: [Int] = [0x27] + Array(0x1E...0x26)
    static let fkeys: [Int] = Array(0x3A...0x45)
    static let `return` = 0x28, space = 0x2C, delete = 0x2A, escape = 0x29, tab = 0x2B
    static let up = 0x52, down = 0x51, left = 0x50, right = 0x4F
    static let leftBracket = 0x2F, rightBracket = 0x30, minus = 0x2D, equal = 0x2E
    static let home = 0x4A
    static let shift = 0xE1, rightShift = 0xE5, control = 0xE0, rightControl = 0xE4
    static let option = 0xE2, rightOption = 0xE6
    #endif
    static func letter(_ c: Character) -> Int { letters[Int(c.asciiValue! - 65)] }
}

/// Keyboard fallback. Default: keyboard → virtual gamepad 0 (Greenlight gamepad.ts keyboard_mapping),
/// plus WASD / IJKL for the sticks. The MKB path (Windows virtual-key codes) is used for xCloud MKB titles.
final class KeyboardInput: @unchecked Sendable {
    private let lock = NSLock()
    private var _pressed = Set<UInt16>()
    private var pressed: Set<UInt16> {
        get { lock.lock(); defer { lock.unlock() }; return _pressed }
        set { lock.lock(); _pressed = newValue; lock.unlock() }
    }
    private var monitor: Any?
    var mkbMode = false
    var onKeyboardFrame: ((KeyboardFrame) -> Void)?

    deinit { stop() }

    #if os(macOS)
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, let w = e.window, w === StreamWindow.current else { return e }
            // The in-stream menu is open: the keys drive it, not the game.
            if GamepadInput.shared.uiOwnsInput { self.pressed.removeAll(); return e }
            let command = e.modifierFlags.contains(.command)
            switch e.type {
            case .keyUp:
                // Always release, even with Cmd down: a key let go during Cmd+Tab must not stay held.
                self.pressed.remove(e.keyCode); self.emit(e.keyCode, false)
                return command ? e : nil
            case .keyDown:
                // Let Cmd shortcuts through (Cmd+Q, Cmd+W, Ctrl+Cmd+F...).
                if command { return e }
                if !e.isARepeat { self.pressed.insert(e.keyCode); self.emit(e.keyCode, true) }
                return nil
            default: return e
            }
        }
        // Key-ups never arrive once the window or app loses focus, so release everything then.
        let nc = NotificationCenter.default
        focusObservers = [
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
                if (n.object as? NSWindow) === StreamWindow.current { self?.releaseAll() }
            },
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.releaseAll() },
        ]
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
        pressed.removeAll()
    }

    private var focusObservers: [NSObjectProtocol] = []

    private func releaseAll() {
        let held = pressed
        pressed.removeAll()
        held.forEach { emit($0, false) }
    }
    #else
    /// Hardware keyboards (Magic Keyboard, Bluetooth, USB-C) through GameController's GCKeyboard.
    func start() {
        guard monitor == nil else { return }
        attach()
        monitor = NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in self?.attach() }
    }

    private func attach() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, down in
            guard let self else { return }
            let code = UInt16(truncatingIfNeeded: keyCode.rawValue)
            if down { self.pressed.insert(code) } else { self.pressed.remove(code) }
            self.emit(code, down)
        }
    }

    func stop() {
        if let m = monitor { NotificationCenter.default.removeObserver(m) }
        monitor = nil
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        pressed.removeAll()
    }
    #endif

    private func emit(_ code: UInt16, _ down: Bool) {
        if mkbMode, let vk = Self.windowsVK[Int(code)] { onKeyboardFrame?(KeyboardFrame(pressed: down, vkey: vk)) }
    }

    private var virtualUntil: [String: UInt64] = [:]

    /// Holds a virtual button for `ms` (used by the toolbar's Guide button).
    func tap(_ button: String, ms: UInt64 = 150) {
        lock.lock(); virtualUntil[button] = DispatchTime.now().uptimeNanoseconds + ms * 1_000_000; lock.unlock()
    }

    private func virtualHeld(_ button: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (virtualUntil[button] ?? 0) > DispatchTime.now().uptimeNanoseconds
    }

    /// Current virtual-gamepad state from held keys.
    func gamepadFrame() -> GamepadFrame? {
        if virtualHeld("nexus") { var f = GamepadFrame(); f.nexus = true; return f }
        guard !mkbMode, AppSettings.shared.keyboardAsGamepad, !pressed.isEmpty, !GamepadInput.shared.uiOwnsInput else { return nil }
        let k = pressed
        func has(_ c: Int) -> Bool { k.contains(UInt16(c)) }
        func has(_ c: Character) -> Bool { has(Key.letter(c)) }
        var f = GamepadFrame()
        f.a = has(Key.return) || has(Key.space); f.b = has(Key.delete) || has(Key.escape)
        f.x = has("X"); f.y = has("Y")
        f.dpadUp = has(Key.up); f.dpadDown = has(Key.down)
        f.dpadLeft = has(Key.left); f.dpadRight = has(Key.right)
        f.leftShoulder = has(Key.leftBracket) || has("Q")
        f.rightShoulder = has(Key.rightBracket) || has("E")
        f.leftThumb = has("L"); f.rightThumb = has("R")
        f.leftTrigger = has(Key.minus) || has("Z") ? 1 : 0
        f.rightTrigger = has(Key.equal) || has("C") ? 1 : 0
        f.menu = has("M"); f.view = has("V"); f.nexus = has("N") || has(Key.home)
        f.leftX = (has("D") ? 1 : 0) - (has("A") ? 1 : 0)
        f.leftY = (has("W") ? 1 : 0) - (has("S") ? 1 : 0)
        f.rightX = (has("K") ? 1 : 0) - (has("H") ? 1 : 0)
        f.rightY = (has("U") ? 1 : 0) - (has("J") ? 1 : 0)
        return f
    }

    /// Platform key code → Windows VK code (subset).
    static let windowsVK: [Int: UInt8] = {
        var m: [Int: UInt8] = [:]
        for (i, k) in Key.letters.enumerated() { m[k] = UInt8(0x41 + i) }
        for (i, k) in Key.digits.enumerated() { m[k] = UInt8(0x30 + i) }
        m[Key.return] = 0x0D; m[Key.escape] = 0x1B; m[Key.delete] = 0x08; m[Key.tab] = 0x09; m[Key.space] = 0x20
        m[Key.left] = 0x25; m[Key.up] = 0x26; m[Key.right] = 0x27; m[Key.down] = 0x28
        m[Key.shift] = 0xA0; m[Key.rightShift] = 0xA1; m[Key.control] = 0xA2; m[Key.rightControl] = 0xA3
        m[Key.option] = 0xA4; m[Key.rightOption] = 0xA5
        for (i, k) in Key.fkeys.enumerated() { m[k] = UInt8(0x70 + i) }
        return m
    }()
}
