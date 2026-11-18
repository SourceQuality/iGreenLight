// iGreenLight AWDL helper: a root daemon that keeps the awdl0 interface down while a stream is running.
//
// AWDL (AirDrop, AirPlay, Handoff) makes the Wi-Fi radio leave the network's channel at regular intervals, which
// a stream sees as latency spikes. Taking awdl0 down needs root and the app is sandboxed, so this tool does it.
//
// launchd starts it: registered from Settings → Network (SMAppService), or, for a build that can't do that,
// installed by Platforms/macOS/Scripts/install-awdl-helper.sh. It is sandboxed because macOS only registers a
// sandboxed app's daemon if the daemon is sandboxed too; the sandbox still lets root change the interface.
//
// The app talks to it with Darwin notifications (the names are mirrored in Sources/Streaming/AWDLHold.swift):
//   hold    state = the app's clock in seconds, renewed every 2 s while a stream runs; 0 releases.
//           A hold older than STALE_SECONDS is over, so a crashed app can't leave AWDL off.
//   ping    asks for a status report.
//   status  state = (helper's clock in seconds << 1) | holding, posted after every change and every ping.
//
// Any local process can post these notifications. The most one can do with that is keep AWDL off for as long as
// it keeps renewing the hold.

#include <dispatch/dispatch.h>
#include <errno.h>
#include <net/if.h>
#include <notify.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define LABEL "app.igreenlight.awdl-helper"
#define HOLD_NAME "app.igreenlight.awdl.hold"
#define PING_NAME "app.igreenlight.awdl.ping"
#define STATUS_NAME "app.igreenlight.awdl.status"
#define INTERFACE "awdl0"
#define STALE_SECONDS 8

static int sock = -1;
static int holdToken, pingToken, statusToken;
static bool holding = false;
/// Whether awdl0 was up when the hold began: only then is it brought back up afterwards.
static bool wasUp = false;
static dispatch_source_t watchTimer;
/// True until the first evaluation. A hold already running then is one a previous run of this helper was
/// serving, so awdl0 being down is that run's doing and it is brought back up afterwards.
static bool launching = true;

/// The interface flags, or -1 when they can't be read (no such interface on this Mac).
static int interfaceFlags(void) {
    struct ifreq request = {0};
    strlcpy(request.ifr_name, INTERFACE, sizeof(request.ifr_name));
    if (ioctl(sock, SIOCGIFFLAGS, &request) != 0) return -1;
    return (unsigned short)request.ifr_flags;
}

static void setInterfaceUp(bool up) {
    int flags = interfaceFlags();
    if (flags < 0 || ((flags & IFF_UP) != 0) == up) return;
    struct ifreq request = {0};
    strlcpy(request.ifr_name, INTERFACE, sizeof(request.ifr_name));
    request.ifr_flags = (short)(up ? (flags | IFF_UP) : (flags & ~IFF_UP));
    if (ioctl(sock, SIOCSIFFLAGS, &request) != 0) {
        syslog(LOG_ERR, "can't bring %s %s: %s", INTERFACE, up ? "up" : "down", strerror(errno));
    }
}

static void evaluate(void);

static void setWatching(bool on) {
    if (on == (watchTimer != NULL)) return;
    if (on) {
        // macOS brings awdl0 back up by itself (opening AirDrop, an AirPlay scan), so keep checking.
        watchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(watchTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(watchTimer, ^{ evaluate(); });
        dispatch_resume(watchTimer);
    } else {
        dispatch_source_cancel(watchTimer);
        dispatch_release(watchTimer);
        watchTimer = NULL;
    }
}

static void publishStatus(void) {
    notify_set_state(statusToken, ((uint64_t)time(NULL) << 1) | (holding ? 1 : 0));
    notify_post(STATUS_NAME);
}

static void evaluate(void) {
    uint64_t beat = 0;
    notify_get_state(holdToken, &beat);
    int64_t age = (int64_t)time(NULL) - (int64_t)beat;
    bool wanted = beat != 0 && age <= STALE_SECONDS && age >= -STALE_SECONDS;
    bool changed = wanted != holding;
    if (wanted) {
        if (!holding) {
            int flags = interfaceFlags();
            wasUp = flags >= 0 && (launching || (flags & IFF_UP) != 0);
            holding = true;
            syslog(LOG_NOTICE, "stream started: holding %s down", INTERFACE);
        }
        setInterfaceUp(false);
    } else if (holding) {
        holding = false;
        if (wasUp) setInterfaceUp(true);
        syslog(LOG_NOTICE, "stream over: %s", wasUp ? INTERFACE " is back up" : INTERFACE " was already down, left down");
    }
    launching = false;
    setWatching(holding);
    if (changed) publishStatus();
}

static int runDaemon(void) {
    openlog(LABEL, LOG_PID, LOG_DAEMON);
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { syslog(LOG_ERR, "socket: %s", strerror(errno)); return 1; }
    dispatch_queue_t queue = dispatch_get_main_queue();
    notify_register_check(STATUS_NAME, &statusToken);
    notify_register_dispatch(HOLD_NAME, &holdToken, queue, ^(int token) { (void)token; evaluate(); });
    notify_register_dispatch(PING_NAME, &pingToken, queue, ^(int token) { (void)token; evaluate(); publishStatus(); });

    // Stopped by launchd (uninstall, shutdown) in the middle of a stream: don't leave AWDL off.
    signal(SIGTERM, SIG_IGN);
    dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, queue);
    dispatch_source_set_event_handler(term, ^{
        if (holding && wasUp) setInterfaceUp(true);
        exit(0);
    });
    dispatch_resume(term);

    evaluate();
    publishStatus();
    dispatch_main();
}

int main(void) {
    return runDaemon();
}
