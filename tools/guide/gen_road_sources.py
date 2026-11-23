#!/usr/bin/env python3
"""Writes the guide section for road events and road work from the app's data file (app/assets/roads/road_sources.json).

The section text is fixed here; the tables and the counts in the text come from the data file, so adding a site or a feed is a data-file
row and nothing is typed twice.

usage:
  python3 -I tools/guide/gen_road_sources.py DATA.json CHAPTER.md [CHAPTER.md ...]     write the section into each chapter
  python3 -I tools/guide/gen_road_sources.py --check DATA.json CHAPTER.md [CHAPTER.md ...]  exit 1 when a chapter's section is not what the data makes
  python3 -I tools/guide/gen_road_sources.py --print DATA.json                          print the section

The section is the part of the chapter from the heading "## Road events and road work on the map" to the next "## " heading. A chapter
without it gets it before "## Adding more sources".
"""
import json
import sys

HEADING = "## Road events and road work on the map"
BEFORE = "## Adding more sources"


def section(data):
    sites = data["sites"]
    feeds = data["wzdx"]["feeds"]
    steps = data["platform"]["keySteps"]
    usable = [f for f in feeds if f["access"] in ("open", "key", "request")]
    work = [f for f in usable if f["access"] in ("open", "key")]
    keyed = [f for f in usable if f["access"] == "key"]
    byreq = [f for f in usable if f["access"] == "request"]
    notyet = [f for f in feeds if f["access"] == "unverified"]
    with_cond = [s for s in sites if s.get("conditions")]
    out = []
    w = out.append
    w(HEADING + "\n")
    w("Two sources draw closures, crashes and road work on the map. They also feed the Weather screen's \"Happening nearby\" list and what the assistant can tell you about the road.\n")
    w("- \"511 road events\" works with %d state and provincial 511 sites. It shows closures, crashes, incidents and planned road work, with the closed stretch and a detour when the site gives one. %d of the sites also give winter road conditions, and one source covers both." % (len(sites), len(with_cond)))
    w("- \"WZDx road work\" reads the US Department of Transportation's work zone feeds. It shows planned work zones and lane closures. %d feeds work today and %d of them need a key. %d more are available by request from the publisher, and %d need a key whose instructions are not verified yet, so they are not supported yet.\n" % (len(work), len(keyed), len(byreq), len(notyet)))
    w("Some places have both. A 511 site reports what is happening now; a WZDx feed reports planned work. When both describe the same work zone, the map draws it once, from the 511 site.\n")
    w("What the map draws is what Cache has already downloaded for the places it watches and the maps on your device. Moving the map downloads nothing. Tap a closure, a crash or a work zone for its card. An event whose data is out of date is drawn faded, with its age on the card.\n")
    w("### Add a 511 site\n")
    w("1. Go to [\"Settings\" > \"Maps\"](cache://settings/maps).")
    w("2. Under \"Road events\", tap \"Add a 511 site\", then tap your state or province. Use the search box, or \"Enter another site\" for a 511 site that is not listed.")
    w("3. In the same place, open the key row named for the site, for example \"511 key (511.idaho.gov)\".")
    for i, s in enumerate(steps):
        w("%d. %s" % (4 + i, s if s.endswith(".") else s + "."))
    w("")
    w("Every site needs its own key. Each site allows ten calls every 60 seconds, and Cache stays under that. Adding a key does not turn anything on: switch the source on under \"Road events\".\n")
    w("### Add road work (WZDx)\n")
    w("1. Under \"Road events\" in [\"Settings\" > \"Maps\"](cache://settings/maps), tap \"Add a road work feed\".")
    w("2. Tap a feed from the list, or tap \"Paste a feed URL\". Cache removes any key or token from a pasted address; a feed that needs a key gets its own key row there, for example \"WZDx key (Ohio DOT)\".\n")
    w("Feeds that are by request or not supported yet are listed but cannot be added. The list in Cache can be longer than the tables here.\n")
    w("### Supported 511 sites\n")
    w("| Site | Covers | Winter road conditions | Link |")
    w("|---|---|---|---|")
    for s in sites:
        w("| %s | %s%s | %s | [Key page](%s) |" % (s["host"], s["name"], " (Canada)" if s["country"] == "CA" else "", "Yes" if s.get("conditions") else "No", s["keyPage"]))
    w("")
    w("### Supported road work feeds\n")
    w("| Feed | Covers | Key needed | Link |")
    w("|---|---|---|---|")
    for f in usable:
        link = "[Key page](%s)" % f["keyPage"] if f.get("keyPage") else "-"
        need = {"open": "No", "key": "Yes", "request": "By request"}[f["access"]]
        w("| %s | %s | %s | %s |" % (f["publisher"], f["area"], need, link))
    w("")
    return "\n".join(out)


def replace_in(text, new):
    """[text] with its road events section replaced by [new] (or added before the "Adding more sources" section)."""
    lines = text.split("\n")
    new_lines = new.rstrip("\n").split("\n") + [""]
    try:
        start = lines.index(HEADING)
    except ValueError:
        try:
            at = lines.index(BEFORE)
        except ValueError:
            raise SystemExit("neither %r nor %r is in the chapter" % (HEADING, BEFORE))
        return "\n".join(lines[:at] + new_lines + lines[at:])
    end = start + 1
    while end < len(lines) and not lines[end].startswith("## "):
        end += 1
    return "\n".join(lines[:start] + new_lines + lines[end:])


def main(argv):
    args = argv[1:]
    mode = "write"
    if args and args[0] in ("--check", "--print"):
        mode = args.pop(0)[2:]
    if not args:
        print(__doc__)
        return 2
    with open(args[0], encoding="utf-8") as f:
        data = json.load(f)
    new = section(data)
    if mode == "print":
        sys.stdout.write(new)
        return 0
    bad = 0
    for path in args[1:]:
        with open(path, encoding="utf-8") as f:
            old = f.read()
        updated = replace_in(old, new)
        if mode == "check":
            if updated != old:
                print("%s: the road events section is not what the data file makes; run tools/guide/gen_road_sources.py" % path)
                bad = 1
        elif updated != old:
            with open(path, "w", encoding="utf-8") as f:
                f.write(updated)
            print("%s: road events section written" % path)
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv))
