# Security policy

## Supported versions

Only the latest release and the latest commit on `main` are supported.

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability** and describe the problem.

This opens a private advisory that only the maintainer can see. You can expect a first reply within a week. If the
report is confirmed, the fix is published first and the advisory afterwards, with credit to you unless you'd rather
not be named.

## What counts

iGreenLight signs in to a Microsoft account and stores its tokens in the Keychain, so these matter most:

- anything that exposes tokens or other credentials: in the log, in a diagnostics capture, on disk or over the network;
- anything that lets another app, a web page or someone on the local network take over a session or the sign-in;
- memory-safety problems in the code that parses data from the network (the input channel, the SDP and bitstream parsers).

Problems in Microsoft's services, in libwebrtc or in Greenlight belong with those projects.
