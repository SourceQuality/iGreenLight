import Foundation
import AppKit
import Carbon.HIToolbox

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
    var onEscapeLong: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, let w = e.window, w === StreamWindow.current else { return e }
            // Let Cmd shortcuts through (Cmd+Q, Cmd+W, Ctrl+Cmd+F...).
            if e.modifierFlags.contains(.command) { return e }
            switch e.type {
            case .keyDown:
                if !e.isARepeat { self.pressed.insert(e.keyCode); self.emit(e.keyCode, true) }
            case .keyUp:
                self.pressed.remove(e.keyCode); self.emit(e.keyCode, false)
            default: return e
            }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        pressed.removeAll()
    }

    private func emit(_ code: UInt16, _ down: Bool) {
        if mkbMode, let vk = Self.windowsVK[Int(code)] { onKeyboardFrame?(KeyboardFrame(pressed: down, vkey: vk)) }
    }

    /// Current virtual-gamepad state from held keys.
    func gamepadFrame() -> GamepadFrame? {
        guard !mkbMode, AppSettings.shared.keyboardAsGamepad, !pressed.isEmpty else { return nil }
        let k = pressed
        func has(_ c: Int) -> Bool { k.contains(UInt16(c)) }
        var f = GamepadFrame()
        f.a = has(kVK_Return) || has(kVK_Space); f.b = has(kVK_Delete) || has(kVK_Escape)
        f.x = has(kVK_ANSI_X); f.y = has(kVK_ANSI_Y)
        f.dpadUp = has(kVK_UpArrow); f.dpadDown = has(kVK_DownArrow)
        f.dpadLeft = has(kVK_LeftArrow); f.dpadRight = has(kVK_RightArrow)
        f.leftShoulder = has(kVK_ANSI_LeftBracket) || has(kVK_ANSI_Q)
        f.rightShoulder = has(kVK_ANSI_RightBracket) || has(kVK_ANSI_E)
        f.leftThumb = has(kVK_ANSI_L); f.rightThumb = has(kVK_ANSI_R)
        f.leftTrigger = has(kVK_ANSI_Minus) || has(kVK_ANSI_Z) ? 1 : 0
        f.rightTrigger = has(kVK_ANSI_Equal) || has(kVK_ANSI_C) ? 1 : 0
        f.menu = has(kVK_ANSI_M); f.view = has(kVK_ANSI_V); f.nexus = has(kVK_ANSI_N) || has(kVK_Home)
        f.leftX = (has(kVK_ANSI_D) ? 1 : 0) - (has(kVK_ANSI_A) ? 1 : 0)
        f.leftY = (has(kVK_ANSI_W) ? 1 : 0) - (has(kVK_ANSI_S) ? 1 : 0)
        f.rightX = (has(kVK_ANSI_K) ? 1 : 0) - (has(kVK_ANSI_H) ? 1 : 0)
        f.rightY = (has(kVK_ANSI_U) ? 1 : 0) - (has(kVK_ANSI_J) ? 1 : 0)
        return f
    }

    /// macOS virtual key code → Windows VK code (subset).
    static let windowsVK: [Int: UInt8] = {
        var m: [Int: UInt8] = [:]
        let letters: [(Int, Character)] = [(kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"),
            (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"),
            (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"),
            (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z")]
        for (k, c) in letters { m[k] = c.asciiValue! }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, k) in digits.enumerated() { m[k] = UInt8(0x30 + i) }
        m[kVK_Return] = 0x0D; m[kVK_Escape] = 0x1B; m[kVK_Delete] = 0x08; m[kVK_Tab] = 0x09; m[kVK_Space] = 0x20
        m[kVK_LeftArrow] = 0x25; m[kVK_UpArrow] = 0x26; m[kVK_RightArrow] = 0x27; m[kVK_DownArrow] = 0x28
        m[kVK_Shift] = 0xA0; m[kVK_RightShift] = 0xA1; m[kVK_Control] = 0xA2; m[kVK_RightControl] = 0xA3
        m[kVK_Option] = 0xA4; m[kVK_RightOption] = 0xA5
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, k) in fkeys.enumerated() { m[k] = UInt8(0x70 + i) }
        return m
    }()
}
