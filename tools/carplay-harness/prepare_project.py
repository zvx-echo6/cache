#!/usr/bin/env python3
"""Readies the scratch project of the CarPlay harness. Run with the project's ios/ folder.

- The app icon becomes one flat magenta square, so the job can find it on the CarPlay home screen by colour.
- The deployment target becomes iOS 16.3, the product's.
"""
import re
import struct
import sys
import zlib
from pathlib import Path

ios = Path(sys.argv[1])


def flat_png(width, height, rgb):
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    rows = (b"\x00" + bytes(rgb) * width) * height
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


icons = sorted((ios / "Runner" / "Assets.xcassets" / "AppIcon.appiconset").glob("*.png"))
for icon in icons:
    width, height = struct.unpack(">II", icon.read_bytes()[16:24])
    icon.write_bytes(flat_png(width, height, (255, 0, 255)))
print("app icon: %d pictures made flat magenta" % len(icons))

project_path = ios / "Runner.xcodeproj" / "project.pbxproj"
project = project_path.read_text()
project, count = re.subn(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;", "IPHONEOS_DEPLOYMENT_TARGET = 16.3;", project)
project_path.write_text(project)
print("deployment target: iOS 16.3 in %d places" % count)
