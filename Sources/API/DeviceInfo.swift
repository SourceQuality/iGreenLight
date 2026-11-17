import Foundation

/// Builds the `X-MS-Device-Info` header (from Greenlight player/src/server/index.ts `getDeviceInfo`).
enum DeviceInfo {
    static func header(osName: String, sdk: SDKProfile, width: Int, height: Int) -> String {
        let info: [String: Any] = [
            "appInfo": ["env": ["clientAppId": "www.xbox.com", "clientAppType": "browser",
                                "clientAppVersion": sdk.appVersion, "clientSdkVersion": sdk.sdkVersion,
                                "httpEnvironment": "prod", "sdkInstallId": ""]],
            "dev": [
                "hw": ["make": "Microsoft", "model": "unknown", "sdktype": "web"],
                "os": ["name": osName, "ver": "22631.2715", "platform": "desktop"],
                "displayInfo": ["dimensions": ["widthInPixels": width, "heightInPixels": height],
                                "pixelDensity": ["dpiX": 2, "dpiY": 2]],
                "browser": ["browserName": "chrome", "browserVersion": sdk.browserVersion],
            ],
        ]
        return String(data: HTTP.jsonBody(info), encoding: .utf8)!
    }
}
