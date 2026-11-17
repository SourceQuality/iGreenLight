import Foundation
import Testing
@testable import iGreenLight

/// `Redact` is the only thing between credentials and the log / capture files.
@Suite struct RedactTests {
    @Test func sensitiveKeys() {
        for k in ["key", "Key", "Authorization", "userToken", "gsToken", "accessKey", "Set-Cookie", "password", "clientSecret", "signature"] {
            #expect(Redact.isSensitiveKey(k), "\(k)")
        }
        for k in ["keyboard", "monkey", "ipV4Address", "state", "sessionPath", "port"] {
            #expect(!Redact.isSensitiveKey(k), "\(k)")
        }
    }

    /// The shape of the gssv /configuration response, which StreamSession logs.
    @Test func configurationResponseKeepsAddressesButNotTheSRTPKey() {
        let cfg: [String: Any] = [
            "serverDetails": ["ipV4Address": "192.168.1.88", "ipV4Port": 9002, "srtp": ["key": "c2VjcmV0LXNydHAta2V5LXZhbHVl"]],
            "keepAlivePulseInSeconds": 30,
        ]
        let text = "\(Redact.value(cfg))"
        #expect(!text.contains("c2VjcmV0LXNydHAta2V5LXZhbHVl"))
        #expect(text.contains("192.168.1.88"))
        #expect(text.contains("keepAlivePulseInSeconds"))
        let srtp = ((Redact.value(cfg) as? [String: Any])?["serverDetails"] as? [String: Any])?["srtp"] as? [String: Any]
        #expect(srtp?["key"] as? String == "[redacted 28 chars]")
    }

    @Test func sensitiveContainersAreRedactedWhole() {
        let v = Redact.value(["tokens": ["a", "b"], "credentials": ["user": "x"], "list": [["token": "abc"], ["name": "ok"]]]) as? [String: Any]
        #expect(v?["tokens"] as? String == "[redacted]")
        #expect(v?["credentials"] as? String == "[redacted]")
        let list = v?["list"] as? [[String: Any]]
        #expect(list?[0]["token"] as? String == "[redacted 3 chars]")
        #expect(list?[1]["name"] as? String == "ok")
    }

    @Test func jsonEmbeddedInAStringIsDecodedAndRedacted() {
        let v = Redact.value(["exchangeResponse": #"{"sdp":"v=0","userToken":"abcdef"}"#]) as? [String: Any]
        let inner = (v?["exchangeResponse"] as? [String: Any])?["_embeddedJSON"] as? [String: Any]
        #expect(inner?["sdp"] as? String == "v=0")
        #expect(inner?["userToken"] as? String == "[redacted 6 chars]")
    }

    @Test func headers() {
        let h = Redact.headers(["Authorization": "Bearer abc.def.ghi", "Accept": "application/json", "X-Custom": "Bearer zzz"])
        #expect(h["Authorization"] == "[redacted 18 chars]")
        #expect(h["Accept"] == "application/json")
        #expect(h["X-Custom"] == "[redacted]")
    }

    @Test func urlQueryTokens() {
        let u = Redact.url("https://example.test/path?token=abc123&region=weu")
        #expect(!u.contains("abc123"))
        #expect(u.contains("region=weu"))
        #expect(Redact.url("https://example.test/path") == "https://example.test/path")
    }

    @Test func scrubRemovesBearerXBLAndJWTs() {
        #expect(Redact.scrub("Authorization: Bearer abc.def") == "Authorization: [redacted]")
        #expect(Redact.scrub("XBL3.0 x=123;eyJabc") == "[redacted]")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123"
        #expect(!Redact.scrub("token is \(jwt) ok").contains("eyJ"))
        #expect(Redact.scrub("nothing secret here") == "nothing secret here")
    }

    @Test func body() {
        let json = Data(#"{"userToken":"abcdef","state":"Provisioned"}"#.utf8)
        let obj = Redact.body(json) as? [String: Any]
        #expect(obj?["userToken"] as? String == "[redacted 6 chars]")
        #expect(obj?["state"] as? String == "Provisioned")
        #expect(Redact.body(Data()) as? String == "")
        #expect(Redact.body(Data([0xFF, 0xFE, 0x00])) as? String == "<3 bytes binary>")
    }
}
