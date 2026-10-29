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

**Fixed and expandable tools.** Six fixed tools (search, read, navigate, nearby, locate, calculate) and one generic
`live_data` tool whose sources come from what is installed on the phone, so new data sources never need new
tool definitions or retraining. `calculate` needs no installed data, so it is always in the tool list. `act` is also a fixed tool, but its actions come from the
modules the app has installed (see below); it is in the tool list only while at least one action is listed. `web_search` is a seventh fixed tool that exists only while a web-search key is
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
  "description": "Plan a route to a named place (to) or the nearest place of a type (to_type), using the offline maps on this phone. Omit from to start at the phone's current location. Returns matched places with their coordinates, distance, travel time, the direction from the start, traffic (null when there is no traffic data) and warnings for a brief summary. The app provides Open navigation for this exact route; Maps handles the map and turn-by-turn directions. Do not invent turns or navigation links.",
  "strict": true,
  "parameters": {"type": "object", "properties": {
    "from": {"type": "string", "maxLength": 300,
             "description": "Starting place name, or \"lat,lon\" coordinates the person gave. Omit it when the person means where they are now."},
    "to": {"type": "string", "minLength": 1, "maxLength": 300,
           "description": "Destination place name, for a named place. For \"nearest X\" give to_type instead."},
    "to_type": {"type": "string",
                "enum": ["emergency_room", "hospital", "urgent_care", "pharmacy", "fuel", "police", "fire_station", "campground", "trailhead", "water", "shelter"],
                "description": "Use this instead of to whenever the person asks for the nearest place of a kind. Finds the nearest one by travel time from the start. For a hospital in an emergency use emergency_room."},
    "mode": {"type": "string", "enum": ["drive", "walk", "bike", "offroad_foot", "offroad_vehicle"],
             "description": "drive, walk and bike follow roads and paths. offroad_foot (on foot) and offroad_vehicle (4x4, ATV or dirt bike, on foot where no vehicle can go) go cross-country the whole way over trails, tracks and open ground, where off-road data is installed."},
    "near": {"type": "string", "minLength": 1, "maxLength": 200,
             "description": "Town and state the trip is in, e.g. \"Burley, Idaho\". Give it whenever the question names or implies one."},
    "land_access": {"type": "string", "enum": ["strict", "pragmatic", "emergency"],
                    "description": "Off-road legs only: how land the map data marks private or closed is treated. strict avoids it, pragmatic (the default) crosses it only when it saves a lot, emergency ignores it. This follows the map data's access rules and cannot guarantee access on the ground."}},
    "required": ["mode"], "additionalProperties": false}}}
