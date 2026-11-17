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

    /// Size we tell the server we want (dimensionschanged + displayInfo).
    var requestedSize: (width: Int, height: Int) {
        let h = quality.height
        if request1610 { return h == 720 ? (1280, 800) : (1920, 1200) }
        return h == 720 ? (1280, 720) : (1920, 1080)
    }
}
