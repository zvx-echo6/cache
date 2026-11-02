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
