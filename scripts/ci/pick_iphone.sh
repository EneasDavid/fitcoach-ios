#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest iOS runtime. Never an iPad: the UI suite is iPhone-only by design.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    return tuple(int(n) for n in re.findall(r"\d+", runtime.split("iOS-")[-1])) if "iOS-" in runtime else ()
best = None
for runtime in sorted((r for r in devices if "iOS" in r), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone") and d.get("isAvailable", True)]
    if phones:
        best = phones[0]["udid"]
        break
if not best:
    sys.exit("no iPhone simulator available")
print(best)
'