```

`to_type` lists the categories in the installed places pack; the 11 above are the default list while no pack says otherwise.
Give exactly one of `to` and `to_type`. `mode` is `drive`, `walk` or `bike`, as in AIDA, or one of the two off-road
modes, `offroad_foot` and `offroad_vehicle` (Cache's additions). `land_access` is the one argument added to AIDA's, and
the last: it defaults to `pragmatic` and only matters for off-road legs.

**Off-road legs in drive, walk and bike.** When the start or the destination is away from the road network and the
off-road data (pack and elevation file) is installed, the off-road legs come back automatically inside the route:
a drive uses the vehicle-class modes, a walk goes on foot, a bike uses a two-wheeler. The full Maps snapshot includes
the off-road maneuvers; the assistant sees the off-road distance, explanation and warnings. Without the off-road data the road route is
returned and the end that could not be reached gets a `warnings` entry.

**Off-road modes.** `offroad_foot` and `offroad_vehicle` route the whole trip with the off-road router, with no road
route first: `offroad_foot` on foot over trails and open ground (the unified search with only foot), `offroad_vehicle`
with navi's unified Auto search (4x4, ATV and two-wheeler, switching at parking lots, trailheads and road ends, on foot
for the last part where no vehicle can go). Roads the router uses are part of the route. The result has the same fields
as any route; `offroad_mi` is the off-road part. They need the off-road data covering both ends: without it the call is
`not_set_up` with the detail "Off-road directions need off-road data for this area (the off-road pack and the elevation
file), and none is installed for it" (both matched places beside it), never a road route in their place. A trip too large
for the off-road grid is `route_too_long`. There are no alternatives.

**Land access.** `strict` treats land the data marks private or closed, and MVUM roads and trails closed to the vehicle,
as a wall; `pragmatic` crosses them at five times the cost; `emergency` ignores them. Wilderness rules (no vehicles)
apply under all three. It changes which way the route goes (and so its distance,
time and `offroad_mi`), and a land access other than `pragmatic` gives a different `route_id`, so the same trip under
two land accesses is two sources. When no way exists under the chosen land access the result is `no_route`. No field
is added to the result.

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
them, plus `direction_from_start` and the `lat` and `lon` of both matched places (Cache's additions; the coordinates shown are illustrative, not recorded). The recording shows AIDA's geocoder values for `county`, `distance_km` and `near`; see the places-pack note below.

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
    "snap_distance_m": 10,
    "lat": 43.49184,
    "lon": -116.42033
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
    "snap_distance_m": 21,
    "lat": 43.4629,
    "lon": -116.418
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
  "direction_from_start": "south",
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
  "traffic": null,
  "offroad_mi": 0.11,
  "offroad_note": "Off-road legs are straight lines between turn points over a ~15 m elevation grid with no path on the ground; follow legs run along the mapped road, track or trail they name.",
  "map_region": "Idaho",
  "map_region_age": "12 days old"
}
```

Fields:
- `location_bias` says where matches were preferred: `sender_node_position` (the phone's fix), `near:<town>` (the
  place found for `near`), or `from_place` (the matched start); null when none applied.
- `route_id` is the router's id for the route, the same value the tool's `n` address is built from (the ends, the mode,
  and the land access when it is not `pragmatic`).
- `from_matched` and `to_matched` carry `place_name`, `kind`, `street`, `locality`, `county`, `state`, `distance_km`
  (km from the search's bias point), then `near` and `snap_distance_m` (how far the end was moved onto the road
  network; null when not known). `er_tier` follows `distance_km` for an emergency room, when the places source gives one. It is followed by `emergency_department_confirmed` (true only for tier 1). An unconfirmed hospital fallback also has a `note` explaining that its emergency department is not confirmed in the installed data; neither the selected destination nor an alternative may be presented as a confirmed emergency room on that evidence. After `snap_distance_m` come `lat` and `lon`, the matched place's coordinates rounded to 5 decimals.
- `other_destination_candidates` has up to 2 other matches (the same place fields, no `near`); empty when none. On a
  nearest-place search each entry also has `drive_min` (the travel time in minutes, for every mode; null when it could not be timed).
