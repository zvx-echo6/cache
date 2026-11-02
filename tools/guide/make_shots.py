#!/usr/bin/env python3
"""Turns the full-size golden pictures of app/test_shots/guide_shots_test.dart into the guide's assets.

Run from the repository root after `flutter test test_shots/guide_shots_test.dart --update-goldens`:
    python3 -I tools/guide/make_shots.py

Each picture is cut to the sheet or dialog it is about (test_shots/guide/crops.json, in points), or else loses the status bar's
room at the top and the empty page below the content; then it is resized to 645 px wide (LANCZOS), reduced to at most 128
colours (no dither) and saved with optimize=True into app/assets/guide/shots/<id>.png. Needs Pillow.
"""
import json
import os
import sys

from PIL import Image

SRC = 'app/test_shots/guide'
OUT = 'app/assets/guide/shots'
WIDTH = 645
RATIO = 2  # the goldens are drawn at 2x
STATUS = 54 * RATIO  # the room the test leaves for the phone's status bar
KEEP = {'regions-sheet'}  # made by hand earlier; left as it is


def trim_bottom(im, bg):
    px = im.load()
    w, h = im.size
    for y in range(h - 1, 0, -1):
        for x in range(0, w, 2):
            r, g, b = px[x, y][:3]
            if abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) > 18:
                return min(h, y + 24 * RATIO)
    return h


def main():
    crops = json.load(open(f'{SRC}/crops.json'))
    os.makedirs(OUT, exist_ok=True)
    for name in sorted(os.listdir(SRC)):
        if not name.endswith('.png'):
            continue
        i = name[:-4]
        if i in KEEP:
            continue
        im = Image.open(f'{SRC}/{name}').convert('RGB')
        if i in crops:
            l, t, r, b = [round(v * RATIO) for v in crops[i]]
            im = im.crop((l, t, r, b))
            if i == 'chat-list':  # a drawer is as tall as the screen: the empty part under the chats is cut
                im = im.crop((0, 0, im.width, max(trim_bottom(im, im.getpixel((4, im.height // 2))), 520 * RATIO)))
        else:
            bg = im.getpixel((4, STATUS + 4))
            body = im.crop((0, STATUS, im.width, im.height))
            h = max(trim_bottom(body, bg), 520 * RATIO)
            im = body.crop((0, 0, body.width, min(h, body.height)))
        h = round(im.height * WIDTH / im.width)
        im = im.resize((WIDTH, h), Image.LANCZOS).quantize(colors=128, dither=Image.Dither.NONE)
        im.save(f'{OUT}/{i}.png', optimize=True)
        print(i, im.size, os.path.getsize(f'{OUT}/{i}.png'))


if __name__ == '__main__':
    sys.exit(main())
