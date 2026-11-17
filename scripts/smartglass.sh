#!/bin/zsh
# Headless SmartGlass probe of the console on the LAN: scripts/smartglass.sh <console-ip> [broadcast]
# With a second argument it also sends a legacy StartGameStream request (then StopGameStream).
# Results (JSON lines) land in the app's container (…/Application Support/iGreenLight/probes/). Debug builds only.
set -e
IP=${1:?usage: smartglass.sh <console-ip>}
ROOT=${0:A:h:h}
APP="$ROOT/build/Build/Products/Debug/iGreenLight.app"
DIR="$HOME/Library/Containers/app.igreenlight.iGreenLight/Data/Library/Application Support/iGreenLight/probes"
mkdir -p "$DIR"
OUT="$DIR/smartglass-$(date +%H%M%S).jsonl"
pkill -x iGreenLight 2>/dev/null && sleep 1 || true
open -W -n "$APP" --args --smartglass "$IP" --smartglass-out "$OUT" -ApplePersistenceIgnoreState YES -diagnosticsEnabled NO ${2:+--smartglass-broadcast}
cat "$OUT"
echo "results: $OUT"
