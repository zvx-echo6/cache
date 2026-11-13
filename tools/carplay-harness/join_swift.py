#!/usr/bin/env python3
"""Joins Swift files into one, for the CarPlay harness: the scratch project `flutter create` makes compiles a fixed set of
files, so the product's scene delegate and its car files (app/ios/Runner/CarPlay) go into the one the project already has.
The text of each file is kept as it is; only the import lines move to the top, once each.

    join_swift.py <out.swift> <in.swift>...
"""
import sys

out, sources = sys.argv[1], sys.argv[2:]
imports, bodies = [], []
for path in sources:
    body = []
    for line in open(path).read().splitlines():
        if line.startswith("import "):
            if line.strip() not in imports:
                imports.append(line.strip())
        else:
            body.append(line)
    bodies.append("// ---- %s\n%s\n" % (path.split("/app/ios/Runner/")[-1], "\n".join(body).strip("\n")))
open(out, "w").write("\n".join(sorted(imports)) + "\n\n" + "\n".join(bodies))
print("joined %d files into %s: %s" % (len(sources), out, ", ".join(p.split("/")[-1] for p in sources)))
