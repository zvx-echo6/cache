#!/usr/bin/env python3
"""Makes the OCR test's page images: grayscale PNGs of US Letter pages, as the core's ingest job renders them for OCR
(packages/cache_ingest/INGEST-API.md: grayscale, 300 dpi by default), from known text, made to look scanned.

    python3 make_fixtures.py OUT_DIR

Writes OUT_DIR/<page>.png and OUT_DIR/expected.json ({"pages": [{page, file, dpi, width, height, text, phrase}]}). Run in CI by
.github/workflows/ocr.yml (Pillow on the runner, DejaVu fonts); the integration test reads them as assets.
"""
import json
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

PHRASE1 = "Boil water for one full minute before drinking it"
PHRASE2 = "Keep the signal mirror in your left chest pocket"

PAGE1 = [
    "Chapter 3. Safe Water",
    "",
    "Water from streams, lakes and springs can carry germs that make you sick even when it looks clear. "
    f"{PHRASE1}. At elevations above two thousand meters, boil it for three minutes. "
    "Let the water cool on its own and keep it in a clean, covered container.",
    "",
    "If you cannot boil water, filter it through a clean cloth and treat it with household bleach: "
    "eight drops for every gallon, stirred and left to stand for thirty minutes.",
]

PAGE2 = [
    "Signalling for help",
    "",
    "Three of anything is a call for help: three fires, three whistle blasts, three flashes of light. "
    f"{PHRASE2} so you can reach it without taking off your pack. "
    "Sweep the flash slowly across the horizon, even when you see no aircraft, because a pilot can see it from far away.",
]

FONTS = {
    "sans": ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"],
    "serif": ["/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf", "/System/Library/Fonts/Supplemental/Times New Roman.ttf"],
}


def font(kind, px):
    for path in FONTS[kind]:
        if Path(path).exists():
            return ImageFont.truetype(path, px)
    raise SystemExit(f"no {kind} font")


def wrap(draw, text, f, width):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=f) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    lines.append(line)
    return lines


def page(paragraphs, dpi, pt, kind, seed):
    w, h = round(8.5 * dpi), round(11 * dpi)
    paper = 238
    img = Image.new("L", (w, h), paper)
    if paragraphs:
        d = ImageDraw.Draw(img)
        f = font(kind, round(pt / 72 * dpi))
        lead = round(pt / 72 * dpi * 1.35)
        y = margin = dpi
        for para in paragraphs:
            for line in wrap(d, para, f, w - 2 * margin) if para else [""]:
                d.text((margin, y), line, font=f, fill=40)
                y += lead
    rnd = random.Random(seed)
    # a scanner's look: turned a little, softened, speckled
    img = img.rotate(0.6, resample=Image.BICUBIC, fillcolor=paper)
    img = img.filter(ImageFilter.GaussianBlur(0.6 * dpi / 300))
    noise = Image.effect_noise((w, h), 10)
    img = Image.blend(img, noise.point(lambda v: v - 128 + paper), 0.12)
    d = ImageDraw.Draw(img)
    for _ in range(w * h // 40000):
        x, y = rnd.randrange(w), rnd.randrange(h)
        d.point((x, y), fill=90)
    return img


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    specs = [
        (1, PAGE1, 300, 11, "serif", PHRASE1),
        (2, PAGE2, 300, 9, "sans", PHRASE2),
        (3, [], 300, 11, "sans", None),
        # the same small-type page at 200 dpi: what a lower ocr_dpi costs in accuracy and saves in time and memory
        (4, PAGE2, 200, 9, "sans", PHRASE2),
    ]
    pages = []
    for n, paras, dpi, pt, kind, phrase in specs:
        img = page(paras, dpi, pt, kind, n)
        name = f"{n}.png"
        img.save(out / name, dpi=(dpi, dpi), optimize=True)
        pages.append({"page": n, "file": name, "dpi": dpi, "width": img.width, "height": img.height, "pt": pt, "font": kind,
                      "text": "\n".join(paras), "phrase": phrase})
        print(f"{name}: {img.mode} {img.width}x{img.height} at {dpi} dpi, {(out / name).stat().st_size // 1024} KB")
    (out / "expected.json").write_text(json.dumps({"pages": pages}, indent=1))


if __name__ == "__main__":
    main()
