# Cache assistant tools: draft v2 (2026-10-25)

Draft by ref-a5 for training and test examples. These are the tools the Cache assistant will have, as
OpenAI-style function schemas, plus the exact result each one returns. 1.0 tools are pinned; 1.x tools are
sketched so examples can be written, and may still change.

## Conventions (all tools)

**Numbering.** The app numbers every source the assistant sees across the whole conversation: the first
search's results are [1]..[5], the next tool's sources continue from [6], and a source seen before keeps its
number. Tools never number anything themselves; the numbers shown below are what the model sees after the app
has numbered them. The model cites with [n]; citations that don't match a number shown in this conversation are
dropped by the app.

**Two result shapes.**
- `search`, `read` and `web_search` return plain text (cheapest in tokens).
- Every other tool returns one JSON object. Each citable item in it carries `"n"`.

**Fixed and expandable tools.** Five fixed tools (search, read, navigate, nearby, locate) and one generic
`live_data` tool whose sources come from what is installed on the phone, so new data sources never need new
tool definitions or retraining. `web_search` is a sixth fixed tool that exists only while a web-search key is
configured and the phone is online; without them it is left out of the tool list.

**Errors (every tool).** `{"ok": false, "error": {"type": "<code>", "detail": "<short text>"}}`. Shared codes:
`bad_arguments`, `no_location` (the tool needs a place and none was given or known), `not_set_up` (the needed
data, such as a map region or the alerts source, isn't on the phone), `internal`, and these, added with the
tool framework:
- `not_configured`: the tool needs a setting that has not been made;
- `fetch_failed`: a download or network request failed (no connection, timeout, the server refused);
- `quota`: the provider's usage limit is reached;
- `key_missing`: an API key the tool needs is not set;
- `bad_response`: the provider answered with something the tool cannot use.

**Dated data (live sources).** Every item from a live source carries:
- `fetched_at`: local time it was downloaded, ISO 8601 with offset;
- `valid_until`: local time after which it must not be used;
- `age`: plain words, e.g. "2 hours old", "3 days old";
- `expired`: true once `valid_until` has passed.
When everything requested has expired or nothing was ever downloaded, the tool returns
`{"ok": false, "error": {"type": "expired" | "no_data", "detail": ...}}` and the assistant says so plainly,
e.g. "I no longer have weather data. We need to go online for more." It never answers from the stale data or
from memory.

**System prompt context.** The app puts the current local date and time, and whether the phone's location is
known, into the system prompt. When the location is known, tools that take a place default to it.

**Limits.** At most 3 tool rounds per answer. Context is 8,192 tokens, so results are kept short.

---

## 1.0 tools

### search

```json
{"type": "function", "function": {
  "name": "search",
  "description": "Search the offline library and reference articles (encyclopedias, manuals, medical and how-to guides) on this phone. Returns up to 5 numbered results. Use it before answering any question about facts or how to do something.",
  "parameters": {"type": "object", "properties": {
    "query": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "What to search for, in plain words."}},
    "required": ["query"], "additionalProperties": false}}}
```

Result (text, one line per result, up to 5; snippets up to ~400 characters):

```
[1] FM 4-25.11 First Aid, p. 42: Controlling bleeding — Apply firm, direct pressure to the wound with a clean dressing and keep the pressure on...
[2] WikiMed: Bleeding — Bleeding is the loss of blood. First aid is direct pressure on the wound; a tourniquet is used for life-threatening limb bleeding...
```

Titles: library hit `<book title, up to ~60 chars>, p. <page>: <concept title>` (no ", p." when the page is
unknown); reference article `<ZIM title>: <article title>`; video concept `<video title> at <mm:ss>: <concept title>`.

Nothing found: `No results found.`

### read

```json
{"type": "function", "function": {
  "name": "read",
  "description": "Open the full text of one numbered result when its snippet is not enough.",
  "parameters": {"type": "object", "properties": {
    "n": {"type": "integer", "minimum": 1,
          "description": "The number of a result shown earlier in this conversation, e.g. 2 for [2]."}},
    "required": ["n"], "additionalProperties": false}}}
```

Result (text; the same number; up to ~6,000 characters, cut at a paragraph end):

```
[2] WikiMed: Bleeding
<article text, headings kept, HTML removed>
[truncated]
```

For a library concept: title, book, author, page, summary and key facts. Unknown number:
`{"ok": false, "error": {"type": "not_found", "detail": "no result [9] in this conversation"}}`.

### navigate (copied from AIDA's navigate, adapted for offline maps on the phone)

```json
{"type": "function", "function": {
  "name": "navigate",
  "description": "Directions in one call, to a named place (to) or to the nearest place of a type (to_type), using the offline maps on this phone. Omit from to start at the phone's current location. Returns the places actually matched, so a wrong match can be seen.",
  "strict": true,
  "parameters": {"type": "object", "properties": {
    "from": {"type": "string", "maxLength": 300,
             "description": "Starting place name. Omit it when the person means where they are now."},
    "to": {"type": "string", "minLength": 1, "maxLength": 300,
           "description": "Destination place name, for a named place. For \"nearest X\" give to_type instead."},
    "to_type": {"type": "string",
                "enum": ["emergency_room", "hospital", "urgent_care", "pharmacy", "fuel", "police", "fire_station", "campground", "trailhead", "water", "shelter"],
                "description": "Use this instead of to whenever the person asks for the nearest place of a kind. Finds the nearest one by travel time from the start. For a hospital in an emergency use emergency_room."},
    "mode": {"type": "string", "enum": ["drive", "walk", "bike"]},
    "near": {"type": "string", "minLength": 1, "maxLength": 200,
             "description": "Town and state the trip is in, e.g. \"Burley, Idaho\". Give it whenever the question names or implies one."}},
    "required": ["mode"], "additionalProperties": false}}}
```

Steps are capped at 15 in the result (`steps_truncated`, `steps_omitted`), to fit the 8k context.

Differences from AIDA: no Meshtastic waypoint or `pins`/`bridge` fields; the start defaults to the phone's GPS
position instead of the sender's node; `water` and `shelter` added to the categories (from the map pack's OSM
data). Off-road legs come in 1.x; until then a destination off the road network returns the road route plus a
`warnings` entry `{"code": "offroad_unavailable", "gap_m": N}`.

