import Foundation
import Testing
@testable import iGreenLight

@Suite struct VideoBandwidthTests {
    private let sdp = [
        "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0", "b=AS:64", "a=mid:0",
        "m=video 9 UDP/TLS/RTP/SAVPF 102", "c=IN IP4 0.0.0.0", "b=AS:1000", "b=TIAS:1000000", "a=mid:1", "a=rtpmap:102 H264/90000",
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "c=IN IP4 0.0.0.0", "a=mid:2", "",
    ].joined(separator: "\r\n")

    @Test func replacesTheVideoLimitRightAfterTheConnectionLine() {
        let lines = WebRTCClient.setVideoBandwidth(sdp, kbps: 5000).components(separatedBy: "\r\n")
        let video = lines.firstIndex { $0.hasPrefix("m=video") }!
        #expect(Array(lines[video...(video + 3)]) == ["m=video 9 UDP/TLS/RTP/SAVPF 102", "c=IN IP4 0.0.0.0", "b=AS:5000", "b=TIAS:5000000"])
        #expect(!lines.contains("b=AS:1000"))
        #expect(!lines.contains("b=TIAS:1000000"))
        #expect(lines.contains("b=AS:64"))                            // audio untouched
        #expect(lines.filter { $0.hasPrefix("b=") }.count == 3)
        #expect(lines.count == sdp.components(separatedBy: "\r\n").count)
    }

    @Test func leavesSDPWithoutVideoAlone() {
        let audioOnly = "v=0\r\nm=audio 9 RTP 111\r\nc=IN IP4 0.0.0.0\r\n"
        #expect(WebRTCClient.setVideoBandwidth(audioOnly, kbps: 5000) == audioOnly)
        #expect(WebRTCClient.setVideoBandwidth("", kbps: 5000) == "")
    }

    @Test func worksWhenVideoIsTheLastSection() {
        let s = "v=0\r\nm=video 9 RTP 102\r\nc=IN IP4 0.0.0.0\r\na=mid:0"
        #expect(WebRTCClient.setVideoBandwidth(s, kbps: 100) == "v=0\r\nm=video 9 RTP 102\r\nc=IN IP4 0.0.0.0\r\nb=AS:100\r\nb=TIAS:100000\r\na=mid:0")
    }
}

@Suite struct BitstreamTests {
    @Test func splitsAnnexBOnBothStartCodeLengths() {
        let data = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0xCC])
        #expect(Bitstream.nalUnits(data) == [Data([0x67, 0xAA]), Data([0x68, 0xBB, 0xCC])])
        #expect(Bitstream.nalUnits(Data()).isEmpty)
        #expect(Bitstream.nalUnits(Data([1, 2, 3, 4])).isEmpty)        // no start code
        #expect(Bitstream.nalUnits(Data([0, 0, 1])).isEmpty)           // start code with nothing after it
    }

    @Test func removesEmulationPreventionBytes() {
        #expect(Bitstream.rbsp(Data([0x67, 0, 0, 3, 1, 0, 0, 3, 0]), from: 1) == [0, 0, 1, 0, 0, 0])
        #expect(Bitstream.rbsp(Data([0x67, 0, 3, 0]), from: 1) == [0, 3, 0])   // only after two zeros
    }

    @Test func bitReaderReadsFixedAndExpGolomb() throws {
        var r = Bitstream.BitReader([0b1010_0000])
        #expect(try r.u(1) == 1)
        #expect(try r.u(3) == 0b010)
        #expect(r.bitsLeft == 4)
        // ue: 1 -> 0, 010 -> 1, 011 -> 2, 00100 -> 3; se maps 1,2,3,4 -> 1,-1,2,-2
        var g = Bitstream.BitReader([0b1_010_011_0, 0b0100_0000])
        #expect(try g.ue() == 0)
        #expect(try g.ue() == 1)
        #expect(try g.ue() == 2)
        #expect(try g.ue() == 3)
        var s = Bitstream.BitReader([0b010_011_00, 0b100_00101, 0b0000_0000])
        #expect(try s.se() == 1)
        #expect(try s.se() == -1)
        #expect(try s.se() == 2)
        #expect(try s.se() == -2)
    }

    @Test func bitReaderThrowsInsteadOfReadingPastTheEnd() {
        var r = Bitstream.BitReader([0xFF])
        #expect(throws: Bitstream.ParseError.self) { try r.u(9) }
        var zeros = Bitstream.BitReader([0, 0, 0, 0, 0, 0])
        #expect(throws: Bitstream.ParseError.self) { try zeros.ue() }
        var empty = Bitstream.BitReader([])
        #expect(throws: Bitstream.ParseError.self) { try empty.skip(1) }
    }

    /// Network input: truncated or garbage parameter sets must come back as "couldn't parse", never trap.
    @Test func truncatedAndGarbageNALsDoNotCrash() {
        let inputs: [[UInt8]] = [[0x67], [0x67, 0x64], [0x67, 0x64, 0x00, 0x28, 0xFF], [0x42, 0x01], [0x42, 0x01, 0x01, 0xFF, 0xFF],
                                 [0x06], [0x06, 0x05, 0xFF], [0x4E, 0x01, 0x89], Array(repeating: 0xFF, count: 64), Array(repeating: 0x00, count: 64)]
        for bytes in inputs {
            _ = Bitstream.h264NAL(Data(bytes))
            _ = Bitstream.h265NAL(Data(bytes))
            _ = Bitstream.vp9(Data(bytes))
            _ = Bitstream.inspect(codec: "H264", data: Data([0, 0, 1] + bytes))
            _ = Bitstream.inspect(codec: "H265", data: Data([0, 0, 1] + bytes))
        }
    }
}