- `nearest_search` (`{"to_type": ..., "ranked_by": ..., "warnings": []}`) is present only for a `to_type` search, after `other_destination_candidates`. `ranked_by` is `"drive"` when the candidates were ranked by drive time (whatever the travel `mode`: walk and bike searches also say `drive`) and `"distance"` when routing failed for every candidate and the straight-line order stood; it is never the mode name. `warnings` is always a list of strings: `[]` when there are none, and one entry saying that routing failed when `ranked_by` is `"distance"`. (AIDA passes navi's values through: `navi_places/nearby.py` `_rank`.)
- `direction_from_start` is the compass direction of the straight-line (initial great-circle) bearing from the start to the destination, one lower-case word of eight: `north`, `northeast`, `east`, `southeast`, `south`, `southwest`, `west`, `northwest` (45 degree sectors centred on each point). It follows `duration_minutes`.
- `major_roads` is a list of `{"name", "distance_km"}`.
- `traffic` follows `major_roads` on every route: null when there is no traffic data (no traffic key, offline, or no
  traffic source on the phone), which is every route for now; the source (TomTom flow data adjusting the road route) is
  not wired yet. When there is data it is
  `{"delay_min": 7.5, "as_of": "2026-10-29T08:10:00-06:00", "source": "TomTom", "slow_sections": [{"name": "I-84", "delay_min": 6.0}]}`:
  the extra minutes traffic adds to the whole route (already in `duration_minutes`), when the traffic data was read (local
  time, ISO 8601 with offset), where it came from, and the slowed roads with their own delays (empty when none). The
  assistant mentions traffic only when it is not null. Project decision (2026-10-29).
- Every step has `index`, `kind` (`road`, `offroad` or `offroad_follow`), `type`, `street_names`, `distance_mi`,
  `cardinal` and `instruction`. Off-road steps add `travel` (`foot`, `2w`, `4w` or `vehicle`), `grade_class`,
  `elev_gain_m`, `elev_loss_m`, `terrain` (only when known) and, on `offroad_follow`, `follow` (`name` and
  `trail_kind`). The off-road `instruction` is AIDA's text, written by the tool; road steps carry the router's text.
- `offroad_mi` and `offroad_note` appear only when the route has off-road legs. `offroad_note` is AIDA's text with the grid
  size corrected to "~15 m" (AIDA says ~30 m; the router's grid is the global z12 pixel grid, 13-15 m across the
  continental US); the example above shows Cache's text.
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
  {"n": 7, "name": "Walgreens", "kind": "pharmacy", "kind_label": "Pharmacy", "street": "1414 Overland Ave", "locality": "Burley", "state": "ID", "distance_mi": 0.8, "direction": "SE", "phone": "+1 208 ...", "hours": "Mo-Su 08:00-22:00"},
  {"n": 8, "name": "Smith's Pharmacy", "kind": "pharmacy", "kind_label": "Pharmacy", "locality": "Burley", "state": "ID", "distance_mi": 1.6, "direction": "S"}],
 "map_region": "Idaho", "map_region_age": "12 days old"}
```

`phone` and `hours` only when the map data has them.

**Kinds.** Every place says what it is: `kind` is a stable id from the pack's kind table (`drinking_water`, `spring`, `water_well`,
`water_point`, `emergency_shelter`, `picnic_shelter`, `trail_shelter`, `wilderness_hut`, `hospital`, `urgent_care`, `pharmacy`, `fuel`, ...)
and `kind_label` is how to say it ("Drinking water tap", "Picnic shelter"). The kinds are derived from the source's own tags by data
rules (`places_pack/categories.json`), never from names. A category can hold several kinds (`water` holds taps, springs and wells;
`shelter` holds emergency shelters, picnic shelters, trail shelters and huts), so the answer reads `kind_label` to say which. A place
the map data gives no name is called by its kind label and has `"unnamed": true` (`{"name": "Drinking water tap", "kind": "drinking_water",
"kind_label": "Drinking water tap", "unnamed": true, ...}`): the model says "an unnamed drinking water tap", never a bare "Water" or
"Shelter". A pack of the older format (1) has no kinds: those fields are absent. Errors: `nearby_empty`, `no_location`, `not_set_up`.

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

`what3words` only when it was fetched online or cached for a saved place. For a named place the result also has `kind` and `kind_label`
right after `place_name` (`"kind": "pharmacy", "kind_label": "Pharmacy"`; a town is `town` / "Town"); the phone's own position has none. Errors: `geocode_empty`, `no_location`.

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
  "description": "Downloaded live data for a place. Data is downloaded while online and expires. Sources on this phone: weather = weather forecast, current conditions, hourly and daily; alerts = active emergency alerts and evacuation levels; fuel_prices = fuel prices by area and station. Set when to read one period: today, tonight, tomorrow, a weekday name, a date YYYY-MM-DD, or next_days (with days).",
  "parameters": {"type": "object", "properties": {
    "source": {"type": "string", "enum": ["weather", "alerts", "fuel_prices"],
               "description": "Which source to read."},
    "place": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "A saved place or town. Omit for the phone's current location."},
    "when": {"type": "string", "minLength": 1, "maxLength": 20, "description": "Which period. Omit for everything saved."},
    "days": {"type": "integer", "minimum": 1, "maximum": 16,
             "description": "With when=next_days: how many days, today included."}},
    "required": ["source"], "additionalProperties": false}}}
```

