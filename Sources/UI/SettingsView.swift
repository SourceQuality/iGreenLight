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
                Text("Remote Play from your console: asks the console for this resolution (1440p is its maximum, about 17–28 Mbps; 1080p HQ about 12, 1080p about 9, 720p about 2). Cloud gaming: picks the server profile, which tops out at 1080p HQ.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Request 16:10 (experimental)", isOn: $settings.request1610)
                Text("Sends \(settings.requestedSize.width)x\(settings.requestedSize.height) in dimensionschanged and displayInfo. The size the server actually sends is logged and shown in the stats overlay.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Hold this resolution on Remote Play", isOn: $settings.holdResolution)
                Text("The console drops to a lower resolution on its own; this asks for the Quality tier again after 5 seconds below it.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Game language", text: $settings.locale)
            }
            Section("Display") {
                Picker("Scaling", selection: $settings.scaling) {
                    ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Upscaler", selection: $settings.upscaler) {
                    ForEach(Upscaler.allCases) { Text($0.label).tag($0) }
                }
                Text("VideoToolbox ML uses Apple's low-latency super-resolution model. It only accepts sources up to 1280 px wide (so it upgrades 720p to 1080p); larger streams fall back to MetalFX automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Debanding", isOn: $settings.deband)
                Text("Smooths the visible steps 8-bit video leaves in skies, fog and dark gradients. Edges and texture are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Ambient bars", isOn: $settings.ambientBars)
                Text("In Fit mode, fills the black bars with a blurred, dimmed mirror of the picture's edge, like frosted glass around the image.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("HDR highlight expansion", selection: $settings.edrExpansion) {
                    ForEach(EDRExpansion.allCases) { Text($0.label).tag($0) }
                }
                Text("The console only sends SDR. This stretches the brightest parts of the picture into the display's HDR headroom (XDR and other EDR displays). It is an estimate, not real HDR: white menus and subtitles get brighter too.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Start streams in full screen", isOn: $settings.startFullscreen)
                Toggle("Show stats overlay by default", isOn: $settings.showStats)
            }
            Section("Input") {
                Toggle("Keyboard controls a virtual gamepad", isOn: $settings.keyboardAsGamepad)
                Text("Enter/Space = A, Esc/Delete = B, X, Y, arrows = D-pad, WASD = left stick, HUJK = right stick, Q/E = bumpers, Z/C = triggers, M = Menu, V = View, N = Xbox button.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Controller vibration", isOn: $settings.vibration)
            }
            Section("Experimental: Diagnostics") {
                Toggle("Record diagnostics for each stream", isOn: $settings.diagnosticsEnabled)
                Toggle("Show diagnostics overlay", isOn: $settings.diagnosticsOverlay).disabled(!settings.diagnosticsEnabled)
                Text("Writes HTTP calls (tokens stripped), SDP offer/answer, data-channel messages, getStats every second and sampled decoded-frame formats to diagnostics/<timestamp>/.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show diagnostics folder") {
                    let url = DiagnosticsRecorder.rootURL
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Picker("Preferred video codec", selection: $settings.codecPreference) {
                    ForEach(VideoCodecPreference.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Offer only the preferred codec (no H.264 fallback)", isOn: $settings.codecOnlyPreferred)
                Text("Without fallback the console may refuse the session or send video the app can't decode.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Client profile (os.name)", selection: $settings.clientProfile) {
                    ForEach(ClientProfile.allCases) { Text($0.label).tag($0) }
                }
                Picker("Client identity", selection: $settings.sdkProfile) {
                    ForEach(SDKProfile.allCases) { Text($0.label).tag($0) }
                }
                Picker("Video bitrate ceiling (b=AS)", selection: $settings.maxVideoBitrateKbps) {
                    Text("None (server default)").tag(0)
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100], id: \.self) { Text("\($0) Mbps").tag($0 * 1000) }
                }
                Picker("Reported display size", selection: $settings.reportedDisplaySize) {
                    ForEach(ReportedDisplaySize.allCases) { Text($0.label).tag($0) }
                }
                Text("Sent in X-MS-Device-Info displayInfo and dimensionschanged. Now: \(settings.osName), \(settings.requestedSize.width)×\(settings.requestedSize.height).")
                    .font(.caption).foregroundStyle(.secondary)
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
