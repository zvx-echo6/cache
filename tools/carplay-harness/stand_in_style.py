#!/usr/bin/env python3
"""Writes the stand-in map styles of the CarPlay harness, and the colours that go with them, for the phone's four themes.

    stand_in_style.py <out folder>     -> style_<theme>.json, colors_<theme>.json, palette_<theme>.json for dark, light,
                                          parchment and tactical

The app's real style is built in Dart from layers the Rust core serves, and neither runs in the Simulator. The stand-in is a
made-up town with no network and no text: land, a lake, two parks, a grid of streets with a few main roads, all in one GeoJSON
source inside the style. Its colours are the app's four map palettes as they stood when this was written
(app/lib/maps/palette/map_palette.dart), so the route and the position are judged against the real backgrounds; the answer to
the car's `style` call carries the same roles the app sends (car_bridge.dart, style). The trip's `palette` for each theme is the
one the Kotlin tests read (app/android/app/src/test/resources/car/overlay_palette.json), which app/test/car_test.dart holds to
what the phone sends (carOverlayColors).
"""
import json
import sys
from pathlib import Path

WEST, EAST, SOUTH, NORTH = 20.15, 20.33, 10.45, 10.61

PALETTES = {
    "light": {
        "land": "#f8f4f0", "water": "#9ec5e8", "park": "#d8e8c8", "roadMajor": "#ffeeaa", "roadMajorCasing": "#e9ac77",
        "roadMinor": "#ffffff", "roadMinorCasing": "#cfcdca",
        "route": "#1f6fa8", "routeCasing": "#ffffff", "routeOffroad": "#b5470f", "routeAlternate": "#7c8590",
        "position": "#1f6fa8", "positionRing": "#ffffff", "pin": "#c62e24",
    },
    "dark": {
        "land": "#14171c", "water": "#1f3b52", "park": "#1f2d24", "roadMajor": "#59606b", "roadMajorCasing": "#1c1f24",
        "roadMinor": "#3e444d", "roadMinorCasing": "#20242a",
        "route": "#6bb4de", "routeCasing": "#0f1115", "routeOffroad": "#e8955a", "routeAlternate": "#707987",
        "position": "#6bb4de", "positionRing": "#0f1115", "pin": "#ff6b5e",
    },
    "parchment": {
        "land": "#efe3c8", "water": "#9fb5a9", "park": "#d5d9b0", "roadMajor": "#edd08a", "roadMajorCasing": "#b98a50",
        "roadMinor": "#f8efd8", "roadMinorCasing": "#cdbf9e",
        "route": "#7a4e1d", "routeCasing": "#f3e9d2", "routeOffroad": "#a3261c", "routeAlternate": "#9a8a70",
        "position": "#7a4e1d", "positionRing": "#f3e9d2", "pin": "#a3261c",
    },
    "tactical": {
        "land": "#000000", "water": "#2e0909", "park": "#120303", "roadMajor": "#8a1a14", "roadMajorCasing": "#000000",
        "roadMinor": "#5a100d", "roadMinorCasing": "#1a0505",
        "route": "#ff5a4a", "routeCasing": "#000000", "routeOffroad": "#f08070", "routeAlternate": "#8e2b24",
        "position": "#ff5a4a", "positionRing": "#000000", "pin": "#ff2d1f",
    },
}
# The trip's palettes, one for each theme (the Kotlin tests' fixture, which the Dart tests hold to the phone's colours).
TRIP_PALETTES = Path(__file__).resolve().parent.parent.parent / "app/android/app/src/test/resources/car/overlay_palette.json"
SENT = ["route", "routeCasing", "routeOffroad", "routeAlternate", "position", "positionRing", "pin"]


def steps(low, high, every):
    count = int(round((high - low) / every))
    return [round(low + i * every, 4) for i in range(count + 1)]


