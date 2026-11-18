import Foundation
import notify

/// What the AWDL helper last reported: its clock and whether it is holding awdl0 down.
struct AWDLHelperStatus: Equatable {
    var time: UInt64
    var holding: Bool

    /// The helper's `status` state is `(seconds << 1) | holding`.
    init(state: UInt64) {
        time = state >> 1
        holding = state & 1 == 1
    }

    /// A report from the last few seconds means the helper is running: an uninstalled helper leaves its last
    /// report behind until the Mac restarts.
    func isFresh(now: UInt64, within seconds: UInt64 = 3) -> Bool {
        time != 0 && (now > time ? now - time : time - now) <= seconds
    }
}

#if os(macOS)
import ServiceManagement

/// Keeps AWDL (AirDrop, AirPlay, Handoff) off while a stream runs. With AWDL on, the Wi-Fi radio leaves the
/// network's channel at regular intervals and the stream gets latency spikes.
///
/// Taking `awdl0` down needs root and the app is sandboxed, so a root helper does it
/// (`Platforms/macOS/AWDLHelper/main.c`), turned on once from Settings → Network: `service` registers it and the
/// user approves it in System Settings. A build that can't register it falls back to `installCommand` in Terminal.
/// The app only renews a hold with Darwin notifications; when the renewals stop, by `end()` or a crash, the
/// helper brings AWDL back.
/// Without the helper installed all of this does nothing.
enum AWDLHold {
    static let holdName = "app.igreenlight.awdl.hold"
    static let pingName = "app.igreenlight.awdl.ping"
    static let statusName = "app.igreenlight.awdl.status"

    private static let queue = DispatchQueue(label: "app.igreenlight.awdl")
    private static var holds = 0
    private static var timer: DispatchSourceTimer?
    private static let holdToken = token(holdName)
    private static let statusToken = token(statusName)

    private static func token(_ name: String) -> Int32 {
        var token: Int32 = 0
        notify_register_check(name, &token)
        return token
    }

    private static var now: UInt64 { UInt64(Date().timeIntervalSince1970) }

    /// A stream started. Balanced by `end()`.
    static func begin() {
        queue.async {
            holds += 1
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            // The helper drops a hold that is 8 s old.
            t.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(200))
            t.setEventHandler {
                notify_set_state(holdToken, now)
                notify_post(holdName)
            }
            t.resume()
            timer = t
            queue.asyncAfter(deadline: .now() + 1.5) {
                // Still the same hold: not one that ended, nor a later stream's.
                guard timer === t else { return }
                let status = currentStatus()
                if status?.holding == true, interfaceIsUp == false {
                    log("AWDL", "off for this stream")
                } else if status == nil {
                    log("AWDL", "helper is not on: AWDL stays on (turn it on in Settings → Network)")
                } else {
                    log("AWDL", "helper is running but awdl0 is \(interfaceIsUp.map { $0 ? "still up" : "down" } ?? "missing")")
                }
            }
        }
    }

    /// Returns once the release is posted, so it also gets out when the app is quitting.
    static func end() {
        queue.sync {
            holds = max(0, holds - 1)
            guard holds == 0, let t = timer else { return }
            t.cancel()
            timer = nil
            notify_set_state(holdToken, 0)
            notify_post(holdName)
        }
    }

    /// The helper's last report, if it is recent enough to mean the helper is running.
    private static func currentStatus() -> AWDLHelperStatus? {
        var state: UInt64 = 0
        notify_get_state(statusToken, &state)
        let status = AWDLHelperStatus(state: state)
        return status.isFresh(now: now) ? status : nil
    }

    /// Asks the helper to report; nil when it doesn't answer, which means it isn't installed.
    static func helperStatus() async -> AWDLHelperStatus? {
        notify_post(pingName)
        try? await Task.sleep(for: .milliseconds(300))
        return currentStatus()
    }

    /// Whether `awdl0` is up; nil when this Mac has no such interface.
    static var interfaceIsUp: Bool? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            if String(cString: entry.pointee.ifa_name) == "awdl0" { return entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 }
            next = entry.pointee.ifa_next
        }
        return nil
    }

    /// The helper as a launchd daemon inside the app bundle (`Contents/Library/LaunchDaemons`). Its label differs
    /// from the Terminal install's, so `service.status` only ever describes this one.
    static let service = SMAppService.daemon(plistName: "app.igreenlight.awdl-daemon.plist")

    /// The Terminal command that installs the helper from this copy of the app, for a build that can't register it.
    static var installCommand: String? {
        guard let script = Bundle.main.url(forResource: "install-awdl-helper", withExtension: "sh") else { return nil }
        return "sudo sh '\(script.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Removes a Terminal install. Self-contained, so it still works after the app has moved or gone.
    static let uninstallCommand = "sudo sh -c 'launchctl bootout system/app.igreenlight.awdl-helper; rm -f /Library/LaunchDaemons/app.igreenlight.awdl-helper.plist /Library/PrivilegedHelperTools/app.igreenlight.awdl-helper'"
}
#endif
