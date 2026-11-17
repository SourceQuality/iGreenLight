import Testing
import Carbon.HIToolbox
@testable import iGreenLight

struct KeyboardMapTests {
    @Test func lettersDigitsAndFunctionKeysMapToWindowsVirtualKeys() {
        #expect(KeyboardInput.windowsVK[kVK_ANSI_A] == 0x41)
        #expect(KeyboardInput.windowsVK[kVK_ANSI_Z] == 0x5A)
        #expect(KeyboardInput.windowsVK[kVK_ANSI_0] == 0x30)
        #expect(KeyboardInput.windowsVK[kVK_ANSI_9] == 0x39)
        #expect(KeyboardInput.windowsVK[kVK_F1] == 0x70)
        #expect(KeyboardInput.windowsVK[kVK_F12] == 0x7B)
    }

    @Test func punctuationNavigationAndModifiersAreMapped() {
        #expect(KeyboardInput.windowsVK[kVK_ANSI_Comma] == 0xBC)
        #expect(KeyboardInput.windowsVK[kVK_ANSI_Slash] == 0xBF)
        #expect(KeyboardInput.windowsVK[kVK_ANSI_Grave] == 0xC0)
        #expect(KeyboardInput.windowsVK[kVK_ANSI_Backslash] == 0xDC)
        #expect(KeyboardInput.windowsVK[kVK_ForwardDelete] == 0x2E)
        #expect(KeyboardInput.windowsVK[kVK_PageDown] == 0x22)
        #expect(KeyboardInput.windowsVK[kVK_Shift] == 0xA0)
        #expect(KeyboardInput.windowsVK[kVK_RightOption] == 0xA5)
        #expect(KeyboardInput.windowsVK[kVK_CapsLock] == 0x14)
    }

    @Test func mouseReportCarriesMovementWheelAndButtons() {
        let d = InputPacket.report(sequence: 1, timestampMs: 0, mouse: [MouseFrame(x: -3, y: 7, wheelX: 0, wheelY: 120, buttons: 0b101)])
        // 14-byte header, a count byte, then 18 bytes per mouse frame.
        #expect(d.count == 14 + 1 + 18)
        #expect(d[0] == UInt8(ReportType.mouse.rawValue))
        #expect(d[14] == 1)
        #expect(Array(d[15..<19]) == [0xFD, 0xFF, 0xFF, 0xFF])
        #expect(d[19] == 7)
        #expect(d[27] == 120)
        #expect(d[31] == 0b101)
        #expect(d[32] == 0)
    }
}
