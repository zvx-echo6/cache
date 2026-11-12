#!/usr/bin/env python3
"""Turns the project `flutter create` made into the CarPlay spike's scratch app. Run with the project's ios/ folder.

- Info.plist: a scene manifest with a phone scene (no storyboard: the window is built in code around the shared engine) and a
  CarPlay scene, multiple scenes left off as in the product; no main storyboard; a short name under the icon.
- The app icon becomes one flat magenta square, so the workflow can find it on the CarPlay home screen by colour.
- The deployment target becomes iOS 16.3, the product's.
"""
import plistlib
import re
import struct
import sys
import zlib
from pathlib import Path

ios = Path(sys.argv[1])

info_path = ios / "Runner" / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["UIApplicationSceneManifest"] = {
    "UIApplicationSupportsMultipleScenes": False,
    "UISceneConfigurations": {
        "UIWindowSceneSessionRoleApplication": [{
            "UISceneClassName": "UIWindowScene",
            "UISceneConfigurationName": "Phone",
            "UISceneDelegateClassName": "$(PRODUCT_MODULE_NAME).PhoneSceneDelegate",
        }],
        "CPTemplateApplicationSceneSessionRoleApplication": [{
            "UISceneClassName": "CPTemplateApplicationScene",
            "UISceneConfigurationName": "CarPlay",
            "UISceneDelegateClassName": "$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate",
        }],
    },
}
info.pop("UIMainStoryboardFile", None)
info["CFBundleDisplayName"] = "Spike"
info_path.write_bytes(plistlib.dumps(info))
print("Info.plist: scene manifest written,", sorted(info["UIApplicationSceneManifest"]["UISceneConfigurations"]))


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