def grid(every, skip_every=None):
    lines = []
    for lon in steps(WEST, EAST, every):
        if skip_every and abs(round(lon / skip_every) * skip_every - lon) < 1e-6:
            continue
        lines.append([[lon, SOUTH], [lon, NORTH]])
    for lat in steps(SOUTH, NORTH, every):
        if skip_every and abs(round(lat / skip_every) * skip_every - lat) < 1e-6:
            continue
        lines.append([[WEST, lat], [EAST, lat]])
    return lines


def box(west, south, east, north):
    return [[[west, south], [east, south], [east, north], [west, north], [west, south]]]


def feature(kind, geometry_type, coordinates):
    return {"type": "Feature", "properties": {"k": kind}, "geometry": {"type": geometry_type, "coordinates": coordinates}}


def town():
    return {
        "type": "FeatureCollection",
        "features": [
            feature("water", "Polygon", box(20.255, 10.462, 20.272, 10.492)),
            feature("park", "Polygon", box(20.236, 10.501, 20.242, 10.506)),
            feature("park", "Polygon", box(20.292, 10.531, 20.318, 10.552)),
            feature("minor", "MultiLineString", grid(0.001, skip_every=0.01)),
            feature("major", "MultiLineString", grid(0.01)),
        ],
    }


def width(*stops):
    return ["interpolate", ["linear"], ["zoom"], *stops]


def style(name, c):
    def is_kind(kind):
        return ["==", ["get", "k"], kind]

    def road(layer_id, kind, color, line_width, minzoom):
        return {
            "id": layer_id, "type": "line", "source": "town", "minzoom": minzoom, "filter": is_kind(kind),
            "layout": {"line-cap": "round", "line-join": "round"}, "paint": {"line-color": color, "line-width": line_width},
        }

    return {
        "version": 8,
        "name": "CarPlay harness stand-in, %s" % name,
        # The phone's style has the notebook pins' source and layer (app/lib/maps/style/style_generator.dart, kNotebookSource and
        # kNotebookPins, as with an icon pin style): the car fills the source with the pins the phone sends (car_pins.dart).
        "sources": {"town": {"type": "geojson", "data": town()},
                    "cache-notebook": {"type": "geojson", "data": {"type": "FeatureCollection", "features": []}}},
        "layers": [
            {"id": "land", "type": "background", "paint": {"background-color": c["land"]}},
            {"id": "water", "type": "fill", "source": "town", "filter": is_kind("water"), "paint": {"fill-color": c["water"]}},
            {"id": "park", "type": "fill", "source": "town", "filter": is_kind("park"), "paint": {"fill-color": c["park"]}},
            road("minor-casing", "minor", c["roadMinorCasing"], width(13, 1.6, 16, 10), 13),
            road("major-casing", "major", c["roadMajorCasing"], width(9, 1.6, 13, 5, 16, 15), 0),
            road("minor", "minor", c["roadMinor"], width(13, 0.8, 16, 8), 13),
            road("major", "major", c["roadMajor"], width(9, 0.9, 13, 3.6, 16, 12), 0),
            {
                "id": "notebook-pins", "type": "symbol", "source": "cache-notebook", "filter": ["has", "pin"],
                "layout": {"icon-image": ["get", "pin"], "icon-size": 1, "icon-anchor": "center", "icon-allow-overlap": True,
                           "icon-ignore-placement": True},
            },
        ],
    }


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    trip = json.loads(TRIP_PALETTES.read_text())
    for name, c in PALETTES.items():
        (out / ("style_%s.json" % name)).write_text(json.dumps(style(name, c), separators=(",", ":")))
        (out / ("colors_%s.json" % name)).write_text(json.dumps({role: c[role] for role in SENT}))
        (out / ("palette_%s.json" % name)).write_text(json.dumps(trip[name]))
    sizes = ", ".join("%s %d bytes" % (p.name, p.stat().st_size) for p in sorted(out.glob("style_*.json")))
    print("stand-in styles: %s" % sizes)


if __name__ == "__main__":
    main()