The description ends with one sentence on `when`: "Set when to read one period: today, tonight, tomorrow, a weekday name,
a date YYYY-MM-DD, or next_days (with days)." The tool does the date arithmetic in the place's own time zone, never the model:

| `when` | Period |
|---|---|
| omitted | everything saved (the output is exactly what it was before `when`) |
| `today` | now to local midnight |
| `tonight` | 18:00 (or now, if later) to 07:00 tomorrow; before 07:00, the rest of the night in progress |
| `tomorrow`, a weekday name, `YYYY-MM-DD` | that local day; a weekday is the next time it comes, today's own name is today |
| `next_days` with `days` N | now to the end of day N, today being day 1 (all 16 without `days`) |

Items in effect now (current conditions, an alert already running) are always kept, so "is it raining now, and tomorrow?"
needs one call. Dated items (forecast days, an alert starting later) are kept when they overlap the period. A period the saved
forecast does not reach, or a day that is over, is one numbered item saying so, never an empty list:
`{"n": 11, "label": "No weather forecast for Sat Nov 14 in the saved data", "fields": {"Status": "not in the saved data",
"Saved data runs to": "2026-11-09"}, "not_covered": true}`. A forecast day's low is the day's minimum, which comes in the early
morning: its field says "Low (early morning)". For the night ahead the weather source has its own item from the next 36 hours
of hourly data (`"label": "Tonight (Wed Oct 28)"`, fields "Overnight low", "Chance of rain", "Wind max", "Worst conditions",
taken over 18:00 to 07:00 only); `when: "tonight"` answers with it and the Now item, not the two days it falls across. A
definition makes such an item with `window` (a part of the day ahead over a time series) and `agg` values (min, max, sum, first,
last over the series inside it).

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
  {"n": 11, "label": "Sun Oct 26", "time": "2026-10-26",
   "fields": {"Daytime high": "58 °F", "Low (early morning)": "31 °F", "Chance of rain": "10%", "Precipitation": "0.0 in over 0 h", "Snow": "0.0 in", "Wind max": "18 mph"}}],
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

### calculate (always present; needs no installed data)

```json
{"type": "function", "function": {
  "name": "calculate",
  "description": "Exact arithmetic and unit conversion. Use it for any sum, dose, ratio, range or unit change instead of working it out yourself, and quote the result as given. Write a formal expression with numbers and units, e.g. \"8 drops/gallon * 5 gallons\", \"0.15 mg/kg * 70 kg\", \"12 gallons * 18 mpg\", \"98.6 degF to degC\". For dates write YYYY-MM-DD or today: \"today - 2026-10-20\" gives the days between, \"today + 30 days\" gives a date.",
  "parameters": {"type": "object", "properties": {
    "expression": {"type": "string", "minLength": 1, "maxLength": 300,
                   "description": "Numbers, units, + - * / ^ and parentheses. Optionally end with 'to <unit>'."}},
    "required": ["expression"], "additionalProperties": false}}}
```

Result (an exact answer, then an approximate one; there is no `n`, because the result is not a citable source):

```json
{"ok": true, "expression": "8 drops/gallon * 5 gallons", "result": "40 drops", "exact": true,
 "assumptions": ["1 drop = 0.05 mL", "US customary units (1 gallon = 3.785 L)"]}
{"ok": true, "expression": "1/3", "result": "0.333333", "exact": false, "assumptions": []}
```

`expression` is the input with surrounding spaces removed. `result` is the calculator's answer, to be quoted as given.
When the calculator marks the answer as approximate, `exact` is false and `result` is rounded to 6 significant digits;
otherwise `exact` is true and the answer is unchanged. The calculator is fend (fend-core, MIT). A fresh one serves every
call, so nothing carries over from an earlier call, and it has no exchange rates, random numbers or clock: currency
(`5 USD to EUR`) and dice (`roll d6`) fail. A calculation that runs longer than half a second is stopped.

