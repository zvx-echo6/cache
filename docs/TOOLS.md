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
`bad_arguments`, `no_location` (the tool needs a place and none was given or known; nearby and locate use it, navigate uses
`origin_unknown` instead), `not_set_up` (the needed
data, such as a map region or the alerts source, isn't on the phone), `internal`, and these, added with the
tool framework:
- `not_configured`: the tool needs a setting that has not been made;
- `fetch_failed`: a download or network request failed (no connection, timeout, the server refused);
- `quota`: the provider's usage limit is reached;
- `key_missing`: an API key the tool needs is not set;
- `bad_response`: the provider answered with something the tool cannot use.

A tool may also put fields at the top level beside `error` (navigate adds `from_matched` and `to_matched`), and `detail`
is left out when it is empty.

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
<article text, headings kept, HTML removed; the page's main content only: menus, banners, sidebars and footers are left out>
[truncated]
```

For a library concept: title, book, author, page, summary and key facts. Unknown number:
`{"ok": false, "error": {"type": "not_found", "detail": "no result [9] in this conversation"}}`.

### navigate (route summary for the assistant; navigation in Maps)

```json
{"type": "function", "function": {
  "name": "navigate",
  "description": "Plan a route to a named place (to) or the nearest place of a type (to_type), using the offline maps on this phone. Omit from to start at the phone's current location. Returns matched places, distance, travel time and warnings for a brief summary. The app provides Open navigation for this exact route; Maps handles the map and turn-by-turn directions. Do not invent turns or navigation links.",
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
             "description": "Town and state the trip is in, e.g. \"Burley, Idaho\". Give it whenever the question names or implies one."},
    "land_access": {"type": "string", "enum": ["strict", "pragmatic", "emergency"],
                    "description": "Off-road legs only: how private or closed land is treated. strict never crosses it, pragmatic (the default) crosses it only when it saves a lot, emergency ignores it."}},
    "required": ["mode"], "additionalProperties": false}}}
