#!/usr/bin/env python3
"""The app declares MapLibre's native SDK itself for the whole-route picture (RouteSnapshot.kt, AppDelegate.swift): the same artifact
the maplibre_gl plugin brings in. This fails when the app's version and the plugin's differ, so the two never drift apart.

Run from the repository root after `flutter pub get` in app/ (it reads app/.dart_tool/package_config.json to find the plugin):
    python3 -I tools/check_maplibre_pin.py
"""
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"


def plugin_dir() -> Path:
    cfg = json.loads((APP / ".dart_tool" / "package_config.json").read_text())
    for p in cfg["packages"]:
        if p["name"] == "maplibre_gl":
            uri = p["rootUri"]
            if uri.startswith("file://"):
                return Path(unquote(urlparse(uri).path))
            return (APP / ".dart_tool" / uri).resolve()
    sys.exit("maplibre_gl is not in app/.dart_tool/package_config.json (run flutter pub get in app/ first)")


def one(pattern: str, text: str, where: str) -> str:
    found = sorted(set(re.findall(pattern, text)))
    if len(found) != 1:
        sys.exit(f"expected one MapLibre version in {where}, found {found or 'none'}")
    return found[0]


def main() -> None:
    plugin = plugin_dir()
    android_pattern = r"org\.maplibre\.gl:android-sdk-opengl:([0-9][0-9A-Za-z.\-]*)"
    pod_pattern = r"""['"]MapLibre['"]\s*,\s*['"]([^'"]+)['"]"""
    plugin_android = one(android_pattern, (plugin / "android" / "build.gradle").read_text(), "the plugin's android/build.gradle")
    app_android = one(android_pattern, (APP / "android" / "app" / "build.gradle.kts").read_text(), "app/android/app/build.gradle.kts")
    plugin_ios = one(pod_pattern, (plugin / "ios" / "maplibre_gl.podspec").read_text(), "the plugin's ios/maplibre_gl.podspec")
    app_ios = one(pod_pattern, (APP / "ios" / "Podfile").read_text(), "app/ios/Podfile")
    print(f"maplibre_gl at {plugin}")
    print(f"Android: plugin {plugin_android}, app {app_android}")
    print(f"iOS: plugin {plugin_ios}, app {app_ios}")
    bad = []
    if plugin_android != app_android:
        bad.append(f"app/android/app/build.gradle.kts declares android-sdk-opengl {app_android}; maplibre_gl uses {plugin_android}")
    if plugin_ios != app_ios:
        bad.append(f"app/ios/Podfile pins MapLibre {app_ios}; maplibre_gl uses {plugin_ios}")
    if bad:
        sys.exit("\n".join(bad))
    print("MapLibre versions match")


if __name__ == "__main__":
    main()
