# Cache guide tools

The guide is the set of Markdown chapters in `docs/guide/` (`ch1.md` to `ch7.md`). The on-phone assistant searches it as a
library. Every `## Section` becomes one searchable entry.

## The title rule

A section's title is exactly `Cache guide: <chapter heading>: <section heading>`, for example
`Cache guide: 1. Getting started: Choose a model`. The assistant sees one section at a time, so each section must stand on
its own: say where things are (`"Settings" > "Storage"`), give numbered steps, use short plain sentences. Section headings must
be unique within a chapter. Quote UI labels in double quotes, exactly as the app writes them.

## Scripts

- `python3 tools/guide/guide_titles.py` prints `{"titles": [...]}` for every section in `docs/guide/ch*.md`, in order.
  It exits 1 and names the title if two are the same.
- `python3 tools/guide/check_labels.py CHECKOUT [CHAPTER.md ...]` checks that every quoted label in the chapters is a string
  literal in `CHECKOUT/app/lib/**/*.dart` (or core text in the Rust search core). With no chapter files it reads the `ch*.md`
  next to the script, so pass the chapters: `python3 tools/guide/check_labels.py . docs/guide/ch*.md`. It lists each label
  that is not found and exits 1 if any are missing.

Building the library: see [BUILD.md](BUILD.md).

## Screenshots

A section can show a picture of the screen it talks about: `![caption](shot:<id>)` on a line of its own. The reader shows
`app/assets/guide/shots/<id>.png` with the caption under it; the caption is also what a screen reader says. The ids and the
screen state each one shows are in [shots.txt](shots.txt). `split.py` takes the markup out, caption and all, so the library the
assistant searches never holds it, and `verify.py` fails if any is left. `ci_check.py` fails on a screenshot with no caption, an
id not in `shots.txt`, or an id with no picture.

### Making the pictures

Run the **Renders** workflow by hand with `guide=true` on the branch,
`gh workflow run renders.yml --ref <branch> -f guide=true`. It draws `app/test_shots/guide_shots_test.dart`, cuts the pictures
with `make_shots.py` and uploads them as the artifact `guide-shots-<sha>`; fetch it with
`gh run download <run id> -n guide-shots-<sha> -D app/assets/guide/shots` and commit the pictures that changed.
`regions-sheet.png` is made by hand and is never redrawn.

### The map pictures

The map itself cannot be drawn by a test (MapLibre is a platform view), so the Maps pictures and the place form get a real map in
three steps, all inside the same workflow run:

1. **Scenes.** The guide test runs with `GUIDE_MAPS=export` and writes one scene per map view to
   `app/test_shots/guide/scenes/<scene>.json`: the app's own style as the Maps screen holds it, the camera the screen asked for,
   the size and pixel ratio, the GeoJSON the screen put on the map (route, pins, position) and the images it added
   (`app/test_shots/guide_map_kit.dart`). The sample place is Arches National Park (`app/test_shots/guide_sample.dart`); every
   view stays inside the park.
2. **Render.** `node tools/guide/maps/render.mjs` draws each scene with MapLibre GL JS in the runner's headless Chrome and saves
   `app/test_shots/guide_maps/<theme>/<scene>.png`, with the scene's SHA-256 in `app/test_shots/guide_maps/scenes.lock.json`. A
   scene whose picture is already there with the same SHA-256 is not rendered again: the map pictures and the lock file are
   committed, so a run whose scenes have not changed asks for no tile at all. The style is used as it is; only the tile
   and font addresses are replaced. Fonts are the app's own (`app/assets/map/fonts`). Tiles come from the sources in
   `tools/guide/maps/sources.json`: the base map and public lands archives the app's published catalogue names, and the public
   elevation tiles the app's hillshade uses. The script prints the requests it made per host and fails above the ceilings in
   `sources.json`, or when a tile, a font or WebGL is missing, so a broken map never becomes a picture.
3. **Draw.** The guide test runs again and shows each picture where the map is. A scene with no picture, or with a picture
   rendered from another scene, fails the test.

GL JS and the phone's map are two implementations of the same style, so label placement and shading can differ a little from a
phone. The map pictures and the scenes are in the artifact `guide-maps-<sha>`. Map pictures are cut by `make_shots.py` at 256
colours with dithering (see its header). The packages of the renderer are pinned in `tools/guide/maps/package-lock.json`
(`npm ci`); nothing is installed outside the workflow's runner.

The pictures with a map: `maps-find-me`, `maps-search`, `layers-sheet`, `place-card`, `directions-panel`,
`directions-offroad`, `guidance`, `map-ring`, `map-notebook-ring`, `map-measure` and `places-edit` (the place form's small
map). When a scene changes, commit the new map pictures and `scenes.lock.json` from the artifact `guide-maps-<sha>` along with
the guide pictures cut from them.

The routes in these pictures were made by hand along the base map's road and trail lines
(`app/test_shots/guide_data/drive_route.json`, `offroad_route.json`), not recorded from the core. The heights of their
elevation charts (`drive_elevation.json`, `offroad_elevation.json`) were read from the elevation tiles the map's hillshade is
drawn from; each file says where its numbers came from. The view of every route picture is the screen's own: it fits the
route into the free part of the map that shows it larger, with nothing of it under what is over the map. The drive is in the
strip under the position chip and the map's buttons and above the scale; with Off-road chosen the panel leaves that strip no
room, and the trail is in the column between the chip and the buttons.

The pins on these maps are drawn for a 3x phone, whatever scale the test draws at: the guide test tells the screen that scale
(`kGuidePhoneScale` in `app/test_shots/guide_map_kit.dart`) and the renderer shows an added image at that many pixels per point
(`IMAGE_PIXEL_RATIO` in `maps/render.mjs`), as that phone's map does. Change the two together.