```

`to_type` lists the categories in the installed places pack; the 11 above are the default list while no pack says otherwise.
Give exactly one of `to` and `to_type`. `mode` is `drive`, `walk` or `bike`, as in AIDA. `land_access` is the one
argument added to AIDA's, and the last: it defaults to `pragmatic` and only matters for off-road legs.

**Off-road.** There is no off-road mode. When the start or the destination is away from the road network and the
off-road data (pack and elevation file) is installed, the off-road legs come back automatically inside the route:
a drive uses the vehicle-class modes, a walk goes on foot, a bike uses a two-wheeler. The full Maps snapshot includes
the off-road maneuvers; the assistant sees the off-road distance, explanation and warnings. Without the off-road data the road route is
returned and the end that could not be reached gets a `warnings` entry.

**Assistant summary and navigation handoff.** The model receives matched places, distance, travel time,
major roads, off-road distance and warnings, with the canonical `nav:<route_id>` citation address. Turn instructions,
geometry and maneuver lists stay outside the model context. The app offers **Open navigation** from the structured
successful tool result and opens that exact route in Maps; the model must not invent a navigation URL or turns.

The app immediately calls `cs_map_route` with only `{"route_id":"<raw route id>"}` to obtain the retained full map
snapshot (`ok:true`, geometry, all maneuvers, totals, endpoints and `alternatives:[]`). This performs no routing,
GPS or place lookup, and registers the snapshot for `cs_map_progress`. The latest eight tool routes are retained
per core; unknown/evicted IDs return `not_found`, malformed/mixed lookup requests return `bad_json`. Persist the
snapshot as UI metadata outside model context for chat history/restart. Opening it previews the route and does
not start guidance automatically.

Differences from AIDA: no Meshtastic waypoint or `pins`/`bridge` fields; the start defaults to the phone's GPS
position instead of the sender's node (`location_bias` is then `sender_node_position`, AIDA's value, for the phone's
fix); `water` and `shelter` added to the categories (from the map pack's OSM data); `land_access` added; the result
adds `map_region` and `map_region_age`.

Result (JSON). The tool writes `"address": "nav:<route_id>"` as the first field; the framework replaces it with `"n"`
and puts `"ok": true` in front (the example shows `ok`; the app's `n` follows it). The example below is the recorded
AIDA result `offroad-v24-12-t1-h` (`packages/cache_search/cli/tests/fixtures/aida_navigate/`, request: from "Kuna",
to "Swan Falls Dam", near "Kuna, Idaho", mode drive), with its values as recorded, the fields written in the order the
tool writes them, `pins` taken out (Cache has no pins), and `map_region` and `map_region_age` added as the tool emits
them. The recording shows AIDA's geocoder values for `county`, `distance_km` and `near`; see the places-pack note below.

```json
{
  "ok": true,
  "mode": "drive",
  "location_bias": "near:Kuna, Ada, Idaho, United States",
  "route_id": "a7650ad16e34abd2",
  "from_matched": {
    "place_name": "Kuna High School",
    "kind": "poi",
    "street": "East Deer Flat Road",
    "locality": "Kuna",
    "county": "Ada",
    "state": "ID",
    "distance_km": 1.4,
    "near": {
      "county": "Ada",
      "distance_m": 0,
      "housenumber": "637",
      "locality": "Kuna",
      "name": "Kuna High School",
      "state": "ID",
      "street": "East Deer Flat Road"
    },
    "snap_distance_m": 10
  },
  "to_matched": {
    "place_name": "Swan Falls Storage",
    "kind": "poi",
    "street": "South Swan Falls Road",
    "locality": "Kuna",
    "county": "Ada",
    "state": "ID",
    "distance_km": 0.7,
    "near": {
      "county": "Ada",
      "distance_m": 0,
      "housenumber": "387",
      "locality": "Kuna",
      "name": "Swan Falls Storage",
      "state": "ID",
      "street": "South Swan Falls Road"
    },
    "snap_distance_m": 21
  },
  "other_destination_candidates": [
    {
      "place_name": "Swan Falls Assisted Living",
      "kind": "poi",
      "street": "West White Way",
      "locality": "Kuna",
      "county": "Ada",
      "state": "ID",
      "distance_km": 1.2
    },
    {
      "place_name": "Swan Falls Family Dentistry",
      "kind": "poi",
      "street": "North Linder Road",
      "locality": "Kuna",
      "county": "Ada",
      "state": "ID",
      "distance_km": 1.5
    }
  ],
  "distance_mi": 1.99,
  "distance_km": 3.21,
  "duration_minutes": 6.0,
  "major_roads": [
    {
      "name": "North Linder Road",
      "distance_km": 1.38
    },
    {
      "name": "East Deer Flat Road",
      "distance_km": 0.54
    },
    {
      "name": "South Swan Falls Road",
      "distance_km": 0.39
    }
  ],
  "offroad_mi": 0.11,
  "offroad_note": "Off-road legs are straight lines between turn points over a ~30 m elevation grid with no path on the ground; follow legs run along the mapped road, track or trail they name.",
  "map_region": "Idaho",
  "map_region_age": "12 days old"
}
```

Fields:
- `location_bias` says where matches were preferred: `sender_node_position` (the phone's fix), `near:<town>` (the
  place found for `near`), or `from_place` (the matched start); null when none applied.
- `route_id` is the router's id for the route, the same value the tool's `n` address is built from.
- `from_matched` and `to_matched` carry `place_name`, `kind`, `street`, `locality`, `county`, `state`, `distance_km`
  (km from the search's bias point), then `near` and `snap_distance_m` (how far the end was moved onto the road
  network; null when not known). `er_tier` follows `distance_km` for an emergency room, when the places source gives one. It is followed by `emergency_department_confirmed` (true only for tier 1). An unconfirmed hospital fallback also has a `note` explaining that its emergency department is not confirmed in the installed data; neither the selected destination nor an alternative may be presented as a confirmed emergency room on that evidence.
- `other_destination_candidates` has up to 2 other matches (the same place fields, no `near`); empty when none. On a
  nearest-place search each entry also has `drive_min` (the travel time in minutes, for every mode; null when it could not be timed).
- `nearest_search` (`{"to_type": ..., "ranked_by": ..., "warnings": []}`) is present only for a `to_type` search, after `other_destination_candidates`. `ranked_by` is `"drive"` when the candidates were ranked by drive time (whatever the travel `mode`: walk and bike searches also say `drive`) and `"distance"` when routing failed for every candidate and the straight-line order stood; it is never the mode name. `warnings` is always a list of strings: `[]` when there are none, and one entry saying that routing failed when `ranked_by` is `"distance"`. (AIDA passes navi's values through: `navi_places/nearby.py` `_rank`.)
- `major_roads` is a list of `{"name", "distance_km"}`.
- Every step has `index`, `kind` (`road`, `offroad` or `offroad_follow`), `type`, `street_names`, `distance_mi`,
  `cardinal` and `instruction`. Off-road steps add `travel` (`foot`, `2w`, `4w` or `vehicle`), `grade_class`,
  `elev_gain_m`, `elev_loss_m`, `terrain` (only when known) and, on `offroad_follow`, `follow` (`name` and
  `trail_kind`). The off-road `instruction` is AIDA's text, written by the tool; road steps carry the router's text.
- `offroad_mi` and `offroad_note` appear only when the route has off-road legs.
- `warnings` appears only when there is one. Each entry is `{"code": "offroad_unavailable", "end": "from" | "to",
  "road_point": {"lat", "lon"}, "gap_m": N}`: that end is away from the road network, the route stops at
  `road_point`, and `gap_m` is how many metres short of the requested end it stops. It is how the road route is
  returned when the off-road data is not installed, or does not cover that end.
- `map_region` and `map_region_age` name the installed map region and how old it is ("12 days old"; "unknown" when
  the age cannot be read).

**Places pack.** `county`, `distance_km`, `near` and `er_tier` come from the places pack. Until the pack is installed
they are `null` (`county`, `distance_km`, `near`; a place the user gave as coordinates or a saved place has them null
too), and `er_tier` is left out. Cache has no reverse geocoder, so `near` is `null` on every result for now.

**Errors.** `{"ok": false, "error": {"type": ..., "detail": ...}}` as in the Conventions, with two differences: the
fields below sit at the top level beside `error`, and `detail` is left out when it is empty.
- `geocode_empty`: nothing matched a name. `error` has `which` (`from` or `to`), `query` and `searched_within_km`
  (null when unknown); no `detail`.
- `origin_unknown`: no `from` was given and the phone's location is not known. (Navigate does not use `no_location`.)
- `nearby_empty`: no place of that type was found. `error` has `to_type` and `warnings` (a list, `[]` when there are none, never null; AIDA `nav_runtime.py`); no `detail`.
- `same_place`: the start and the destination are the same spot.
- The router's own code is passed through as `error.type` when the route fails, with its message as `detail`:
  `no_route`, `too_far`, `out_of_coverage`, `route_too_long`, `upstream_timeout`, `internal`.
- `not_set_up`: no map region is installed (or the router could not start), or the places data is missing for a
  `to_type` search.
- `bad_arguments`: for example neither or both of `to` and `to_type`.

`from_matched` and `to_matched` (the place fields above, without `near` and `snap_distance_m`) ride at the top
level beside `error` on `same_place` and on the router's failures; `nearby_empty` carries `from_matched` only. When
the phone's location is known, `error` also has a `hint` on `geocode_empty` for `from` and on `same_place`, telling the
model it can omit `from`.

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

The `place` text is a saved place, a town or other place the places pack knows, or latitude and longitude (`"44.42,-111.37"`).
It may be written any way the pack understands ("Island Park, Idaho", "Island Park ID", "island park") and a town name with one
typing slip in it ("Islnd Park") still finds the town. Data is looked up by distance: it is the data of the nearest place that
was downloaded for, within `live_radius_km` (phone setting, default 30), so a town with no data of its own gets the nearest
stored town's, and the result says so (below). The schema is unchanged.

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

When the data is for another place than the one asked about (and 1 km or more away), `place` is the place the data is for, and
two fields follow it: `asked_place`, the place that was asked about (the name the pack resolved, the coordinates as given, or
`current location`), and `distance_from_asked_km`, whole km, at least 1. The assistant says which place the data is for and how
far it is. Without them the data is for the place asked about.

```json
{"ok": true,
 "source": {"id": "weather", "title": "Weather forecast", "provider": "Open-Meteo"},
 "place": "Ashton, ID", "asked_place": "Island Park, ID", "distance_from_asked_km": 40,
 "fetched_at": "2026-10-24T06:00:00-06:00", "valid_until": "2026-11-01T00:00:00-06:00", "age": "1 day old", "expired": false,
 "items": [{"n": 10, "label": "Now", "time": "2026-10-25T14:00-06:00", "fields": {"Temperature": "41 °F", "Conditions": "overcast"}}]}
