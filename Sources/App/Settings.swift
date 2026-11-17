import Foundation
import SwiftUI

enum StreamQuality: String, CaseIterable, Identifiable, Codable {
    case p720, p1080, p1080HQ
    var id: String { rawValue }
    var label: String {
        switch self { case .p720: "720p"; case .p1080: "1080p"; case .p1080HQ: "1080p HQ" }
    }
    /// os.name in X-MS-Device-Info picks the server-side profile (Better xCloud's trick).
    var osName: String {
        switch self { case .p720: "android"; case .p1080: "windows"; case .p1080HQ: "tizen" }
    }
    var height: Int { self == .p720 ? 720 : 1080 }
}

enum ScalingMode: String, CaseIterable, Identifiable, Codable {
    case fit, zoom, stretch
    var id: String { rawValue }
    var label: String {
        switch self { case .fit: "Fit (letterbox)"; case .zoom: "Zoom (fill, crop)"; case .stretch: "Stretch" }
    }
}

enum Upscaler: String, CaseIterable, Identifiable, Codable {
    case off, metalFX, videoToolbox
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off (bilinear)"
        case .metalFX: "MetalFX Spatial"
        case .videoToolbox: "VideoToolbox ML + MetalFX"
        }
    }
}

// MARK: Experimental (Diagnostics) settings

enum VideoCodecPreference: String, CaseIterable, Identifiable, Codable {
    case h264High, h264High51, h264Main, h264Baseline, hevcMain, hevcMain10, vp9p0, vp9p2, av1
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264High: "H.264 High 640c1f (default)"
        case .h264High51: "H.264 High L5.1 640033"
        case .h264Main: "H.264 Main 4d0033"
        case .h264Baseline: "H.264 Constrained Baseline 42e01f"
        case .hevcMain: "HEVC Main (profile-id 1)"
        case .hevcMain10: "HEVC Main 10 (profile-id 2)"
        case .vp9p0: "VP9 profile 0"
        case .vp9p2: "VP9 profile 2 (10-bit)"
        case .av1: "AV1 main (dav1d, software)"
        }
    }
}

/// `os.name` in X-MS-Device-Info and `settings.osName` in /play; picks the server-side client profile.
enum ClientProfile: String, CaseIterable, Identifiable, Codable {
    case auto = "", android, windows, tizen, webOS, xboxOS, kepler
    var id: String { rawValue }
    var label: String { self == .auto ? "From Quality setting" : rawValue }
}

/// Client identity sent in X-MS-Device-Info.appInfo / browser.
enum SDKProfile: String, CaseIterable, Identifiable, Codable {
    case greenlight, current
    var id: String { rawValue }
    var label: String { self == .greenlight ? "Greenlight (app 21.1.98, SDK 8.5.3, Chrome 119)" : "Current web (app 26.1.97, SDK 10.3.7, Chrome 140)" }
    var appVersion: String { self == .greenlight ? "21.1.98" : "26.1.97" }
    var sdkVersion: String { self == .greenlight ? "8.5.3" : "10.3.7" }
    var browserVersion: String { self == .greenlight ? "119.0" : "140.0.3485.54" }
}

enum ReportedDisplaySize: String, CaseIterable, Identifiable, Codable {
    case auto, w1920h1080, w1920h1200, w2560h1440, w2560h1600, w3840h2160, w4096h2160
    var id: String { rawValue }
    var size: (Int, Int)? {
        switch self {
        case .auto: nil
        case .w1920h1080: (1920, 1080)
        case .w1920h1200: (1920, 1200)
        case .w2560h1440: (2560, 1440)
        case .w2560h1600: (2560, 1600)
        case .w3840h2160: (3840, 2160)
        case .w4096h2160: (4096, 2160)
        }
    }
    var label: String { size.map { "\($0.0)×\($0.1)" } ?? "From Quality / 16:10 setting" }
}

/// App settings, backed by UserDefaults. Mirrors Greenlight's settings pages where it makes sense.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("quality") var quality: StreamQuality = .p1080
    @AppStorage("request1610") var request1610 = false
    @AppStorage("scaling") var scaling: ScalingMode = .fit
    @AppStorage("upscaler") var upscaler: Upscaler = .metalFX
    @AppStorage("startFullscreen") var startFullscreen = true
    @AppStorage("locale") var locale = "en-US"
    @AppStorage("vibration") var vibration = true
    @AppStorage("keyboardAsGamepad") var keyboardAsGamepad = true
    @AppStorage("showStats") var showStats = false
    @AppStorage("consoleAddressCandidate") var consoleAddressCandidate = true
    @AppStorage("xhomeRegionOverride") var xhomeRegionOverride = ""
    @AppStorage("xcloudRegionOverride") var xcloudRegionOverride = ""

    // Experimental / Diagnostics
    @AppStorage("diagnosticsEnabled") var diagnosticsEnabled = false
    @AppStorage("diagnosticsOverlay") var diagnosticsOverlay = true
    @AppStorage("codecPreference") var codecPreference: VideoCodecPreference = .h264High
    @AppStorage("codecOnlyPreferred") var codecOnlyPreferred = false
    @AppStorage("clientProfile") var clientProfile: ClientProfile = .auto
    @AppStorage("sdkProfile") var sdkProfile: SDKProfile = .greenlight
    /// 0 = no b=AS line (server default).
    @AppStorage("maxVideoBitrateKbps") var maxVideoBitrateKbps = 0
    @AppStorage("reportedDisplaySize") var reportedDisplaySize: ReportedDisplaySize = .auto

    var osName: String { clientProfile == .auto ? quality.osName : clientProfile.rawValue }

    /// Settings that affect stream negotiation, recorded with each diagnostics run.
    var experimentalSnapshot: [String: Any] {
        ["quality": quality.label, "osName": osName, "clientProfile": clientProfile.rawValue.isEmpty ? "auto" : clientProfile.rawValue,
         "sdkProfile": sdkProfile.rawValue, "codecPreference": codecPreference.rawValue, "codecOnlyPreferred": codecOnlyPreferred,
         "maxVideoBitrateKbps": maxVideoBitrateKbps, "requestedSize": "\(requestedSize.width)x\(requestedSize.height)",
         "request1610": request1610, "reportedDisplaySize": reportedDisplaySize.rawValue, "upscaler": upscaler.rawValue,
         "consoleAddressCandidate": consoleAddressCandidate]
    }

    /// Size we tell the server we want (dimensionschanged + displayInfo).
    var requestedSize: (width: Int, height: Int) {
        if let s = reportedDisplaySize.size { return s }
        let h = quality.height
        if request1610 { return h == 720 ? (1280, 800) : (1920, 1200) }
        return h == 720 ? (1280, 720) : (1920, 1080)
    }
}
