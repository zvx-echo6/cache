#!/usr/bin/env python3
"""Turns the full-size golden pictures of app/test_shots/guide_shots_test.dart into the guide's assets.

Run from the repository root after `flutter test test_shots/guide_shots_test.dart --update-goldens`:
    python3 -I tools/guide/make_shots.py

Each picture is cut to the sheet or dialog it is about (test_shots/guide/crops.json, in points), or else loses the status bar's
room at the top and the empty page below the content; then it is resized to 645 px wide (LANCZOS), reduced to at most 128
colours (no dither) and saved with optimize=True into app/assets/guide/shots/<id>.png. Needs Pillow.

A picture with a real map in it (MAPS) is reduced to 256 colours with dithering instead: shaded relief breaks into bands at 128
flat colours. Its palette is an octree one, which keeps the few strong colours of a map picture (the position dot, a pin, the
route) that a median-cut palette gives up for more shades of the land; the picture's own large flat colours (a panel, a page)
are then put into it exactly, so they stay flat instead of being dithered. Its line also says what the same picture would
weigh in other forms, for choosing how map pictures ship. Where the map fills the screen (every map picture but the place
form, MAP_INSIDE) the picture is the whole screen less the status bar.
"""
import io
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
# Drawn with a rendered map: the Maps screen over its map, and the place form with its small map.
MAPS = {
    'maps-find-me', 'maps-search', 'place-card', 'directions-panel', 'directions-offroad', 'guidance', 'layers-sheet',
    'map-ring', 'map-notebook-ring', 'map-measure', 'places-edit',
}
MAP_INSIDE = {'places-edit'}  # the map is a part of the page: cut like any other page


def trim_bottom(im, bg):
    px = im.load()
    w, h = im.size
    for y in range(h - 1, 0, -1):
        for x in range(0, w, 2):
            r, g, b = px[x, y][:3]
            if abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) > 18:
                return min(h, y + 24 * RATIO)
    return h


def map_palette(im, colours=256, flats=8, share=0.02):
    """A palette for a map picture: an octree palette of [colours] colours, in which the palette colour nearest to each of the
    picture's large flat colours (up to [flats] of them, each at least [share] of the picture) is replaced by that colour."""
    pal = im.quantize(colors=colours, method=Image.Quantize.FASTOCTREE).getpalette()[:colours * 3]
    pal += [0] * (colours * 3 - len(pal))
    taken = set()
    for n, colour in sorted(im.getcolors(im.width * im.height), reverse=True)[:flats]:
        if n < share * im.width * im.height:
            break
        nearest = min((i for i in range(colours) if i not in taken), key=lambda i: sum((pal[i * 3 + k] - colour[k]) ** 2 for k in range(3)))
        pal[nearest * 3:nearest * 3 + 3] = colour
        taken.add(nearest)
    out = Image.new('P', (1, 1))
    out.putpalette(pal)
    return out


def dithered(im):
    """[im] in its map palette, with Floyd-Steinberg dithering (quantize() alone does not dither)."""
    return im.quantize(palette=map_palette(im), dither=Image.Dither.FLOYDSTEINBERG)


def weights(im):
    """What the map picture [im] (RGB, at its final size) weighs in other forms, as text for its line."""
    def size(picture, kind, **how):
        try:
            buf = io.BytesIO()
            picture.save(buf, kind, **how)
            return buf.tell()
        except Exception:  # a form this Pillow cannot write is left out
            return None

    forms = [
        ('128 colours flat', size(im.quantize(colors=128, dither=Image.Dither.NONE), 'PNG', optimize=True)),
        ('256 colours flat', size(im.quantize(colors=256, dither=Image.Dither.NONE), 'PNG', optimize=True)),
        ('full colour PNG', size(im, 'PNG', optimize=True)),
        ('WebP q80', size(im, 'WEBP', quality=80, method=6)),
        ('JPEG q85', size(im, 'JPEG', quality=85, optimize=True)),
    ]
    return ', '.join(f'{name} {n}' for name, n in forms if n is not None)


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
        if i in MAPS and i not in MAP_INSIDE:
            # A map fills the screen to its foot: the whole screen less the status bar, nothing below the content to cut.
            im = im.crop((0, STATUS, im.width, im.height))
        elif i in crops:
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
        im = im.resize((WIDTH, h), Image.LANCZOS)
        if i in MAPS:
            dithered(im).save(f'{OUT}/{i}.png', optimize=True)
            print(i, im.size, os.path.getsize(f'{OUT}/{i}.png'), '(256 colours dithered; otherwise:', weights(im) + ')')
        else:
            im = im.quantize(colors=128, dither=Image.Dither.NONE)
            im.save(f'{OUT}/{i}.png', optimize=True)
            print(i, im.size, os.path.getsize(f'{OUT}/{i}.png'))


if __name__ == '__main__':
    sys.exit(main())