Dates. Before the expression goes to fend, a date layer answers these forms, and only these:

- a date is `YYYY-MM-DD` or `today`; `today` is the date part of the tool's `now` (the phone's local date, pinned in
  captures), never the system clock;
- `<date> - <date>` gives the days between, `"N days"` (N may be negative; `"1 day"` and `"-1 day"` are singular, `"0 days"`
  is plural);
- `<date> + <n> days|weeks` and `<date> - <n> days|weeks`, with `n` a whole number without a sign, give a date as
  `"YYYY-MM-DD (Thu)"` (the weekday as its three-letter English abbreviation);
- a lone `<date>` gives that date with its weekday.

`today`, `day(s)` and `week(s)` may be written in any case, and the spaces are optional (`today+30days`). The result is
always exact. `assumptions` is `["today is YYYY-MM-DD (the phone's local date)"]` when `today` was used, otherwise empty.

```json
{"ok": true, "expression": "today - 2026-10-20", "result": "9 days", "exact": true,
 "assumptions": ["today is 2026-10-29 (the phone's local date)"]}
{"ok": true, "expression": "2026-10-29 + 2 weeks", "result": "2026-11-12 (Thu)", "exact": true, "assumptions": []}
```

Any other expression containing a date or `today` (other arithmetic, a fraction or a signed `n`, other units, an
impossible date such as `2026-02-30`, or a result outside the years 0001-9999) fails with `calc_failed` and the detail
`dates work only as date - date, or date + or - a whole number of days or weeks; write dates as YYYY-MM-DD or today`.
`today` with no readable date in `now` fails with `unable to get the current date`.

`assumptions` has one line for each unit in the expression whose definition varies by country or convention, in order of
first appearance, each line once; it is empty when there are none. `drop`, `drops` and `gtt` give "1 drop = 0.05 mL".
`gallon`, `gal`, `quart`, `qt`, `pint`, `pt`, `cup`, `fluid_ounce`, `floz`, `tablespoon`, `tbsp`, `teaspoon` and `tsp`
(and their plurals) are US customary units and give "US customary units (1 gallon = 3.785 L)". For the imperial
gallon write `imperial_gallon` (or `ukgal`): 4.54609 L, no assumption line. fend has no plain `ton`; use `short_ton`,
`tonne` or `t`.

Temperature. `98.6 degF to degC` converts an absolute temperature (`37 °C`; `degF` and `degC` are the same as `°F` and `°C`,
and `100 °C to °F` gives `212 °F`). In a sum the second temperature is a difference, not an absolute temperature:
`1°C+1°F` gives `1.55556 °C` (approximate), the same as adding 1 °C and a 1 °F step of 5/9 °C. The tool does nothing special for
temperatures; this is how fend works.

Errors: `bad_arguments` (no expression, an empty one, not a string, or over 300 characters) and `calc_failed`, whose
`detail` is the calculator's message (`division by zero`, `exchange rates are not available`, `unknown identifier 'ton'`,
`cannot convert from drops to unitless: ...`), `took too long`, or one of the two date details above.

### act (present only while the app has installed at least one action)

Modules publish the things they can do as data; the model reaches them through this one tool, so a new module needs no new
tool definition or retraining. The contract with the app (definitions, the confirm card, running actions) is
[docs/ACTIONS.md](ACTIONS.md); this section is the tool as the model and the core see it.

```json
{"type": "function", "function": {
  "name": "act",
  "description": "Do something in one of the app's modules. Actions marked (confirm) show the user a confirm card; nothing changes until they tap it. * = required. Actions:\nplaces.save(name:string*, place:place*, note:string) - Save a place to the user's saved places. (confirm)\nplaces.list() - The user's saved places.",
  "parameters": {"type": "object", "properties": {
    "action": {"type": "string"},
    "fields": {"type": "object"}},
    "required": ["action"], "additionalProperties": false}}}
```

