#!/bin/zsh
# Runs a probe spec headlessly against your console and prints one line per hypothesis.
#   scripts/probe.sh probes/codecs.json
# The app is sandboxed, so the spec is copied into its container (…/Application Support/iGreenLight/probes/) and results land there.
# Debug builds only: the probe isn't compiled into release builds.
set -e
SPEC=${1:?usage: probe.sh <spec.json>}
ROOT=${0:A:h:h}
APP="$ROOT/build/Build/Products/Debug/iGreenLight.app"
DIR="$HOME/Library/Containers/app.igreenlight.iGreenLight/Data/Library/Application Support/iGreenLight/probes"
mkdir -p "$DIR"
NAME=${SPEC:t:r}-$(date +%H%M%S)
cp "$SPEC" "$DIR/$NAME.json"
OUT="$DIR/$NAME.results.jsonl"
pkill -f "iGreenLight.app/Contents/MacOS/iGreenLight" 2>/dev/null && sleep 1 || true
# -ApplePersistenceIgnoreState: never restore (and auto-start) a previous stream window.
open -W -n "$APP" --args --probe "$DIR/$NAME.json" --probe-out "$OUT" -ApplePersistenceIgnoreState YES -diagnosticsEnabled NO
python3 "$ROOT/scripts/probe-report.py" "$OUT"
echo "results: $OUT"
