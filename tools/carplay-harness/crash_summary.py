#!/usr/bin/env python3
"""Prints the useful part of a macOS crash report (.ips): why the process died and where. For the CarPlay spike.

    crash_summary.py <report.ips>
"""
import json
import sys

text = open(sys.argv[1], errors="replace").read()
head, _, body = text.partition("\n")
try:
    first = json.loads(head)
    report = json.loads(body)
except ValueError as e:
    print("not the two-part JSON report expected:", e)
    print(text[:3000])
    sys.exit(0)

print("process: %s  version: %s  os: %s" % (first.get("app_name"), first.get("app_version"), first.get("os_version")))
print("time: %s  launched: %s" % (report.get("captureTime"), report.get("procLaunch")))
print("exception:", json.dumps(report.get("exception")))
print("termination:", json.dumps(report.get("termination")))
for key in ("asi", "ktriageinfo", "vmSummary"):
    if key in report and key != "vmSummary":
        print("%s: %s" % (key, json.dumps(report[key])[:3000]))
images = report.get("usedImages", [])


def show(frames, limit):
    for n, frame in enumerate(frames[:limit]):
        image = images[frame.get("imageIndex", -1)] if 0 <= frame.get("imageIndex", -1) < len(images) else {}
        print("  %2d  %-32s %s + %s" % (n, image.get("name", "?"), frame.get("symbol", "0x%x" % frame.get("imageOffset", 0)), frame.get("symbolLocation", "")))


last = report.get("lastExceptionBacktrace")
if last:
    print("last exception backtrace:")
    show(last, 40)
for thread in report.get("threads", []):
    if thread.get("triggered"):
        print("crashed thread (%s, queue %s):" % (thread.get("name", "unnamed"), thread.get("queue", "?")))
        show(thread.get("frames", []), 40)
