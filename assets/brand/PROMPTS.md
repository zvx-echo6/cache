# Cache brand assets — source and prompts

How the Cache artwork was made, so more can be made in the same style.

- `reference/branding-board.png` — the GPT branding board everything is matched to (attach it in GPT when making new assets).
- `reference/asset-sheet-preview.png` — GPT's earlier contact sheet (preview only; its cropped pack was unusable).
- `gpt-originals/` — the full-size PNGs exactly as GPT named them.
- `source/` — the same images renamed by asset number (used by the app build).

## How to make a new asset

1. In ChatGPT, attach `reference/branding-board.png`.
2. Paste one prompt below as its own message (one asset per image). For a new module tile, copy a tile prompt and change the name, icon and tile colour.
3. Download the actual PNG (not a screenshot). Add it to `source/` with the next number.
4. Flat #00FF00 green is cut out at build time (chroma key with despill), so never ask for transparency.

Palette: Forest #3B4D3A, Olive #6B7F4E, Parchment #DCC9A3, Charcoal #1A1D1F, Slate #2A3036, Clay accent #CB7A3C.

Notes on what came back: GPT renders squares at 1254×1254 and the splash at 841×1870, whatever size is asked. 02_app_icon_tile has black outside its rounded corners, so the app icon is built from 01 over 03 instead. Home came in two versions (a, b).

## Prompts

### 1 — Logo → `01_logo.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the Cache branding board. Subject: the Field Manual logo — an open book with a dark green strap and buckle down the middle, a compass rose on the right page, topo lines and a pine tree on the left page. Put it on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. Nothing else in the image: no text, no labels, no checkerboard. Square 1024×1024.
```

### 2 — App icon tile → `02_app_icon_tile.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the Cache branding board. Subject: the app icon — the Field Manual logo (open book, dark strap and buckle, compass rose, topo lines, pine tree) on its green topographic textured tile, exactly as on the board, BUT the tile fills the entire square edge to edge: no background showing, no rounded corners (the phone rounds them). No text, no labels, no checkerboard. Square 1024×1024.
```

### 3 — Icon background → `03_icon_background.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the Cache branding board. Subject: only the green topographic textured tile surface from the app icon — no book, no logo — filling the entire square edge to edge, no rounded corners, no border. No text, no labels, no checkerboard. Square 1024×1024.
```

### 4 — Splash scene → `04_splash_scene.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the Cache branding board. Subject: the splash scene — mountains, an orange sunset sun, dark pine forest and a rocky river — filling the entire frame edge to edge. NO logo and NO text anywhere. Leave a calm, slightly darker area in the upper-middle where an app will place its logo. No labels, no checkerboard. Portrait 1080×2400.
```

### 5 — Wordmark (light) → `05_wordmark_parchment.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same style as the Cache branding board. Subject: the word "Cache" in the board's bold stencil lettering, in Parchment colour (#DCC9A3) with the board's worn texture. Put it on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the width. Nothing else: no other text, no labels, no checkerboard. Size 2048×640.
```

### 6 — Wordmark (dark) → `06_wordmark_charcoal.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same style as the Cache branding board. Subject: the word "Cache" in the board's bold stencil lettering, in Charcoal colour (#1A1D1F) with the board's worn texture. Put it on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the width. Nothing else: no other text, no labels, no checkerboard. Size 2048×640.
```

### 7 — Library tile → `07_library.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Library" module tile — a parchment open-book icon on its own rounded dark slate tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 8 — Maps tile → `08_maps.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Maps" module tile — a light green folded-map icon on its own rounded dark green tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 9 — Videos tile → `09_videos.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Videos" module tile — a blue screen icon with a play triangle, on its own rounded dark blue tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 10 — Games tile → `10_games.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Games" module tile — a red-orange game-controller icon on its own rounded dark red-brown tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 11 — Journal tile → `11_journal.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Journal" module tile — a parchment notebook icon with lines, on its own rounded dark olive tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 12 — Tools tile → `12_tools.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Tools" module tile — a light grey wrench icon on its own rounded dark slate tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 13 — Weather tile → `13_weather.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Weather" module tile — a light blue cloud icon on its own rounded dark blue tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 14 — Alerts tile → `14_alerts.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Alerts" module tile — a red warning-triangle icon with an exclamation mark, on its own rounded dark red tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 15 — Shortcuts tile → `15_shortcuts.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Shortcuts" module tile — a purple 2×2 grid icon on its own rounded dark purple tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 16 — Routes tile → `16_routes.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Routes" module tile — a light green mountain-with-location-pin icon on its own rounded dark green tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 17 — Chat tile → `17_chat.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Chat" module tile — a blue speech-bubble icon on its own rounded dark blue tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 18 — Settings tile → `18_settings.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Settings" module tile — a parchment gear icon on its own rounded dark slate tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 19 — Home tile → `19_home_a.png / 19_home_b.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Home" module tile — a parchment house icon on its own rounded green tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```

### 20 — Ask tile → `20_ask.png`

```
Render this as a fresh full-resolution image — do not crop from any previous sheet. Same painted style, texture, lighting and colours as the module icons on the Cache branding board. Subject: the "Ask" module tile — a glowing parchment-and-orange brain icon with small rays, on its own rounded clay-orange tile, as on the board. Put the tile on a perfectly flat, solid pure green background (#00FF00, no gradient, no shadow on the background), centred, filling about 80% of the frame. No text, no labels, no file names, no checkerboard. Square 1024×1024.
```
