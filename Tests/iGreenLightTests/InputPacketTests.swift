import Foundation
import Testing
@testable import iGreenLight

@Suite struct InputPacketTests {
    @Test func axisClampsRoundsAndSurvivesNaN() {
        #expect(InputPacket.axis(1) == 32767)
        #expect(InputPacket.axis(-1) == -32767)
        #expect(InputPacket.axis(2.5) == 32767)
        #expect(InputPacket.axis(-9) == -32767)
        #expect(InputPacket.axis(0) == 0)
        #expect(InputPacket.axis(0.5) == 16384)
        #expect(InputPacket.axis(.nan) == 0)
        #expect(InputPacket.axis(.infinity) == 32767)
    }

    @Test func triggerClampsAndSurvivesNaN() {
        #expect(InputPacket.trigger(0) == 0)
        #expect(InputPacket.trigger(-1) == 0)
        #expect(InputPacket.trigger(1) == 65535)
        #expect(InputPacket.trigger(7) == 65535)
        #expect(InputPacket.trigger(0.5) == 32767)
        #expect(InputPacket.trigger(.nan) == 0)
    }

    @Test func buttonMaskBits() {
        #expect(GamepadFrame().buttonMask == 0)
        #expect(GamepadFrame(a: true).buttonMask == 16)
        #expect(GamepadFrame(nexus: true, rightThumb: true).buttonMask == 2 | 32768)
        var all = GamepadFrame()
        all.nexus = true; all.menu = true; all.view = true; all.a = true; all.b = true; all.x = true; all.y = true
        all.dpadUp = true; all.dpadDown = true; all.dpadLeft = true; all.dpadRight = true
        all.leftShoulder = true; all.rightShoulder = true; all.leftThumb = true; all.rightThumb = true
        #expect(all.buttonMask == 0xFFFE)
    }

    @Test func gamepadReportLayout() {
        var pad = GamepadFrame(index: 1, a: true)
        pad.leftX = 1; pad.leftY = -1; pad.rightTrigger = 1
        let d = [UInt8](InputPacket.report(sequence: 5, timestampMs: 1.0, gamepads: [pad]))
        // 14-byte header + count + one 23-byte record.
        #expect(d.count == 14 + 1 + 23)
        #expect(Array(d[0..<2]) == [2, 0])                      // type: gamepad, little-endian
        #expect(Array(d[2..<6]) == [5, 0, 0, 0])                // sequence
        #expect(Array(d[6..<14]) == [0, 0, 0, 0, 0, 0, 0xF0, 0x3F])   // 1.0 as little-endian double
        #expect(d[14] == 1)                                     // one gamepad
        #expect(d[15] == 1)                                     // index
        #expect(Array(d[16..<18]) == [16, 0])                   // buttons: A
        #expect(Array(d[18..<20]) == [0xFF, 0x7F])              // leftX = 32767
        #expect(Array(d[20..<22]) == [0x01, 0x80])              // leftY = -32767
        #expect(Array(d[22..<26]) == [0, 0, 0, 0])              // right stick centred
        #expect(Array(d[26..<28]) == [0, 0])                    // left trigger
        #expect(Array(d[28..<30]) == [0xFF, 0xFF])              // right trigger
        #expect(Array(d[30..<34]) == [1, 0, 0, 0])              // physical physicality, little-endian
        #expect(Array(d[34..<38]) == [0, 0, 0, 1])              // virtual physicality, big-endian
    }

    @Test func combinedReportSetsBothTypeBitsAndAppendsKeyboard() {
        let d = [UInt8](InputPacket.report(sequence: 0, timestampMs: 0, gamepads: [GamepadFrame()],
                                           keyboard: [KeyboardFrame(pressed: true, vkey: 0x41)]))
        #expect(Array(d[0..<2]) == [2 | 64, 0])
        #expect(d.count == 14 + 1 + 23 + 1 + 3)
        #expect(Array(d.suffix(4)) == [1, 2, 1, 0x41])
    }

    @Test func clientMetadataIsFifteenBytes() {
        let d = [UInt8](InputPacket.clientMetadata(sequence: 0x01020304, timestampMs: 0))
        #expect(d.count == 15)
        #expect(Array(d[0..<2]) == [8, 0])
        #expect(Array(d[2..<6]) == [4, 3, 2, 1])
        #expect(d[14] == 1)
    }

    @Test func frameMetadataCountsAndConvertsToTenthsOfMs() {
        let f = FrameMetadata(serverDataKey: 7, firstPacketArrivalMs: 1.5, submittedMs: 2, decodedMs: -4, renderedMs: 3)
        let d = [UInt8](InputPacket.frameMetadata(sequence: 0, timestampMs: 10, frames: [f]))
        #expect(d.count == 14 + 1 + 28)
        #expect(d[14] == 1)
        #expect(Array(d[15..<19]) == [7, 0, 0, 0])
        #expect(Array(d[19..<23]) == [15, 0, 0, 0])   // 1.5 ms
        #expect(Array(d[27..<31]) == [0, 0, 0, 0])    // negative times clamp to 0
        #expect(Array(d[35..<39]) == [100, 0, 0, 0])  // 10 ms
    }

    @Test func mergedTakesPressedButtonsAndTheLargerDeflection() {
        var pad = GamepadFrame(a: true); pad.leftX = 0.2; pad.leftTrigger = 0.9
        var keys = GamepadFrame(b: true); keys.leftX = -1; keys.leftTrigger = 0.1
        let m = pad.merged(with: keys)
        #expect(m.a && m.b)
        #expect(m.leftX == -1)
        #expect(m.leftTrigger == 0.9)
    }
}
