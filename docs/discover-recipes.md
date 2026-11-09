# Discover recipes

Discover's activities (Ready, Backcountry, Homestead) and collections are data: one JSON file, so they change without an app
release.

- **Source:** `docs/discover-catalogue.json` (this repository).
- **In the app:** `app/assets/discover/catalogue.json`, an exact copy. `app/test/discover_recipe_test.dart` checks that the two
  are the same. The app uses this copy on first run, offline, and whenever the published file can't be read.
- **Published:** `https://data.cached.info/discover/catalogue.json` (`kDiscoverUrl`), on the same host as the region catalogue,
  the connector catalogue and the recommended models. The app fetches it when Discover starts. It keeps the fetched file only
  when the format is one it reads and its `updated` date is the same as or newer than the copy it carries.
- **Publishing:** `.github/workflows/discover-publish.yml` checks the source and uploads it to that address when
  `docs/discover-catalogue.json` changes on `rel-1.1` or `main` (or when run by hand). Bump `updated` with every change; the
  workflow refuses a date older than the published one.

## Format (`cache-discover`, version 1)

```json
{
  "format": "cache-discover",
  "version": 1,
  "updated": "2026-11-08",
  "activities": [ { activity }, ... ],
  "collections": [ { "id", "title", "tagline"?, "icon"?, "items": [ library items ] }, ... ],
  "libraries":   [ library items ]
}
```

`version` is the version of the format. A build refuses a file whose version is higher than the one it reads
(`kDiscoverVersion`) and keeps using its own copy. If a change would make old builds misread the file, bump the version. Adding an
optional field doesn't need a bump: unknown fields are ignored.

The `libraries` list holds the libraries shown in Discover's Libraries row. Each collection is a set of libraries that the person
gets together. What a collection adds belongs to the person, not to an activity.

### An activity

```json
{
  "id": "backcountry",            // [a-z0-9._-], unique
  "revision": 1,                  // goes up when the recipe changes; an added activity at a lower revision shows Update
  "title": "Backcountry",
  "tagline": "Off-grid trips and first aid",
  "description": "…",             // a sentence or two on its page
  "icon": "peak",                 // shield, peak, sprout, radio, book, map, stack
  "items": [ item, ... ],
  "settings": [ { "key": "home:weather", "value": true } ]
}
```

### Items

Items name only things Cache already offers, by the ids the app already uses. An item is the same item in every activity it
appears in (same `kind` and id), so it is downloaded once.

| kind | fields | what it is |
|---|---|---|
| `library` | `name`, `flavour`?, `title`, `subtitle`?, `approx_bytes` | A ZIM from the Kiwix catalogue, by Kiwix's machine name (`wikipedia_en_medicine`) and variant (`maxi`, `nopic`, `mini` or none). It downloads the newest release through the Library's own downloads. `approx_bytes` is shown until the live catalogue gives the real size. |
| `map_region` | `parts` (`map`, `routing`, `places`, `offroad`), `title`? | The catalogue region for the person's place (the smallest region at the place, as Regions finds it), downloaded through Regions. Another activity's region gets the parts it is missing. |
| `live_source` | `id`, `title`?, `provider`?, `default_on`? | A source from the connector catalogue or a built-in one (`nws-alerts-point`). Turning it on is a setting (`live:<id>`). `title` ("Weather alerts") and `provider` ("National Weather Service") are the plain words Discover shows; without them it shows the connector's own title and provider. |
| `notebook` | `id`, `title`? | A notebook made from one of the app's starter logs or notebook templates (`assets/notebook/starters.json`, `templates.json`), by id. |
| `checklist` | `id`, `title`, `lines` | A Notes notebook with one entry made of Markdown task lines. Supported, but Cache's own file ships none yet. |
| `ask_starters` | `id`, `lines` | Ask starter questions, kept with the activity. Supported, but Cache's own file ships none yet, and Ask doesn't show them yet. |

`default_on: false` on any item means it is offered but switched off in Customize until the person switches it on.

### Settings

An activity may change only settings Discover knows how to put back:

| key | value | meaning |
|---|---|---|
| `live:<id>` | `true` | switched on by a `live_source` item (not listed under `settings`) |
| `home:weather`, `home:shortcuts`, `home:ask` | `true`/`false` | a Home block shown or hidden |
| `watch:here` | `true`/`false` | weather and alerts watch where the device is |

A file that names any other key is refused.

## Installing and removing

The app keeps a ledger in `discover.json` (in the support folder). It records:

- for each activity: its revision, the items it holds, the items the person switched off, and every setting it changed, with that
  setting's value before;
- for each item: the activities that hold it, whether the person had it before any activity added it, and what is needed to
  remove it (the region's id, the notebook's id);
- for each setting: its value before the first activity changed it, the value set, and the activities that hold it.

**Get** comes before anything installs. The Get sheet shows the total size against the free space, every outside source the
activity connects to (Kiwix for library downloads, and the provider of each live source), and the settings it changes.
"Show everything it adds" lists every item.

**Installing:** an item not on the device is added. An item already there is counted, not downloaded again. If the person had it
before, it stays theirs. A setting is changed and its value before is recorded. A setting that already has the wanted value is
left alone, and nothing is recorded for it.

**Removing an activity:**

- An item is removed only when no other activity holds it, the person didn't have it before, and the person doesn't use it. A
  notebook with entries counts as used. A checklist counts as used once its entry has been changed.
- A setting is put back to its value before only when no other activity holds it and it still has the value the activity set.
  If the person changed it since, it stays as they set it.
- Notes, places and other personal data are never touched.

**Updating:** when an activity's revision is newer than the one that was added, the newer recipe is installed the same way.
Items and settings that the older revision held and the newer one doesn't are released, as if removed.

## Curating

Only items Cache already offers may be listed: Kiwix catalogue entries, connector ids, starter logs and templates. Nothing in
this file adds a new content source, and nothing is scraped. Checklists and Ask starter questions are owner-facing text: they
ship only once the owner has approved the wording.
