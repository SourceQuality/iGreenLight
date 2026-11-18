import Foundation
import notify
import Testing
@testable import iGreenLight

struct AWDLHoldTests {
    @Test func statusStateCarriesTheClockAndTheHoldBit() {
        #expect(AWDLHelperStatus(state: (1_800_000_000 << 1) | 1) == AWDLHelperStatus(state: 3_600_000_001))
        let holding = AWDLHelperStatus(state: (1_800_000_000 << 1) | 1)
        #expect(holding.time == 1_800_000_000 && holding.holding)
        let idle = AWDLHelperStatus(state: 1_800_000_000 << 1)
        #expect(idle.time == 1_800_000_000 && !idle.holding)
    }

    @Test func onlyARecentReportMeansTheHelperIsRunning() {
        let status = AWDLHelperStatus(state: 1000 << 1)
        #expect(status.isFresh(now: 1000))
        #expect(status.isFresh(now: 1003))
        #expect(status.isFresh(now: 999))
        #expect(!status.isFresh(now: 1004))
        // No helper has ever reported.
        #expect(!AWDLHelperStatus(state: 0).isFresh(now: 0))
    }

    /// The app is sandboxed: the hold only reaches the helper if the sandbox lets it set a notification's state.
    @Test func theSandboxLetsTheAppSetNotificationState() {
        var token: Int32 = 0
        #expect(notify_register_check("app.igreenlight.awdl.test", &token) == 0)
        #expect(notify_set_state(token, 42) == 0)
        var state: UInt64 = 0
        #expect(notify_get_state(token, &state) == 0)
        #expect(state == 42)
        #expect(notify_post("app.igreenlight.awdl.test") == 0)
    }
}