The description is built from the installed definitions (the two action lines above are an example): the header, then one line
per action in module order and then the module's own order, `id(field:type*, ...) - description`, with ` (confirm)` after a
`change` action. A field is `name:type`, an enum is its values joined by `|`, and `*` marks a required field. At most 40
actions are listed. The model is trained on this exact text.

Results. The model only ever sees these:

```json
{"ok": true, "status": "needs_confirmation", "confirm_id": "c1", "action": "places.save", "title": "Save a place",
 "summary": {"name": "Elk camp", "place": "44.21000, -114.93000 (12 mi NE of Stanley)"}}
{"ok": true, "status": "done", "action": "places.list", "result": {"places": [{"n": 1, "name": "Home"}]}}
{"ok": false, "error": {"type": "bad_arguments", "detail": "note: must be at most 500 characters", "field": "note", "reason": "too_long"}}
```

A `change` action never runs from the call: the result is a confirm card for the app to show, and the model tells the user what
the card will do and that nothing happens until they tap it. What the tap came to arrives later as a system message
(`{"host_event":"act_outcome","ok":true,"status":"done"|"declined"|"failed","confirm_id":"c1","action":"places.save",...}`),
not as a tool result. A `read` or `open` action is run by the app and its result comes straight back as `status` `done`;
objects in `result` with an `address` carry `n` like any other tool result.

Errors: `unknown_action`; `bad_arguments` with `field` and `reason` (`missing`, `unknown_field`, `wrong_type`, `not_allowed`,
`too_long`, `out_of_range`, `bad_format`); `place_not_found` with `field` and `query`; `not_set_up` (the module is switched off).
A `place` field takes a saved place name, a place name or address, or `lat,lon`, resolved as `navigate` resolves `to`.

How the core and the app run the exchange (not seen by the model):

| Step | Call | Result |
|---|---|---|
| install | `cs_act_set_definitions(defs)` | per-definition rejections and the actions not listed |
| a `change` call | `cs_tool` | `needs_confirmation` with `confirm_id` (`c1`, `c2`, ...) |
| the card is shown | `cs_act_resolve(action, fields)` | the machine values to run on a tap, places as `{"lat","lon","name"?,"label"?}` |
| a `read` or `open` call | `cs_tool` | `{"ok":true,"status":"host_run","run_id":"r1","action":...,"fields":{...}}`, for the app only |
| the app has run it | `cs_act_finish(conv, run_id, reply)` | the `done` result above (or the error), to add as the call's tool message |
| the user taps | `cs_act_outcome(conv, outcome)` | the exact system message content, to add to the conversation |

`cs serve` plays the app for captures: `--actions <defs.json>` installs definitions, and `--action-results <file>` scripts what
the app returns. The file is one JSON object with two tables keyed by action id, `run` (the reply to a `host_run`, as
`cs_act_finish` takes it) and `tap` (what a tap on that action's card comes to):

```json
{"run": {"places.list": {"ok": true, "result": {"places": [{"address": "place:home", "name": "Home"}]}},
         "places.open": {"ok": false, "error": {"type": "unavailable", "detail": "Maps is not installed"}}},
 "tap": {"places.save": {"status": "done", "result": {"saved": "Elk camp"}},
         "places.delete": {"status": "declined"},
         "home.source_switch": {"status": "failed", "error": {"type": "denied", "detail": "location is off"}}}}
```

`POST /conversations/{id}/act/finish` with `{"run_id":"r1"}` plays the scripted `run` reply (or give `{"run_id","reply"}`), and
`POST /conversations/{id}/act/outcome` with `{"confirm_id":"c1"}` plays the scripted `tap` (or give `{"outcome":{...}}`); both
return what the core returns. `POST /act/definitions`, `POST /act/modules-off` and `POST /act/resolve` mirror the other three
calls.

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

None at present. Off-road navigate (the `offroad_foot` and `offroad_vehicle` modes, `land_access` and the off-road step fields) is part of navigate in 1.0, above.

---

## Not tools

- Videos: video concepts come through `search` and `read`; citing one opens the video at the time shown.
- Model switching, downloads and settings are app screens, not assistant tools.
