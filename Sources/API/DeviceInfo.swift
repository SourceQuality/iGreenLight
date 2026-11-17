import Foundation

/// Builds the `X-MS-Device-Info` header (from Greenlight player/src/server/index.ts `getDeviceInfo`).
enum DeviceInfo {
    static func header(quality: StreamQuality, width: Int, height: Int) -> String {
        let info: [String: Any] = [
            "appInfo": ["env": ["clientAppId": "www.xbox.com", "clientAppType": "browser",
                                "clientAppVersion": "21.1.98", "clientSdkVersion": "8.5.3",
                                "httpEnvironment": "prod", "sdkInstallId": ""]],
            "dev": [
                "hw": ["make": "Microsoft", "model": "unknown", "sdktype": "web"],
                "os": ["name": quality.osName, "ver": "22631.2715", "platform": "desktop"],
                "displayInfo": ["dimensions": ["widthInPixels": width, "heightInPixels": height],
                                "pixelDensity": ["dpiX": 2, "dpiY": 2]],
                "browser": ["browserName": "chrome", "browserVersion": "119.0"],
            ],
        ]
        return String(data: HTTP.jsonBody(info), encoding: .utf8)!
    }
}