Result (JSON): the same fields as AIDA's navigate result, plus `"n"`:

```json
{"ok": true, "n": 6, "mode": "drive", "location_bias": "phone_location",
 "from_matched": {"place_name": "current location", "lat": 42.536, "lon": -113.792},
 "to_matched": {"place_name": "Cassia Regional Hospital", "kind": "hospital", "street": "1501 Hiland Ave", "locality": "Burley", "state": "ID", "lat": 42.531, "lon": -113.785},
 "other_destination_candidates": [{"place_name": "Minidoka Memorial Hospital", "locality": "Rupert", "state": "ID", "drive_min": 14.2}],
 "nearest_search": {"to_type": "emergency_room", "ranked_by": "drive_time"},
 "distance_mi": 1.1, "distance_km": 1.8, "duration_minutes": 4.0, "major_roads": ["Overland Ave"],
 "step_count": 5, "steps": [{"index": 0, "kind": "road", "street_names": ["Main St"], "distance_mi": 0.3, "cardinal": "S", "instruction": "Head south on Main St"}],
 "steps_truncated": false, "steps_omitted": 0, "map_region": "Idaho", "map_region_age": "12 days old"}
```

Errors (AIDA's codes kept): `geocode_empty` (with `which`, `query`, `searched_within_km`), `origin_unknown`,
`nearby_empty`, `same_place`, `route_failed`, plus `not_set_up` when no map region covers the area.

### nearby

```json
{"type": "function", "function": {
  "name": "nearby",
  "description": "List the nearest places of one kind, without directions. Use navigate instead when the person wants to go there.",
  "parameters": {"type": "object", "properties": {
    "category": {"type": "string",
                 "enum": ["emergency_room", "hospital", "urgent_care", "pharmacy", "fuel", "police", "fire_station", "campground", "trailhead", "water", "shelter"]},
    "near": {"type": "string", "minLength": 1, "maxLength": 200,
             "description": "Town and state, or a place name. Omit to search around the phone's current location."},
    "limit": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5}},
    "required": ["category"], "additionalProperties": false}}}
```

The `category` enum, and a one-line description of each category appended to the property's description, are
filled at runtime from the category tables of the installed map packs; the values listed above are an example.
The pack's description of `emergency_room` is "for a hospital in an emergency use emergency_room".

Result:

```json
{"ok": true, "category": "pharmacy", "center": "current location", "ranked_by": "distance",
 "places": [
  {"n": 7, "name": "Walgreens", "street": "1414 Overland Ave", "locality": "Burley", "state": "ID", "distance_mi": 0.8, "direction": "SE", "phone": "+1 208 ...", "hours": "Mo-Su 08:00-22:00"},
  {"n": 8, "name": "Smith's Pharmacy", "locality": "Burley", "state": "ID", "distance_mi": 1.6, "direction": "S"}],
 "map_region": "Idaho", "map_region_age": "12 days old"}
```

`phone` and `hours` only when the map data has them. Errors: `nearby_empty`, `no_location`, `not_set_up`.

### locate

```json
{"type": "function", "function": {
  "name": "locate",
  "description": "Where a place is (or where the phone is now): coordinates and the nearest town. Use for \"where am I\" or \"what are the coordinates of X\".",
  "parameters": {"type": "object", "properties": {
    "place": {"type": "string", "minLength": 1, "maxLength": 300,
              "description": "Place name. Omit for the phone's current location."},
    "near": {"type": "string", "minLength": 1, "maxLength": 200}},
    "required": [], "additionalProperties": false}}}
```

Result (1.0 gives latitude/longitude; 1.x adds the other formats shown):

```json
{"ok": true, "n": 9, "place_name": "current location", "lat": 42.53612, "lon": -113.79245,
 "lat_lon_dms": "42°32'10\"N 113°47'33\"W", "nearest_town": "Burley, ID", "distance_to_town_mi": 0.9,
 "accuracy_m": 12, "fixed_at": "2026-10-25T14:20:05-06:00",
 "usng": "12T VN 64780 10230", "plus_code": "85GF+...", "what3words": "///filled.count.soap"}
```

`what3words` only when it was fetched online or cached for a saved place. Errors: `geocode_empty`, `no_location`.

### live_data (one generic tool for every live source)

Live sources (weather, alerts, and later fuel prices, repeaters, earthquakes, river levels, avalanche, space
weather, wildfires, road conditions, satellite passes, outages, or anything a user adds) are all reached
through this one tool. The app fills the `source` enum at runtime from the source definitions installed on that
phone, with each source's one-line description appended to the tool description. Adding a source never needs
retraining: the model picks a source from the list and answers from the labelled fields it gets back.

Schema as the app builds it (example with three installed sources):

```json
{"type": "function", "function": {
  "name": "live_data",
  "description": "Downloaded live data for a place. Data is downloaded while online and expires. Sources on this phone: weather = weather forecast, current conditions, hourly and daily; alerts = active emergency alerts and evacuation levels; fuel_prices = fuel prices by area and station.",
  "parameters": {"type": "object", "properties": {
    "source": {"type": "string", "enum": ["weather", "alerts", "fuel_prices"],
               "description": "Which source to read."},
    "place": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "A saved place or town. Omit for the phone's current location."}},
    "required": ["source"], "additionalProperties": false}}}
```

Result (one self-describing shape for every source):

```json
{"ok": true,
 "source": {"id": "weather", "title": "Weather forecast", "provider": "Open-Meteo"},
 "place": "Burley, ID",
 "fetched_at": "2026-10-24T06:00:00-06:00", "valid_until": "2026-11-01T00:00:00-06:00", "age": "1 day old", "expired": false,
 "items": [
  {"n": 10, "label": "Now", "time": "2026-10-25T14:00-06:00",
   "fields": {"Temperature": "54 °F", "Feels like": "51 °F", "Wind": "12 mph NW, gusts 20 mph", "Conditions": "partly cloudy"}},
  {"n": 11, "label": "Sun 26 Oct", "time": "2026-10-26",
   "fields": {"High": "58 °F", "Low": "31 °F", "Chance of rain": "10%", "Wind max": "18 mph"}}],
 "not_covered_after": "2026-11-01"}
```

The same shape for alerts:

```json
{"ok": true,
 "source": {"id": "alerts", "title": "Emergency alerts", "provider": "NWS"},
 "place": "Home (Burley, ID)",
 "fetched_at": "2026-10-25T13:55:00-06:00", "valid_until": "2026-10-25T22:00:00-06:00", "age": "25 minutes old", "expired": false,
 "items": [
  {"n": 12, "label": "Wildfire evacuation: SET (prepare to leave)", "time": "2026-10-25T13:40:00-06:00",
   "fields": {"Severity": "severe", "Area": "Cassia County south of I-84", "Distance": "6.2 mi S",
              "Expires": "2026-10-25 22:00", "Headline": "Prepare to evacuate due to the Rock Creek fire.",
              "Instructions": "Prepare to leave at a moment's notice. Gather medications, documents and pets."}}]}
```

Rules:
- `fields` keys are plain labels and values carry their units, so no source needs special handling by the model.
- Items are capped (about 12 per result) to fit the 8k context; `"more": N` says how many were left out.
- Nothing to report (for example no active alerts): `"items": []` with `"none": true`; the assistant states the age.
- All downloaded data expired: `{"ok": false, "error": {"type": "expired", "detail": "weather data expired 2026-11-01"}}`;
  nothing ever downloaded: type `no_data`; source not installed: type `unknown_source`. The assistant says plainly
  that it needs to go online (for example "I no longer have weather data. We need to go online for more.").
- "Ask about this alert" starts a chat whose first user turn carries the alert as source [1] in this shape.

Sources planned for 1.0: `weather`, `alerts`. Sources for 1.x (installed as source definitions): fuel prices,
repeaters (from imported lists), earthquakes, river levels, avalanche, space weather, wildfires, road conditions,
satellite passes, outages. Training uses a deliberately varied mix of sources, including made-up ones, so the
behaviour generalises to sources added later.

### web_search (present only with a web-search key configured and the phone online)

```json
{"type": "function", "function": {
  "name": "web_search",
  "description": "Search the web. Only for what the offline library cannot answer or for current information (news, prices, recent events). Search the offline library first.",
  "parameters": {"type": "object", "properties": {
    "query": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "What to search for, in plain words."}},
    "required": ["query"], "additionalProperties": false}}}
```

Result (text, the same form as `search`: one line per result, up to 5). Every title ends with
` (web, fetched <local time>)`, the time the result was downloaded:

```
[3] Cassia County lifts burn ban (web, fetched 2026-10-25 14:20) — The county fire marshal ended the burn ban on Friday after two days of rain...
[4] Burley, ID weather this week (web, fetched 2026-10-25 14:20) — Highs near 58 with a chance of rain on Tuesday...
```

Nothing found: `No results found.`

`read` on a web result fetches the page within a time budget and returns, in the same shape as any `read`:

```
[3] Cassia County lifts burn ban (web, fetched 2026-10-25 14:20)
<page text>
```

If the budget runs out before the page loads, `read` returns the snippet instead, followed by the line
`[full page did not load in time]`. The first line is kept (`[3] <title> (web, fetched <time>)`), the snippet follows
it, and the marker is the last line. If the page cannot be had for another reason (the server refused, it is not an
HTML or text page, or it has no text), the same output ends with `[full page not available]`. Neither is an error.

If the page loads but its text is under 500 characters (a page drawn by JavaScript often gives only navigation or a
footer), `read` returns the first line, the snippet, the text that was found (if any), and the last line
`[page had little readable text]`. That is not an error either.

Errors: `key_missing`, `fetch_failed`, `quota`, `bad_response`. Without a key, or with the phone offline, the tool is
not in the tool list, so the model cannot call it.

Web results are never stored as library content: they exist only in this conversation, with the time they were
fetched.

## 1.x additions

### navigate, off-road

`mode` gains `"offroad_vehicle"` and `"offroad_foot"`; results gain AIDA's off-road step fields (`travel`,
`grade_class`, `elev_gain_m`, `elev_loss_m`, `terrain`, `follow`, `offroad_mi`, `offroad_note`).

---

## Not tools

- Videos: video concepts come through `search` and `read`; citing one opens the video at the time shown.
- Model switching, downloads and settings are app screens, not assistant tools.
