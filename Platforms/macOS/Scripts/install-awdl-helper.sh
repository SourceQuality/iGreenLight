#!/bin/sh
# Installs the AWDL helper as a LaunchDaemon by hand, for builds that can't register it from Settings → Network
# (a build signed ad hoc). Run from inside the app bundle:
#   sudo sh iGreenLight.app/Contents/Resources/install-awdl-helper.sh            install or update
#   sudo sh iGreenLight.app/Contents/Resources/install-awdl-helper.sh uninstall  remove
set -e
label=app.igreenlight.awdl-helper
tool=/Library/PrivilegedHelperTools/$label
plist=/Library/LaunchDaemons/$label.plist

[ "$(id -u)" = 0 ] || { echo "Run this with sudo." >&2; exit 1; }
launchctl bootout "system/$label" 2>/dev/null || true
if [ "$1" = uninstall ]; then
    rm -f "$tool" "$plist"
    echo "Removed."
    exit 0
fi

mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$(dirname "$0")/../MacOS/awdl-helper" "$tool"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$tool</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
PLIST
chown root:wheel "$plist"
chmod 644 "$plist"
launchctl bootstrap system "$plist"
echo "Installed. iGreenLight now turns AWDL off while a stream is running."
