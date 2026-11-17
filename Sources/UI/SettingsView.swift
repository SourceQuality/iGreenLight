import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        Form {
            Section("Stream") {
                Picker("Quality", selection: $settings.quality) {
                    ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                }
                Text("Picks the server profile via the device-info OS name (android / windows / tizen). Remote Play tops out at 1080p.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Request 16:10 (experimental)", isOn: $settings.request1610)
                Text("Sends \(settings.requestedSize.width)x\(settings.requestedSize.height) in dimensionschanged and displayInfo. The size the server actually sends is logged and shown in the stats overlay.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Game language", text: $settings.locale)
            }
            Section("Display") {
                Picker("Scaling", selection: $settings.scaling) {
                    ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("MetalFX Spatial upscaling", isOn: $settings.metalFX)
                Toggle("Show stats overlay by default", isOn: $settings.showStats)
            }
            Section("Input") {
                Toggle("Keyboard controls a virtual gamepad", isOn: $settings.keyboardAsGamepad)
                Text("Enter/Space = A, Esc/Delete = B, X, Y, arrows = D-pad, WASD = left stick, HUJK = right stick, Q/E = bumpers, Z/C = triggers, M = Menu, V = View, N = Xbox button.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Controller vibration", isOn: $settings.vibration)
            }
            Section("Network") {
                Toggle("Add console's own address as ICE candidate", isOn: $settings.consoleAddressCandidate)
                regionPicker("Remote Play region", token: auth.xhome, selection: $settings.xhomeRegionOverride)
                regionPicker("Cloud region", token: auth.xcloud, selection: $settings.xcloudRegionOverride)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    func regionPicker(_ title: String, token: XboxAuth.StreamToken?, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Default (\(token?.defaultRegion?.name ?? "-"))").tag("")
            ForEach(token?.offeringSettings.regions ?? [], id: \.name) { Text($0.name).tag($0.name) }
        }
    }
}
