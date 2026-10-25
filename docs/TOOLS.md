# Cache assistant tools (v1, 2026-10-25)

The tools the Cache assistant has, as OpenAI-style function schemas, plus the exact result each one returns. Training and test examples are written against this file. 1.0 tools are pinned; 1.x tools are sketched and may still change.

## Conventions (all tools)

**Numbering.** The app numbers every source the assistant sees across the whole conversation: the first
search's results are [1]..[5], the next tool's sources continue from [6], and a source seen before keeps its
number. Tools never number anything themselves; the numbers shown below are what the model sees after the app
has numbered them. The model cites with [n]; citations that don't match a number shown in this conversation are
dropped by the app.

**Two result shapes.**
- `search` and `read` return plain text (cheapest in tokens).
- Every other tool returns one JSON object. Each citable item in it carries `"n"`.

**Errors (every tool).** `{"ok": false, "error": {"type": "<code>", "detail": "<short text>"}}`. Shared codes:
`bad_arguments`, `no_location` (the tool needs a place and none was given or known), `not_set_up` (the needed
data, such as a map region or the alerts source, isn't on the phone), `internal`.

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
 "steps_truncated": false, "map_region": "Idaho", "map_region_age": "12 days old"}
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

### weather

```json
{"type": "function", "function": {
  "name": "weather",
  "description": "The downloaded weather forecast for a place: current conditions, hourly for the next days and daily up to about 16 days. Forecasts are downloaded while online and expire.",
  "parameters": {"type": "object", "properties": {
    "place": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "A saved place or town. Omit for the phone's current location."},
    "days": {"type": "integer", "minimum": 1, "maximum": 16, "default": 3}},
    "required": [], "additionalProperties": false}}}
```

Result:

```json
{"ok": true, "n": 10, "place": "Burley, ID", "source": "Open-Meteo",
 "fetched_at": "2026-10-24T06:00:00-06:00", "valid_until": "2026-11-01T00:00:00-06:00", "age": "1 day old", "expired": false,
 "units": {"temperature": "°F", "wind": "mph", "precipitation": "in"},
 "now": {"time": "2026-10-25T14:00-06:00", "temperature": 54, "feels_like": 51, "wind": 12, "wind_direction": "NW", "gusts": 20, "conditions": "partly cloudy"},
 "daily": [{"date": "2026-10-25", "high": 58, "low": 31, "precip_chance": 10, "precip": 0.0, "wind_max": 18, "conditions": "partly cloudy"}],
 "hourly_note": "hourly data available for the next 72 hours; ask for a specific time"}
```

Days past the downloaded range are left out and reported as `"not_covered_after": "<date>"`. Errors:
`expired`, `no_data`, `no_location`.

### alerts

```json
{"type": "function", "function": {
  "name": "alerts",
  "description": "Active emergency alerts (weather warnings, wildfire evacuation levels and similar) downloaded for a place, newest first. Alerts arrive only while the phone is online.",
  "parameters": {"type": "object", "properties": {
    "place": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "A saved place or town. Omit for the phone's current location."}},
    "required": [], "additionalProperties": false}}}
```

Result:

```json
{"ok": true, "place": "Home (Burley, ID)", "fetched_at": "2026-10-25T13:55:00-06:00", "age": "25 minutes old",
 "alerts": [
  {"n": 11, "event": "Wildfire evacuation: SET (prepare to leave)", "severity": "severe", "source": "county emergency management via NWS",
   "area": "Cassia County south of I-84", "distance_mi": 6.2, "direction": "S",
   "issued": "2026-10-25T13:40:00-06:00", "expires": "2026-10-25T22:00:00-06:00", "expired": false,
   "headline": "Prepare to evacuate due to the Rock Creek fire.",
   "instructions": "Prepare to leave at a moment's notice. Gather medications, documents and pets."}],
 "none_active": false}
```

No alerts: `{"ok": true, ..., "alerts": [], "none_active": true}` (only meaningful if `age` is recent; the
assistant states the age). Errors: `expired` (all downloaded alerts have expired), `no_data`, `not_set_up`.

The "Ask about this alert" button starts a chat whose first user turn carries the alert as source [1] in this
same shape.

---

## 1.x tools (sketch; may change)

### fuel_prices

```json
{"type": "function", "function": {
  "name": "fuel_prices",
  "description": "Downloaded fuel prices: regional weekly averages, and per-station prices when available.",
  "parameters": {"type": "object", "properties": {
    "place": {"type": "string", "minLength": 1, "maxLength": 200},
    "grade": {"type": "string", "enum": ["regular", "midgrade", "premium", "diesel"], "default": "regular"}},
    "required": [], "additionalProperties": false}}}
```

Result (EIA format):

```json
{"ok": true, "grade": "regular",
 "regional": {"n": 12, "area": "Rocky Mountain (PADD 4)", "price": 4.605, "unit": "USD/gal", "period": "week of 2026-10-19", "series": "EMM_EPM0_PTE_R40_DPG", "source": "U.S. EIA",
              "fetched_at": "2026-10-22T09:00:00-06:00", "valid_until": "2026-10-29T00:00:00-06:00", "age": "3 days old", "expired": false},
 "stations": [{"n": 13, "name": "Maverik", "locality": "Burley", "price": 4.39, "updated": "2 hours ago", "distance_mi": 1.2}]}
```

`stations` appears only with a per-station source (online Google Places results are shown live and never
stored).

### repeaters

```json
{"type": "function", "function": {
  "name": "repeaters",
  "description": "Radio repeaters from the lists imported on this phone, nearest first.",
  "parameters": {"type": "object", "properties": {
    "near": {"type": "string", "minLength": 1, "maxLength": 200},
    "band": {"type": "string", "enum": ["2m", "70cm", "6m", "10m", "1.25m", "gmrs", "any"], "default": "any"},
    "mode": {"type": "string", "enum": ["fm", "dmr", "dstar", "fusion", "p25", "any"], "default": "any"},
    "limit": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5}},
    "required": [], "additionalProperties": false}}}
```

Result: `{"ok": true, "list": "<imported file name>", "repeaters": [{"n": 14, "callsign": "...", "output_mhz": 146.94, "offset": "-0.6", "tone": "100.0", "mode": "fm", "location": "...", "distance_mi": 8.4, "notes": "..."}]}`.
Errors: `not_set_up` (no list imported), `nearby_empty`.

### Other live-source tools (same dated-data conventions)

| Tool | Arguments | Items |
|---|---|---|
| `earthquakes` | place?, days?, min_magnitude? | magnitude, place, time, depth, distance |
| `river_levels` | place?, river? | gauge name, stage/flow, flood stage, trend, time |
| `avalanche` | place? | zone, danger rating, problems, valid period |
| `space_weather` | (none) | Kp index, alerts, HF radio conditions, valid period |
| `wildfires` | place? | incident name, size, containment, distance, hotspots near |
| `road_conditions` | place? or route? | closures, chain controls, work zones, time |
| `satellite_passes` | satellite?, place?, hours? | pass times, max elevation, direction |
| `outages` | place? | utility, customers out, area, estimated restore |

### navigate, off-road (1.x)

`mode` gains `"offroad_vehicle"` and `"offroad_foot"`; results gain AIDA's off-road step fields (`travel`,
`grade_class`, `elev_gain_m`, `elev_loss_m`, `terrain`, `follow`, `offroad_mi`, `offroad_note`).

---

## Not tools

- Videos: video concepts come through `search` and `read`; citing one opens the video at the time shown.
- Model switching, downloads and settings are app screens, not assistant tools.
