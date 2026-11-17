import SwiftUI

/// Settings as a console-style list: every row can be reached with the controller; A toggles or steps a value,
/// left / right step it either way.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var auth: AuthManager
    @State private var showLog = false
    #if os(iOS)
    @State private var tryingTouchControls = false
    #endif

    var body: some View {
        if showLog {
            LogView { showLog = false }
        } else {
            list
        }
    }

    private var list: some View {
        PadScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageHeader(title: "Settings") { EmptyView() }

                XboxSection(title: "Account") {
                    XboxRow(id: "set-account", title: auth.gamertag ?? "Signed in", detail: "Refresh the Xbox tokens", action: { Task { await auth.refreshAll() } }) {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Xbox.secondaryText)
                    }
                    XboxRow(id: "set-signout", title: "Sign out", action: { auth.signOut() }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42))
                    }
                }

                XboxSection(title: "Stream") {
                    XboxChoiceRow(id: "set-quality", title: "Quality",
                                  detail: "Remote Play asks the console for this resolution (1440p is its maximum, about 17–28 Mbps; 1080p HQ about 12, 1080p about 9, 720p about 2). Cloud gaming picks the server profile, which tops out at 1080p HQ.",
                                  options: StreamQuality.allCases, label: \.label, selection: $settings.quality)
                    XboxToggleRow(id: "set-1610", title: "Request 16:10 (experimental)",
                                  detail: "Sends \(settings.requestedSize.width)x\(settings.requestedSize.height) in dimensionschanged and displayInfo. The size the server actually sends is in the stats overlay.",
                                  isOn: $settings.request1610)
                    XboxToggleRow(id: "set-hold", title: "Hold this resolution on Remote Play",
                                  detail: "The console drops to a lower resolution on its own; this asks for the Quality tier again after 5 seconds below it.",
                                  isOn: $settings.holdResolution)
                    HStack {
                        Text("Game language").font(.body.weight(.medium)).foregroundStyle(.white)
                        Spacer()
                        TextField("en-US", text: $settings.locale).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .foregroundStyle(Xbox.brightGreen).frame(maxWidth: 140).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14).frame(minHeight: 46)
                    .background(Xbox.surface, in: RoundedRectangle(cornerRadius: Xbox.corner))
                }

                XboxSection(title: "Display") {
                    XboxChoiceRow(id: "set-scaling", title: "Scaling", options: ScalingMode.allCases, label: \.label, selection: $settings.scaling)
                    XboxChoiceRow(id: "set-upscaler", title: "Upscaler",
                                  detail: "VideoToolbox ML uses Apple's low-latency super-resolution model. It only accepts sources up to 1280 px wide (so it upgrades 720p to 1080p); larger streams fall back to MetalFX automatically.",
                                  options: Upscaler.allCases, label: \.label, selection: $settings.upscaler)
                    XboxToggleRow(id: "set-deband", title: "Debanding",
                                  detail: "Smooths the visible steps 8-bit video leaves in skies, fog and dark gradients. Edges and texture are left alone.",
                                  isOn: $settings.deband)
                    XboxToggleRow(id: "set-ambient", title: "Ambient bars",
                                  detail: "In Fit mode, fills the black bars with a blurred, dimmed mirror of the picture's edge, like frosted glass around the image.",
                                  isOn: $settings.ambientBars)
                    XboxChoiceRow(id: "set-edr", title: "HDR highlight expansion",
                                  detail: "The console only sends SDR. This stretches the brightest parts of the picture into the display's HDR headroom. It is an estimate, not real HDR: white menus and subtitles get brighter too.",
                                  options: EDRExpansion.allCases, label: \.label, selection: $settings.edrExpansion)
                    #if os(macOS)
                    XboxToggleRow(id: "set-fullscreen", title: "Start streams in full screen", isOn: $settings.startFullscreen)
                    #endif
                    XboxToggleRow(id: "set-stats", title: "Show stats overlay by default", isOn: $settings.showStats)
                }

                XboxSection(title: "Input") {
                    #if os(iOS)
                    XboxToggleRow(id: "set-touch", title: "On-screen controls when no controller is connected", isOn: $settings.touchControls)
                    XboxToggleRow(id: "set-touchhaptics", title: "Haptic feedback for on-screen buttons", isOn: $settings.touchHaptics)
                    XboxRow(id: "set-trytouch", title: "Try on-screen controls", action: { tryingTouchControls = true }) {
                        Image(systemName: "chevron.right").foregroundStyle(Xbox.secondaryText)
                    }
                    .fullScreenCover(isPresented: $tryingTouchControls) { TouchGamepadTestView() }
                    #endif
                    XboxToggleRow(id: "set-keyboard", title: "Keyboard controls a virtual gamepad",
                                  detail: "Enter/Space = A, Esc/Delete = B, X, Y, arrows = D-pad, WASD = left stick, HUJK = right stick, Q/E = bumpers, Z/C = triggers, M = Menu, V = View, N = Xbox button.",
                                  isOn: $settings.keyboardAsGamepad)
                    XboxToggleRow(id: "set-mkb", title: "Mouse and keyboard (experimental)",
                                  detail: mouseKeyboardDetail,
                                  isOn: $settings.mouseKeyboard)
                    XboxToggleRow(id: "set-vibration", title: "Controller vibration", isOn: $settings.vibration)
                }

                XboxSection(title: "Experimental: Diagnostics") {
                    XboxToggleRow(id: "set-diag", title: "Record diagnostics for each stream",
                                  detail: "Writes HTTP calls (tokens stripped), SDP offer/answer, data-channel messages, getStats every second and sampled decoded-frame formats to diagnostics/<timestamp>/.",
                                  isOn: $settings.diagnosticsEnabled)
                    XboxToggleRow(id: "set-diagoverlay", title: "Show diagnostics overlay", disabled: !settings.diagnosticsEnabled, isOn: $settings.diagnosticsOverlay)
                    XboxRow(id: "set-diagfolder", title: "Show diagnostics folder", action: {
                        let url = DiagnosticsRecorder.rootURL
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        Platform.reveal(url)
                    }) { Image(systemName: "folder").foregroundStyle(Xbox.secondaryText) }
                    XboxChoiceRow(id: "set-codec", title: "Preferred video codec", options: VideoCodecPreference.allCases, label: \.label, selection: $settings.codecPreference)
                    XboxToggleRow(id: "set-codeconly", title: "Offer only the preferred codec (no H.264 fallback)",
                                  detail: "Without fallback the console may refuse the session or send video the app can't decode.",
                                  isOn: $settings.codecOnlyPreferred)
                    XboxChoiceRow(id: "set-profile", title: "Client profile (os.name)", options: ClientProfile.allCases, label: \.label, selection: $settings.clientProfile)
                    XboxChoiceRow(id: "set-sdk", title: "Client identity", options: SDKProfile.allCases, label: \.label, selection: $settings.sdkProfile)
                    XboxChoiceRow(id: "set-bitrate", title: "Video bitrate ceiling (b=AS)",
                                  options: [0] + [5, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100].map { $0 * 1000 },
                                  label: { $0 == 0 ? "None (server default)" : "\($0 / 1000) Mbps" }, selection: $settings.maxVideoBitrateKbps)
                    XboxChoiceRow(id: "set-display", title: "Reported display size",
                                  detail: "Sent in X-MS-Device-Info displayInfo and dimensionschanged. Now: \(settings.osName), \(settings.requestedSize.width)×\(settings.requestedSize.height).",
                                  options: ReportedDisplaySize.allCases, label: \.label, selection: $settings.reportedDisplaySize)
                }

                XboxSection(title: "Network") {
                    XboxToggleRow(id: "set-consoleice", title: "Add console's own address as ICE candidate", isOn: $settings.consoleAddressCandidate)
                    regionRow("set-region-home", "Remote Play region", token: auth.xhome, selection: $settings.xhomeRegionOverride)
                    regionRow("set-region-cloud", "Cloud region", token: auth.xcloud, selection: $settings.xcloudRegionOverride)
                }

                XboxSection(title: "Log") {
                    XboxRow(id: "set-log", title: "Show log", action: { showLog = true }) {
                        Image(systemName: "chevron.right").foregroundStyle(Xbox.secondaryText)
                    }
                    #if os(iOS)
                    XboxRow(id: "set-files", title: "Open app folder in Files", action: { Platform.reveal(Platform.dataDirectory) }) {
                        Image(systemName: "folder").foregroundStyle(Xbox.secondaryText)
                    }
                    #else
                    XboxRow(id: "set-reveallog", title: "Reveal log file in Finder", action: { Platform.reveal(Log.shared.logFileURL) }) {
                        Image(systemName: "folder").foregroundStyle(Xbox.secondaryText)
                    }
                    #endif
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private var mouseKeyboardDetail: String {
        #if os(macOS)
        "Sends the keyboard and mouse to the game as themselves, for games that support them, instead of the virtual gamepad. Click the picture to capture the pointer; press ⌘ to get it back."
        #else
        "Sends a connected keyboard and mouse to the game as themselves, for games that support them, instead of the virtual gamepad."
        #endif
    }

    private func regionRow(_ id: String, _ title: String, token: XboxAuth.StreamToken?, selection: Binding<String>) -> some View {
        XboxChoiceRow(id: id, title: title, options: [""] + (token?.offeringSettings.regions.map(\.name) ?? []),
                      label: { $0.isEmpty ? "Default (\(token?.defaultRegion?.name ?? "-"))" : $0 }, selection: selection)
    }
}
