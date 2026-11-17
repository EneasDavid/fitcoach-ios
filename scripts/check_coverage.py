#!/usr/bin/env python3
"""Coverage gate over an `llvm-cov export -summary-only` JSON file.

Gate: every module under Sources/ *and* the total must reach --min percent line coverage.

What counts: everything under Sources/ except SwiftUI view bodies (`/Views/`). Those are declarative
layout with no logic — all behaviour lives in view models, which ARE counted — and are verified by the
XCUITest suite instead. The figure *including* views is printed too, so the exclusion is never hidden.
"""
import argparse
import collections
import json
import re
import sys

EXCLUDED = re.compile(r"/Views/")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report")
    parser.add_argument("--min", type=float, default=70.0)
    args = parser.parse_args()

    with open(args.report) as handle:
        files = json.load(handle)["data"][0]["files"]

    counted = collections.defaultdict(lambda: [0, 0])
    with_views = [0, 0]
    excluded_files = []
    low_files = []

    for entry in files:
        match = re.search(r"/Sources/([^/]+)/(.*)", entry["filename"])
        if not match:
            continue
        module, path = match.groups()
        lines = entry["summary"]["lines"]
        with_views[0] += lines["covered"]
        with_views[1] += lines["count"]
        if EXCLUDED.search(entry["filename"]):
            excluded_files.append(path)
            continue
        counted[module][0] += lines["covered"]
        counted[module][1] += lines["count"]
        if lines["count"] and lines["percent"] < args.min:
            low_files.append((lines["percent"], f"{module}/{path}", lines["covered"], lines["count"]))

    total = [sum(v[0] for v in counted.values()), sum(v[1] for v in counted.values())]

    def pct(pair):
        return 100.0 * pair[0] / pair[1] if pair[1] else 100.0

    print(f"\n{'module':<18}{'covered':>9}{'lines':>8}{'coverage':>10}")
    failed = []
    for module in sorted(counted):
        value = pct(counted[module])
        flag = "" if value >= args.min else "  ✗ below gate"
        print(f"{module:<18}{counted[module][0]:>9}{counted[module][1]:>8}{value:>9.1f}%{flag}")
        if value < args.min:
            failed.append(module)
    print(f"{'TOTAL':<18}{total[0]:>9}{total[1]:>8}{pct(total):>9.1f}%")
    print(f"\nincluding SwiftUI views ({len(excluded_files)} files): {pct(with_views):.1f}%")

    if low_files:
        print("\nfiles under the gate (not fatal on their own):")
        for percent, name, covered, count in sorted(low_files):
            print(f"  {percent:5.1f}%  {name}  ({covered}/{count})")

    if pct(total) < args.min:
        failed.append("TOTAL")
    if failed:
        print(f"\nFAIL: coverage below {args.min:.0f}% for: {', '.join(failed)}")
        return 1
    print(f"\nOK: every module and the total are at or above {args.min:.0f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
