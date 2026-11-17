#!/usr/bin/env python3
"""Prints a Markdown table (setting -> codec / resolution / bitrate / bit depth / colour) from
~/Library/Containers/app.igreenlight.iGreenLight/Data/Library/Application Support/iGreenLight/diagnostics/runs.jsonl. Self-test runs are skipped unless --all."""
import json, os, sys

path = os.path.expanduser("~/Library/Containers/app.igreenlight.iGreenLight/Data/Library/Application Support/iGreenLight/diagnostics/runs.jsonl")
show_all = "--all" in sys.argv
rows = []
for line in open(path):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    s = r.get("settings", {})
    if s.get("selftest") and not show_all:
        continue
    res = r.get("result", {})
    mbps = res.get("videoMbps", {})
    bs = [b for b in res.get("bitstream", []) if b.get("nal") in ("SPS", "keyframe")]
    depth = sorted({str(b.get("bitDepthLuma")) for b in bs if b.get("bitDepthLuma")})
    colour = sorted({b.get("colour", "") for b in bs if b.get("colour")})
    hdr_sei = any(b.get("hdrSEI") for b in res.get("bitstream", []))
    rows.append([
        r.get("runId", ""),
        f'{s.get("codecPreference", "-")}{" only" if s.get("codecOnlyPreferred") else ""}',
        s.get("osName", "-"), s.get("sdkProfile", "-"),
        str(s.get("maxVideoBitrateKbps") or "-"), s.get("requestedSize", "-"),
        res.get("selectedVideoCodec", "-"),
        ", ".join(res.get("statsResolutions", [])) or "-",
        ", ".join(res.get("serverReportedVideoSizes", [])) or "-",
        f'{mbps.get("p50", "-")} / {mbps.get("max", "-")}',
        str(res.get("avgQp", {}).get("p50", "-")),
        "/".join(depth) or "-",
        "; ".join(res.get("pixelFormats", [])) or "-",
        "; ".join(colour) or "-",
        "; ".join(res.get("colorInfo", [])) or "-",
        "yes" if res.get("colorSpaceExtensionNegotiated") else "no",
        "yes" if (res.get("hdrMetadataSeen") or hdr_sei) else "no",
        r.get("endReason", ""),
    ])
hdr = ["run", "codec pref", "os.name", "identity", "b=AS kbps", "reported size", "answer codec", "decoded res",
       "server-reported size", "Mbps p50/max", "QP p50", "SPS bit depth", "pixel format", "SPS colour",
       "frame colour attachments", "color-space ext", "HDR meta", "end"]
print("| " + " | ".join(hdr) + " |")
print("|" + "---|" * len(hdr))
for r in rows:
    print("| " + " | ".join(x.replace("|", "\\|") for x in r) + " |")
