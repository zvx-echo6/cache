#!/usr/bin/env python3
"""Convert a trained division classifier (model.json + W_*.bin + bias_f32_*.bin) into a cache-classifier-<version>.bin file.

Python standard library only. The file layout is documented in packages/cache_classify/README.md.

  make_classifier_model.py --weights DIR --divisions divisions.md --version 2 \
      --embedding-sha256 <hex> --threshold 0.4640781879425049 [--f16] [--out cache-classifier-2.bin]

DIR holds model.json (class order), bias_f32_<n>.bin and W_f32_<dims>x<n>.bin (or W_f16_...). Labels come from the library's
divisions.md ("- 310 - Gardening: description" lines); every class in model.json must have one.
"""
import argparse
import glob
import json
import os
import re
import struct
import sys
import zlib

MAGIC = b"CCLS"
FORMAT_VERSION = 1
RECIPE_MEAN_L2 = 1


def read_labels(path):
    labels = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^- (\d{3}) - ([^:]*?)\s*(?::.*)?$", line.rstrip("\n"))
            if m and m.group(2) and "(unassigned)" not in m.group(2):
                labels[m.group(1)] = m.group(2).strip()
    return labels


def build(weights_dir, divisions, version, sha_hex, threshold, first, spread, use_f16):
    meta = json.load(open(os.path.join(weights_dir, "model.json")))
    classes = meta["classes"]
    dims = int(meta["input_dim"])
    n = len(classes)
    labels = read_labels(divisions)
    missing = [c for c in classes if c not in labels]
    if missing:
        sys.exit("no label in divisions file for: " + ", ".join(missing))
    sha = bytes.fromhex(sha_hex)
    if len(sha) != 32:
        sys.exit("--embedding-sha256 must be 64 hex digits")
    if not (0.0 <= threshold <= 1.0):
        sys.exit("--threshold must be between 0 and 1")
    wfile = os.path.join(weights_dir, "W_%s_%dx%d.bin" % ("f16" if use_f16 else "f32", dims, n))
    wbytes = open(wfile, "rb").read()
    want = dims * n * (2 if use_f16 else 4)
    if len(wbytes) != want:
        sys.exit("%s is %d bytes, expected %d" % (wfile, len(wbytes), want))
    bfile = glob.glob(os.path.join(weights_dir, "bias_f32_*.bin"))[0]
    bbytes = open(bfile, "rb").read()
    if len(bbytes) != n * 4:
        sys.exit("%s is %d bytes, expected %d" % (bfile, len(bbytes), n * 4))

    out = bytearray()
    out += MAGIC
    out += struct.pack("<HH", FORMAT_VERSION, 1 if use_f16 else 0)
    out += struct.pack("<III", version, dims, n)
    out += sha
    out += struct.pack("<d", threshold)
    out += struct.pack("<BBHH", RECIPE_MEAN_L2, 0, first, spread)
    for c in classes:
        label = labels[c].encode("utf-8")
        if len(label) > 255:
            sys.exit("label too long: " + c)
        out += struct.pack("<HB", int(c), len(label)) + label
    out += bbytes
    out += wbytes
    out += struct.pack("<I", zlib.crc32(bytes(out)) & 0xFFFFFFFF)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--weights", required=True, help="folder with model.json, W_*.bin and bias_f32_*.bin")
    ap.add_argument("--divisions", required=True, help="divisions.md with the division labels")
    ap.add_argument("--version", required=True, type=int, help="classifier version (a whole number)")
    ap.add_argument("--embedding-sha256", required=True, help="SHA-256 (hex) of the embedding model file")
    ap.add_argument("--threshold", required=True, type=float, help="top probability below this is Unsorted")
    ap.add_argument("--first", type=int, default=8, help="recipe: first pieces kept (default 8)")
    ap.add_argument("--spread", type=int, default=16, help="recipe: further pieces spread evenly (default 16)")
    ap.add_argument("--f16", action="store_true", help="write float16 weights instead of float32")
    ap.add_argument("--out", help="output file (default cache-classifier-<version>.bin)")
    a = ap.parse_args()
    data = build(a.weights, a.divisions, a.version, a.embedding_sha256, a.threshold, a.first, a.spread, a.f16)
    out = a.out or "cache-classifier-%d.bin" % a.version
    with open(out, "wb") as f:
        f.write(data)
    print("%s: %d bytes, version %d, %s weights" % (out, len(data), a.version, "f16" if a.f16 else "f32"))


if __name__ == "__main__":
    main()
