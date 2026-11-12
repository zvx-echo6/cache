#!/usr/bin/env python3
"""Finds the scratch app's icon (one flat magenta square) in a picture, for the CarPlay spike.

    find_icon.py ext  <png>                        -> the whole picture, answer in picture pixels
    find_icon.py host <png> <screen width in points> <x> <y> <w> <h>
                                                   -> only inside that window (points), answer in screen points

Prints one line: "found <x> <y> count=<n> box=<x>,<y>,<w>,<h> image=<w>x<h>" or "none image=<w>x<h> most=<n>".
The answer is the middle of the largest connected patch of magenta pixels. Standard library only: the PNG is decoded here.
"""
import struct
import sys
import zlib


def read_png(path, last_row=None):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, width, height, depth, kind, interlace = 8, [], 0, 0, 0, 0, 0
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, kind, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat.append(body)
        elif tag == b"IEND":
            break
    if interlace or kind not in (2, 6) or depth not in (8, 16):
        raise ValueError("PNG kind %d depth %d interlace %d is not handled" % (kind, depth, interlace))
    bpp = (3 if kind == 2 else 4) * (depth // 8)
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat))
    rows, prev, at = [], bytearray(stride), 0
    for y in range(height):
        if last_row is not None and y > last_row:
            rows.append(prev)
            continue
        f = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(bpp):
                line[i] = (line[i] + (prev[i] >> 1)) & 255
            for i in range(bpp, stride):
                line[i] = (line[i] + ((line[i - bpp] + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(bpp):
                line[i] = (line[i] + prev[i]) & 255
            for i in range(bpp, stride):
                a, b, c = line[i - bpp], prev[i], prev[i - bpp]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif f != 0:
            raise ValueError("PNG filter %d" % f)
        rows.append(line)
        prev = line
    step = depth // 8  # 16-bit samples: the high byte comes first
    return width, height, rows, bpp, step


def magenta_patch(width, height, rows, bpp, step, x0, y0, x1, y1):
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(width, x1), min(height, y1)
    hits = set()
    for y in range(y0, y1):
        line = rows[y]
        r = line[x0 * bpp:x1 * bpp:bpp]
        g = line[x0 * bpp + step:x1 * bpp:bpp]
        b = line[x0 * bpp + 2 * step:x1 * bpp:bpp]
        for i in range(len(r)):
            if r[i] > 170 and b[i] > 170 and g[i] < 110 and abs(r[i] - b[i]) < 80:
                hits.add((x0 + i, y))
    best, left = [], set(hits)
    while left:
        seed = left.pop()
        patch, stack = [seed], [seed]
        while stack:
            x, y = stack.pop()
            for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if n in left:
                    left.remove(n)
                    patch.append(n)
                    stack.append(n)
        if len(patch) > len(best):
            best = patch
    return best


def main():
    mode, path = sys.argv[1], sys.argv[2]
    scale, rect, last_row = 1.0, None, None
    if mode == "host":
        # The picture's width comes from its header, so only the rows down to the window's bottom edge are decoded.
        width = struct.unpack(">I", open(path, "rb").read(24)[16:20])[0]
        screen_w = float(sys.argv[3])
        x, y, w, h = [float(v) for v in sys.argv[4:8]]
        scale = width / screen_w
        rect = (int(x * scale), int(y * scale), int((x + w) * scale), int((y + h) * scale))
        last_row = rect[3]
    width, height, rows, bpp, step = read_png(path, last_row)
    if rect is None:
        rect = (0, 0, width, height)
    patch = magenta_patch(width, height, rows, bpp, step, *rect)
    if len(patch) < 150:
        print("none image=%dx%d most=%d" % (width, height, len(patch)))
        return 1
    xs, ys = [p[0] for p in patch], [p[1] for p in patch]
    bx, by, bw, bh = min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
    cx, cy = bx + bw / 2.0, by + bh / 2.0
    print("found %.1f %.1f count=%d box=%d,%d,%d,%d image=%dx%d scale=%.2f" % (cx / scale, cy / scale, len(patch), bx, by, bw, bh, width, height, scale))
    return 0


if __name__ == "__main__":
    sys.exit(main())
