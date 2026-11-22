#!/usr/bin/env python3
"""MapLibre's native SDK must come from one place on each platform, so the app never ships it twice.

Android: the app declares MapLibre's SDK itself for the whole-route picture (RouteSnapshot.kt), the same artifact the maplibre_gl
plugin brings in. This fails when the app's version and the plugin's differ.

iOS: the app does not pin MapLibre. The maplibre_gl plugin brings it in through its Swift package (Flutter's Swift Package Manager
integration), and RouteSnapshot (AppDelegate.swift) imports it from there. So there is no app version to compare. The real risk is
someone re-adding `pod 'MapLibre'` to app/ios/Podfile, which embeds a second MapLibre.framework and breaks the archive ("Multiple
commands produce ... Runner.app/Frameworks/MapLibre.framework"). This fails if the Podfile declares a MapLibre pod at all, and prints
the plugin's MapLibre version for information.

The iOS job in .github/workflows/map-bench.yml builds a scratch project with CocoaPods and so carries its own literal
`POD="pod 'MapLibre', 'X'"`. This also fails if that X differs from the plugin's version.

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
    pod_line = re.compile(r"""^\s*pod\s+['"]MapLibre['"]""", re.MULTILINE)
    spm_pattern = r'exact:\s*"([^"]+)"'
    plugin_android = one(android_pattern, (plugin / "android" / "build.gradle").read_text(), "the plugin's android/build.gradle")
    app_android = one(android_pattern, (APP / "android" / "app" / "build.gradle.kts").read_text(), "app/android/app/build.gradle.kts")
    plugin_ios = one(spm_pattern, (plugin / "ios" / "maplibre_gl" / "Package.swift").read_text(), "the plugin's ios/maplibre_gl/Package.swift")
    bench_text = (ROOT / ".github" / "workflows" / "map-bench.yml").read_text()
    bench_ios = one(r'POD="pod \'MapLibre\',\s*\'([^\']+)\'"', bench_text, ".github/workflows/map-bench.yml")
    podfile_pod = pod_line.search((APP / "ios" / "Podfile").read_text())
    print(f"maplibre_gl at {plugin}")
    print(f"Android: plugin {plugin_android}, app {app_android}")
    print(f"iOS: plugin brings MapLibre {plugin_ios} through its Swift package; the app declares no MapLibre pod: {not podfile_pod}")
    bad = []
    if plugin_android != app_android:
        bad.append(f"app/android/app/build.gradle.kts declares android-sdk-opengl {app_android}; maplibre_gl uses {plugin_android}")
    if podfile_pod:
        bad.append("app/ios/Podfile declares a MapLibre pod; maplibre_gl already brings MapLibre in through its Swift package, "
                   "and a pod embeds a second MapLibre.framework (the archive fails with 'Multiple commands produce')")
    if bench_ios != plugin_ios:
        bad.append(f".github/workflows/map-bench.yml builds the iOS snapshotter against MapLibre {bench_ios}; maplibre_gl uses {plugin_ios}")
    if bad:
        sys.exit("\n".join(bad))
    print("MapLibre is declared once on each platform")


if __name__ == "__main__":
    main()