```

Rules:
- `fields` keys are plain labels and values carry their units, so no source needs special handling by the model.
- Items are capped (about 12 per result) to fit the 8k context; `"more": N` says how many were left out.
- Nothing to report (for example no active alerts) is still a result with one numbered entry, so it can be cited like any
  item: `"none": true` stays at the top level, and `items` holds one entry in an item's shape with `"none_active": true`
  (its label is the definition's `none_label`, or its `title` when it has none; `Checked` is the time of the download in the
  place's zone; the assistant states the age). The same entry is returned for as long as the download is valid:

```json
{"ok": true,
 "source": {"id": "alerts", "title": "Emergency alerts", "provider": "NWS"},
 "place": "Boise, ID",
 "fetched_at": "2026-10-26T09:53:25-06:00", "valid_until": "2026-10-26T15:53:25-06:00", "age": "6 minutes old", "expired": false,
 "items": [
  {"n": 3, "label": "No active emergency alerts", "time": "2026-10-26T09:53:25-06:00",
   "fields": {"Status": "none active", "Checked": "2026-10-26 09:53", "Age": "6 minutes old"}, "none_active": true}],
 "none": true}
```

  Before this change the same result was `"items": []` with `"none": true`, which gave the model nothing to cite.
- All downloaded data expired: `{"ok": false, "error": {"type": "expired", "detail": "weather data expired 2026-11-01"}}`;
  nothing ever downloaded: type `no_data`; source not installed: type `unknown_source`. Data exists, but none within
  `live_radius_km` of the place asked about: type `no_data` with the nearest place named in the detail
  (`"no weather data within 30 km of Island Park, ID; the nearest place with data is Ashton, ID, 40 km away"`). A place text
  that no saved place and no places pack entry matches: type `geocode_empty`. Without a places pack only saved places and
  coordinates are matched. The assistant says plainly
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

None at present. Off-road navigate (the `offroad_vehicle` and `offroad_foot` modes, `land_access` and the off-road step fields) is part of navigate in 1.0, above.

---

## Not tools

- Videos: video concepts come through `search` and `read`; citing one opens the video at the time shown.
- Model switching, downloads and settings are app screens, not assistant tools.
