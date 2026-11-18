# Contributing to iGreenLight

Thanks for your interest. iGreenLight is a spare-time project with one maintainer, so small, focused changes are
the easiest to review and the most likely to be merged.

## Before you start

- **Bugs:** open an issue with the bug report form. Say which device and OS you use, whether it was Remote Play or
  cloud gaming, and what you expected.
- **Features:** open an issue first and describe the idea. It saves you from building something that doesn't fit.
- **Security problems:** do not open a public issue. See [SECURITY.md](SECURITY.md).

### Logs

The app's log (Settings → Log) helps a lot with stream problems. It holds no tokens, but it does hold your console's
name and ID, session IDs and the IP addresses of both ends. Remove what you don't want public before attaching it.

## Building

You need Xcode 26 or later on an Apple silicon Mac.

```sh
xcodebuild -project iGreenLight.xcodeproj -scheme iGreenLight -derivedDataPath build build
```

The Mac app signs ad hoc out of the box. To run on an iPhone or iPad, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and put your Apple Developer team ID in it. That file is ignored by git; keep it that way.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you add,
remove or rename files, run `xcodegen generate` and commit the regenerated project along with your change.

## Testing

```sh
xcodebuild test -project iGreenLight.xcodeproj -scheme iGreenLight -derivedDataPath build -destination 'platform=macOS,arch=arm64'
```

The unit tests need no account and no network. Debug builds also have two offline helpers:

- `--diagnostics-selftest` runs loopback WebRTC calls against a local fake server and checks the capture.
- `--ui-demo` shows the signed-in screens with made-up consoles and games, for interface work without an account.

Streaming itself can only be checked against a real console or a cloud session. If your change touches the stream,
input or the session, say in the pull request what you tried it on, and what you could not try.

## Pull requests

- One topic per pull request, with a commit message that says what changes for the user or the code and why.
- Keep the Mac and iOS targets building; both share the sources under `Sources/`.
- Add or update a unit test when the change is testable offline (packet formats, parsing, layout maths, shaders).
- Match the surrounding style: plain Swift and SwiftUI, no new dependencies without discussion.
- Never commit tokens, logs, diagnostics captures, your team ID or anything else personal.

## Scope

iGreenLight is an unofficial client. Please don't send changes whose purpose is to get around account, region or
subscription restrictions.

## Releases

Pushing a tag like `v0.2.0` runs the release workflow, which builds the unsigned iOS `.ipa` and publishes it. The
tag must match `CFBundleShortVersionString` in `project.yml`.

By contributing you agree that your contribution is licensed under the project's [MIT licence](LICENSE), and that
you follow the [code of conduct](CODE_OF_CONDUCT.md).
