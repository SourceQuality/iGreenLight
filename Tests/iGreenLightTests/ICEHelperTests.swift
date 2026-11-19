import Testing
@testable import iGreenLight

@Suite struct ICEHelperTests {
    // Client 192.0.2.45:40000, stored inverted in the last three groups (RFC 4380).
    @Test func teredoDecodesClientAddressAndPort() {
        let t = ICEHelper.teredo("2001:0:4136:e378:8000:63bf:3fff:fdd2")
        #expect(t?.ip == "192.0.2.45")
        #expect(t?.port == 40000)
    }

    @Test func teredoAcceptsCompressedAndUppercaseForms() {
        #expect(ICEHelper.teredo("2001::4136:e378:8000:63bf:3fff:fdd2")?.ip == "192.0.2.45")
        #expect(ICEHelper.teredo("2001:0:4136:E378:8000:63BF:3FFF:FDD2")?.port == 40000)
    }

    @Test func ordinaryIPv6IsNotTeredo() {
        #expect(ICEHelper.teredo("2001:db8::1") == nil)                         // 2001: but not 2001:0:
        #expect(ICEHelper.teredo("2a00:1450:4003:80f::200e") == nil)
        #expect(ICEHelper.teredo("fe80::1") == nil)
        #expect(ICEHelper.teredo("192.168.1.88") == nil)
        #expect(ICEHelper.teredo("") == nil)
        #expect(ICEHelper.teredo("2001:0:zz:1:2:3:4:5") == nil || ICEHelper.teredo("2001:0:zz:1:2:3:4:5") != nil)   // must not trap
    }

    @Test func expandIPv6FillsTheGap() {
        #expect(ICEHelper.expandIPv6("::1") == ["0", "0", "0", "0", "0", "0", "0", "1"])
        #expect(ICEHelper.expandIPv6("2001:DB8::ff") == ["2001", "db8", "0", "0", "0", "0", "0", "ff"])
        #expect(ICEHelper.expandIPv6("1:2:3:4:5:6:7:8") == ["1", "2", "3", "4", "5", "6", "7", "8"])
    }

    @Test func candidateHelpers() {
        #expect(ICEHelper.stripPrefix("a=candidate:1 1 UDP 1 1.2.3.4 9002 typ host") == "candidate:1 1 UDP 1 1.2.3.4 9002 typ host")
        #expect(ICEHelper.stripPrefix("candidate:1") == "candidate:1")
        #expect(ICEHelper.hostCandidate(foundation: 10, ip: "1.2.3.4", port: 9002) == "candidate:10 1 UDP 1 1.2.3.4 9002 typ host ")
    }

    @Test func localCandidateIsWhatABrowserSends() {
        let c = ICEHelper.localCandidate(sdp: "candidate:1 1 udp 1685790463 198.51.100.7 58977 typ srflx raddr 10.0.0.2 rport 54131 generation 0 ufrag nT/n network-id 8", mid: "0", index: 0)
        #expect((c["candidate"] as? String)?.hasPrefix("candidate:1 1 udp") == true)
        #expect(c["usernameFragment"] as? String == "nT/n")
        #expect(c["sdpMid"] as? String == "0")
        #expect(c["sdpMLineIndex"] as? Int32 == 0)
        #expect(ICEHelper.localCandidate(sdp: "candidate:1 1 udp 1 198.51.100.7 9 typ host", mid: nil, index: 0)["usernameFragment"] == nil)
    }

    @Test func stunServersComeFromServerDetails() {
        let sd: [String: Any] = ["stunServerAddresses": ["stun:relay.example.com:3478", " stun:other.example.com:3478 ", "turn:x.example.com", "stun:", 7]]
        #expect(ICEHelper.stunServers(sd) == ["stun:relay.example.com:3478", "stun:other.example.com:3478"])
        #expect(ICEHelper.stunServers([:]).isEmpty)
        #expect(ICEHelper.stunServers(["stunServerAddresses": "stun:a.example.com"]).isEmpty)
    }

    @Test func isIPv4() {
        #expect(ICEHelper.isIPv4("192.168.1.88"))
        #expect(!ICEHelper.isIPv4("256.1.1.1"))
        #expect(!ICEHelper.isIPv4("1.2.3"))
        #expect(!ICEHelper.isIPv4("a.b.c.d"))
        #expect(!ICEHelper.isIPv4("2001::1"))
    }
}
