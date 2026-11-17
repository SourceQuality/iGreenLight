#!/usr/bin/env python3
"""Per-second timeline of one diagnostics capture, with the probe's timed control messages and anything the
console sent on the control channel interleaved: scripts/probe-timeline.py <capture-dir>"""
import json, sys, os
d = sys.argv[1]
rows = []
def load(name):
    p = os.path.join(d, name)
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []
for s in load("stats.jsonl"):
    v = s.get("video", {})
    rows.append((s["t"], "  %sx%s %5s fps %6s Mbps  key+%s  loss %s%%" % (
        v.get("frameWidth", "-"), v.get("frameHeight", "-"), v.get("fpsDecoded", "-"), v.get("videoMbps", "-"),
        v.get("keyframesThisSecond", "-"), v.get("lossPercent", "-"))))
for e in load("events.jsonl"):
    if e.get("event") == "probe.control":
        rows.append((e["t"], ">> SENT " + json.dumps(e["message"], sort_keys=True)))
for m in load("datachannels.jsonl"):
    if m.get("dir") == "recv" and m.get("channel") in ("control", "message"):
        rows.append((m["t"], "<< %s %s" % (m["channel"], json.dumps(m.get("decoded"), sort_keys=True)[:200])))
    elif m.get("dir") == "recv" and m.get("channel") == "input" and m.get("kind") not in (None, "vibration"):
        rows.append((m["t"], "<< input %s" % json.dumps(m.get("decoded") or m.get("kind"))[:160]))
for t, line in sorted(rows):
    print("%6.1f %s" % (t, line))
