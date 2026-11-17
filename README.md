# iGreenLight

A native macOS and iOS app for Xbox Remote Play (xHome) and Xbox Cloud Gaming (xCloud).
It is written in Swift and SwiftUI, uses Google's libwebrtc for transport, renders with Metal and
MetalFX Spatial upscaling, and takes input through the GameController framework. It has no Electron and no web view.

iGreenLight is a port of **[Greenlight](https://github.com/unknownskl/greenlight)** by
UnknownSKL (Jim Kroon), MIT licensed. The protocol knowledge (auth flow, gssv session API, data channel
messages, input report format) comes from Greenlight and its auth library
[xal-node](https://github.com/unknownskl/xal-node). iGreenLight itself is MIT licensed ([`LICENSE`](LICENSE)). Greenlight's and WebRTC's
licenses are in [`Licenses/`](Licenses); they ship inside the app and are shown under Settings → About. Ideas from
[Better xCloud](https://github.com/redphx/better-xcloud) were also used: the quality profiles chosen by the device-info OS name, and the console address used as an ICE candidate.

Not affiliated with Microsoft or Xbox.

## Requirements

* macOS 15+, Apple silicon; or iOS 18+
* Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
xcodegen generate
xcodebuild -project iGreenLight.xcodeproj -scheme iGreenLight -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/iGreenLight.app
```

Unit tests (Swift Testing, in `Tests/iGreenLightTests`, hosted in the Mac app; they need no account or network):

```sh
xcodebuild test -project iGreenLight.xcodeproj -scheme iGreenLight -derivedDataPath build -destination 'platform=macOS,arch=arm64'
```

### iPhone / iPad

The `iGreenLight-iOS` target builds the same sources for iOS 18+ (platform differences are behind `#if os(iOS)`).

```bash
xcodebuild -project iGreenLight.xcodeproj -scheme iGreenLight-iOS -destination 'id=<device UDID>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <device UDID> build/Build/Products/Debug-iphoneos/iGreenLight.app
```

The app icon is `Platforms/iOS/Assets.xcassets`; `scripts/make-ios-icon.swift` regenerates it from the artwork.

### Controller navigation

Both apps use the same console-style interface (`Sources/UI/XboxTheme.swift`) and can be driven entirely with a controller
(`Sources/Input/PadNavigator.swift`): D-pad or left stick to move, A to select, B to go back, LB / RB to switch tabs,
left / right to change a setting. The arrow keys, Return and Escape do the same. During a stream the controller belongs to
the game; clicking both sticks together (L3 + R3) opens the stream menu. The Microsoft sign-in page is a web page and still
needs touch or a mouse. `--ui-demo` (debug builds) shows the signed-in screens with made-up consoles and games.

What differs from the Mac app:

* The stream is a full-screen cover, landscape only, and keeps the screen awake. Its buttons are a row at the top; with a
  controller connected they become a column on the right-hand edge, where iPhone Duo places an app's controls, in the
  black bar beside the picture when there is one. In a window taller than wide (iPhone Duo's inner display, which doesn't
  honour the landscape request) the on-screen gamepad keeps to a band along the bottom and the picture moves to the top.
* On-screen gamepad (`Sources/Input/TouchGamepad.swift`) while no controller is connected; rumble goes to the phone's Taptic Engine.
  Settings → Input → "Try on-screen controls" shows it without a stream (`--touch-test` opens it at launch and logs every change).
* Hardware keyboards go through `GCKeyboard`, with the same mapping as on the Mac.
* Sign-in opens the Microsoft page in an in-app Safari sheet.
* The log and diagnostics are in the app's Documents folder (Files → On My iPhone → iGreenLight).
* Default quality is 1080p HQ. Audio plays through its own 48 kHz stereo output unit (`Sources/Streaming/GameAudioDevice.swift`), not libwebrtc's call-oriented iOS device; nothing is captured from the microphone.
* The Simulator SDK has no MetalFX and no VideoToolbox ML scaler, so both are compiled out there; devices have them.

Signing is set in `Config/Signing.xcconfig`, which signs ad hoc by default: enough to build and run the Mac app.
For your own team (needed to run on an iPhone or iPad), copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`
and put your team ID there; that file is not in git.

## Features

* Microsoft sign-in with the device-code flow (same client id as Greenlight). The tokens are stored in the Keychain.
* Console list from `/v6/servers/home`, with the SmartGlass device list as a fallback.
* Remote Play: session start, `/connect` with the console transfer token, SDP/ICE over HTTP, Teredo
  candidate decoding, and the console's `serverDetails` address added as an extra ICE candidate. Keepalive runs every 30 s.
* Data channels `control`, `input`, `message` and `chat`: handshake, `dimensionschanged`, transactions
  (server disconnect, message dialogs).
* Rendering: CVPixelBuffer (NV12) is converted from YUV to RGB in Metal, upscaled with MetalFX Spatial, and drawn as fit, zoom or stretch.
* Input: GameController pads (up to 4) with rumble through CoreHaptics. The keyboard can act as a virtual gamepad.
  Mouse-and-keyboard mode (Settings → Input, or the stream menu; experimental) sends the keyboard and mouse to the game as
  themselves (`Sources/Input/MouseInput.swift`): on the Mac, click the picture to capture the pointer and press ⌘ to release it.
  View+Menu together act as the Xbox button.
* Audio is played by libwebrtc's CoreAudio device module on the Mac (see the iPhone section for iOS).
* Cloud Gaming: the Game Pass library (`/v2/titles` plus catalog.gamepass.com box art), queue / wait times.
* Settings: 720p / 1080p / 1080p HQ (device-info OS `android` / `windows` / `tizen`), an experimental 16:10
  request, scaling mode, MetalFX on/off, region override, and a stats overlay.

The log is written to `~/Library/Containers/app.igreenlight.iGreenLight/Data/Library/Application Support/iGreenLight/iGreenLight.log`.
You can also open it from the app's Log tab.

## Diagnostics

Settings → Experimental: Diagnostics records each stream to `diagnostics/<timestamp>/` next to the log.
It captures the gssv HTTP calls (tokens stripped), the SDP offer and answer with a parsed summary, data-channel messages, getStats
every second, decoded-frame pixel formats and colour/HDR attachments, and SPS/SEI parsed from the bitstream. The same section has
switches to compare codec (H.264 profiles, HEVC Main/Main 10 via a VideoToolbox decoder, VP9, AV1), client profile, bitrate ceiling
and reported display size. `--diagnostics-selftest` (debug builds) checks the capture offline. The files a capture contains are listed at the top of
`Sources/Diagnostics/DiagnosticsRecorder.swift`.
