// The macOS slice of WebRTC.xcframework has the injectable audio device compiled in
// (-[RTCPeerConnectionFactory initWithEncoderFactory:decoderFactory:audioDevice:]) but doesn't ship the header
// that declares the protocol, so RTCAudioDevice.h here is a copy of the one in the iOS slice.
#import "RTCAudioDevice.h"
