#!/usr/bin/env python3
"""Writes the recorded car messages as a Dart file for the harness's stand-in Dart side.

    recorded_dart.py <folder of recorded .json> <out.dart>
"""
import json
import sys
from pathlib import Path

folder, out = Path(sys.argv[1]), Path(sys.argv[2])
lines = ["// Made by tools/carplay-harness/recorded_dart.py from tools/carplay-harness/recorded. Not kept in the repository.", "", "const Map<String, String> recorded = <String, String>{"]
for path in sorted(folder.glob("*.json")):
    text = json.dumps(json.loads(path.read_text()), separators=(",", ":"))
    assert "'''" not in text
    lines.append("  '%s': r'''%s'''," % (path.stem, text))
lines.append("};")
out.write_text("\n".join(lines) + "\n")
print("recorded messages for the stand-in Dart side: %s" % ", ".join(p.stem for p in sorted(folder.glob("*.json"))))
