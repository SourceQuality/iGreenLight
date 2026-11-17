# iGreenLight

A native macOS app for Xbox Remote Play (xHome) and Xbox Cloud Gaming (xCloud).
It is written in Swift and SwiftUI, uses Google's libwebrtc for transport, renders with Metal and
MetalFX Spatial upscaling, and takes input through the GameController framework. It has no Electron and no web view.

iGreenLight is a port of **[Greenlight](https://github.com/unknownskl/greenlight)** by
UnknownSKL (Jim Kroon), MIT licensed. The protocol knowledge (auth flow, gssv session API, data channel
messages, input report format) comes from Greenlight and its auth library
[xal-node](https://github.com/unknownskl/xal-node). Greenlight's license is in
[`THIRD_PARTY_LICENSES-greenlight.txt`](THIRD_PARTY_LICENSES-greenlight.txt). Ideas from
[Better xCloud](https://github.com/redphx/better-xcloud) were also used: the quality profiles chosen by the device-info OS name, and the console address used as an ICE candidate.

Not affiliated with Microsoft or Xbox.

## Requirements

* macOS 15+, Apple silicon
* Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
xcodegen generate
xcodebuild -project iGreenLight.xcodeproj -scheme iGreenLight -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/iGreenLight.app
```

Signing uses the `Apple Development` identity and team set in `project.yml`. Change
`DEVELOPMENT_TEAM` there, or use `CODE_SIGN_IDENTITY: "-"` for ad-hoc signing.

## Features

* Microsoft sign-in with the device-code flow (same client id as Greenlight). The tokens are stored in the Keychain.
* Console list from `/v6/servers/home`, with the SmartGlass device list as a fallback.
* Remote Play: session start, `/connect` with the console transfer token, SDP/ICE over HTTP, Teredo
  candidate decoding, and the console's `serverDetails` address added as an extra ICE candidate. Keepalive runs every 30 s.
* Data channels `control`, `input`, `message` and `chat`: handshake, `dimensionschanged`, transactions
  (server disconnect, message dialogs).
* Rendering: CVPixelBuffer (NV12) is converted from YUV to RGB in Metal, upscaled with MetalFX Spatial, and drawn as fit, zoom or stretch.
* Input: GameController pads (up to 4) with rumble through CoreHaptics. The keyboard can act as a virtual gamepad.
  View+Menu together act as the Xbox button.
* Audio is played by libwebrtc's CoreAudio device module.
* Cloud Gaming: the Game Pass library (`/v2/titles` plus catalog.gamepass.com box art), queue / wait times.
* Settings: 720p / 1080p / 1080p HQ (device-info OS `android` / `windows` / `tizen`), an experimental 16:10
  request, scaling mode, MetalFX on/off, region override, and a stats overlay.

The log is written to `~/Library/Containers/app.igreenlight.iGreenLight/Data/Library/Application Support/iGreenLight/iGreenLight.log`.
You can also open it from the app's Log tab.
