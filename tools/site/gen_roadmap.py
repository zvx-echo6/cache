"""Builds cached.info's Roadmap page (roadmap.html) from the public GitHub project "Cache roadmap".
Usage: gen_roadmap.py out.html
Needs `gh` signed in with read access to user projects, and ROADMAP_BLOCKLIST: a regular expression of words that must
never reach the public page. It lives in a repository secret so this public file does not repeat what it guards.
Any match in an item's title or body, the readme text used, or the finished page stops the build with an error.
A body line "Summary: ..." sets the item's one-line description; "Release: X" overrides the Release field (e.g. 1.3)."""
import datetime, html, json, os, re, subprocess, sys

OWNER, NUMBER, RELEASE = "zvx-echo6", 4, "1.1"
PROJECT_URL = f"https://github.com/users/{OWNER}/projects/{NUMBER}"
PLATFORMS = ["Android", "iPhone & iPad", "Linux & Pi"]
STATES = ["Done", "Building", "Planned", "Later", "n/a"]
if not os.environ.get("ROADMAP_BLOCKLIST"): sys.exit("STOP: ROADMAP_BLOCKLIST is not set")
BANNED = re.compile(os.environ["ROADMAP_BLOCKLIST"], re.I)

out = sys.argv[1]
Q = """query($o:String!,$n:Int!,$c:String){user(login:$o){projectV2(number:$n){readme
items(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{
 content{... on DraftIssue{title body} ... on Issue{title body} ... on PullRequest{title body}}
 fieldValues(first:30){nodes{... on ProjectV2ItemFieldSingleSelectValue{name field{... on ProjectV2SingleSelectField{name}}}}}}}}}}"""

def fetch():
    items, cur, readme = [], None, ""
    while True:
        args = ["gh", "api", "graphql", "-f", "query=" + Q, "-f", f"o={OWNER}", "-F", f"n={NUMBER}"]
        if cur: args += ["-f", f"c={cur}"]
        p = json.loads(subprocess.check_output(args))["data"]["user"]["projectV2"]
        readme = p["readme"] or ""
        for it in p["items"]["nodes"]:
            c = it["content"] or {}
            fv = {v["field"]["name"]: v["name"] for v in it["fieldValues"]["nodes"] if v and v.get("field")}
            items.append({"title": (c.get("title") or "").strip(), "body": c.get("body") or "", **fv})
        if not p["items"]["pageInfo"]["hasNextPage"]: return items, readme
        cur = p["items"]["pageInfo"]["endCursor"]

# Retired product names: never published, whatever the blocklist secret says.
RETIRED = re.compile(r"\bcache\s+server\b", re.I)

def check(text, where):
    m = BANNED.search(text) or RETIRED.search(text)
    if m: sys.exit(f"STOP: a blocked word was found in {where}; nothing was written")

def describe(body):
    """A `Summary:` line wins; otherwise the body's first sentence, cut at the first semicolon."""
    for ln in body.splitlines():
        if ln.lower().startswith("summary:"): return ln.split(":", 1)[1].strip()
    body = "\n".join(l for l in body.splitlines() if not re.match(r"(?i)^release:", l.strip()))
    t = re.sub(r"\s+", " ", re.sub(r"[*_`#>\[\]]", "", body)).strip()
    if not t: return ""
    s = re.split(r"(?<=[.!?])\s+(?=[A-Z(])", t, maxsplit=1)[0]
    s = s.split(";", 1)[0].strip().rstrip(".")
    return s + "." if s else ""

def stable_means(readme):
    m = re.search(r"\*\*Stable means:\*\*\s*(.+?)(?:\n\s*\n|\Z)", readme, re.S)
    if not m: return []
    text = re.sub(r"\s+", " ", m.group(1)).strip().rstrip(".")
    return [p.strip()[:1].upper() + p.strip()[1:] for p in text.split(";") if p.strip()]

def theme(readme):
    m = re.search(r"^##\s*1\.1:\s*(.+)$", readme, re.M)
    return m.group(1).strip() if m else ""

ICON = {  # 16px inline icons; the state is always written out too, so colour is never the only cue
    "Done": '<path d="M3 8.5l3.2 3L13 4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
    "Building": '<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M8 2a6 6 0 0 1 0 12z" fill="currentColor"/>',
    "Planned": '<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.6"/>',
    "Later": '<path d="M3 8h9M8.5 4.5L12 8l-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
    "n/a": '<path d="M4 8h8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
}
CLS = {"Done": "done", "Building": "building", "Planned": "planned", "Later": "later", "n/a": "na"}
MEANING = {"Done": "Shipped and tested on real devices", "Building": "Work has started",
           "Planned": "In 1.1, not started yet", "Later": "Coming to this platform in a later release",
           "n/a": "Does not apply to this platform"}

def icon(state):
    return f'<svg class="ic" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">{ICON[state]}</svg>'

def chip(platform, state):
    state = state if state in STATES else "Planned"
    return (f'<li class="chip {CLS[state]}"><span class="plat">{html.escape(platform)}</span>'
            f'<span class="state">{icon(state)}{html.escape(state)}</span></li>')

def item_html(it):
    d = describe(it["body"])
    desc = f'<p>{html.escape(d)}</p>' if d else ""
    chips = "".join(chip(p, it.get(p, "")) for p in PLATFORMS)
    status = it.get("Status", "Todo")
    tag = f' <span class="status">{html.escape(status)}</span>' if status in ("In Progress", "Done") else ""
    return (f'<article class="card"><h3>{html.escape(it["title"])}{tag}</h3>{desc}'
            f'<ul class="parity" aria-label="Platforms">{chips}</ul></article>')

items, readme = fetch()
def release_of(it):
    """A body line "Release: X" overrides the field (for versions the Release field has no option for, e.g. 1.3)."""
    m = re.search(r"(?im)^\s*release:\s*(\d+\.\d+)\s*$", it["body"])
    return m.group(1) if m else it.get("Release")
LATER = ("1.2", "1.3", "1.5")
cur = [i for i in items if i.get("Release") == RELEASE and release_of(i) == RELEASE]
later = {r: [i["title"] for i in items if release_of(i) == r] for r in LATER}
the_theme = theme(readme)
stable = stable_means(readme)

# Public hygiene: everything that is published, plus the full bodies of the 1.1 items.
for i in cur: check(i["title"] + "\n" + i["body"], f'item "{i["title"]}"')
for r, ts in later.items():
    for t in ts: check(t, f"{r} title")
check(the_theme + " " + " ".join(stable), "project readme")

def group(name, prio, note):
    rows = [i for i in cur if i.get("Priority") == prio]
    if not rows: return ""
    return (f'<section aria-labelledby="g-{prio}"><h2 id="g-{prio}">{name}</h2><p class="note">{note}</p>'
            f'<div class="list">{"".join(item_html(i) for i in rows)}</div></section>')

legend = "".join(f'<li class="chip {CLS[s]}"><span class="state">{icon(s)}{html.escape(s)}</span>'
                 f'<span class="mean">{MEANING[s]}</span></li>' for s in STATES)
stable_html = "".join(f"<li>{html.escape(s)}.</li>" for s in stable)
later_html = "".join(
    f'<div><h3>{r}</h3><ul>' + "".join(f"<li>{html.escape(t)}</li>" for t in ts) + "</ul></div>"
    for r, ts in later.items() if ts)
today = datetime.date.today().isoformat()
done = sum(1 for i in cur for p in PLATFORMS if i.get(p) == "Done")
total = sum(1 for i in cur for p in PLATFORMS if i.get(p) not in ("n/a", "Later", None))

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Cache roadmap</title>
<meta name="description" content="What is coming in Cache {RELEASE}, and which devices get each feature.">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Roboto+Slab:wght@500;700&family=Roboto:wght@400;500&display=swap" rel="stylesheet">
<style>
:root {{ --ground:#1a1d1f; --card:#2a3036; --text:#dcc9a3; --muted:#b0a58a; --clay:#cb7a3c; --clay-text:#db8a4b; --line:#3a4148;
  --chip:#22272c; --done:#8fc19a; --building:#e0a868; --planned:#b0a58a; --later:#9fb6d6; --na:#7d7768; color-scheme: dark; }}
@media (prefers-color-scheme: light) {{ :root:not([data-theme="dark"]) {{ --ground:#f5efe3; --card:#fffaf1; --text:#2b2722; --muted:#655b4b;
  --clay:#cb7a3c; --clay-text:#9a4c14; --line:#ddd2bf; --chip:#f2eadb; --done:#2f7a43; --building:#9a5a10; --planned:#655b4b;
  --later:#2f5d93; --na:#857c6c; color-scheme: light; }} }}
:root[data-theme="light"] {{ --ground:#f5efe3; --card:#fffaf1; --text:#2b2722; --muted:#655b4b; --clay-text:#9a4c14; --line:#ddd2bf;
  --chip:#f2eadb; --done:#2f7a43; --building:#9a5a10; --planned:#655b4b; --later:#2f5d93; --na:#857c6c; color-scheme: light; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--ground); color:var(--text); font:17px/1.6 Roboto, system-ui, -apple-system, "Segoe UI", sans-serif; }}
a {{ color:var(--clay-text); }}
.wrap {{ max-width:56rem; margin:0 auto; padding-left:max(16px, env(safe-area-inset-left)); padding-right:max(16px, env(safe-area-inset-right)); }}
header {{ padding-block:2.5rem 1.5rem; }}
header a.home {{ text-decoration:none; color:var(--muted); font-size:.95rem; }}
.kicker {{ margin:1rem 0 0; color:var(--clay-text); font-weight:500; letter-spacing:.06em; text-transform:uppercase; font-size:.85rem; }}
h1 {{ font:700 clamp(1.8rem, 5vw, 2.5rem)/1.2 "Roboto Slab", Georgia, serif; margin:.25rem 0 .5rem; text-wrap:balance; }}
.lede {{ color:var(--muted); margin:0; max-width:60ch; }}
.platforms {{ margin:.75rem 0 0; color:var(--text); }}
main {{ display:flex; flex-direction:column; gap:2rem; padding-bottom:2.5rem; }}
h2 {{ font:700 1.35rem/1.3 "Roboto Slab", Georgia, serif; margin:0 0 .25rem; }}
.note {{ color:var(--muted); margin:0 0 1rem; max-width:65ch; }}
.list {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(min(100%, 24rem), 1fr)); gap:1rem; }}
.card {{ background:var(--card); border-radius:18px; padding:1.1rem 1.1rem 1rem; min-width:0; display:flex; flex-direction:column; }}
.card h3 {{ font:700 1.05rem/1.35 "Roboto Slab", Georgia, serif; margin:0 0 .3rem; }}
.card p {{ margin:0 0 .85rem; color:var(--muted); font-size:.95rem; }}
.status {{ font:500 .75rem/1 Roboto, sans-serif; padding:.2rem .45rem; border:1px solid var(--line); border-radius:6px; vertical-align:middle; color:var(--muted); }}
ul.parity {{ list-style:none; margin:auto 0 0; padding:0; display:grid; grid-template-columns:repeat(3, minmax(0, 1fr)); gap:.4rem; }}
.chip {{ background:var(--chip); border-radius:10px; padding:.4rem .5rem; border-left:3px solid currentColor; min-width:0; }}
.chip .plat {{ display:block; font-size:.75rem; color:var(--muted); line-height:1.3; }}
.chip .state {{ display:flex; align-items:center; gap:.3rem; font-weight:500; font-size:.9rem; line-height:1.3; }}
.chip.done {{ color:var(--done); }} .chip.building {{ color:var(--building); }} .chip.planned {{ color:var(--planned); }}
.chip.later {{ color:var(--later); }} .chip.na {{ color:var(--na); }}
.chip.na .state {{ font-weight:400; }}
.ic {{ flex:none; }}
.legend {{ list-style:none; margin:0; padding:0; display:grid; grid-template-columns:repeat(auto-fill, minmax(min(100%, 15rem), 1fr)); gap:.5rem; }}
.legend .chip {{ display:flex; gap:.6rem; align-items:center; }}
.legend .mean {{ color:var(--text); font-size:.85rem; }}
.box {{ background:var(--card); border-radius:18px; padding:1.25rem; border:1px solid var(--line); }}
.box ul {{ margin:.25rem 0 0; padding-left:1.2rem; }} .box li {{ margin:.2rem 0; max-width:65ch; }}
.later-grid {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(min(100%, 16rem), 1fr)); gap:1rem 2rem; }}
.later-grid h3 {{ font-size:.8rem; letter-spacing:.08em; text-transform:uppercase; color:var(--muted); margin:0 0 .25rem; font-weight:500; }}
.later-grid ul {{ margin:0; padding-left:1.2rem; color:var(--muted); }} .later-grid li {{ margin:.15rem 0; }}
.meta {{ color:var(--muted); font-size:.9rem; margin:0; }}
@media (max-width: 380px) {{ ul.parity {{ grid-template-columns:1fr; }} .chip .plat {{ display:inline; margin-right:.4rem; }} .chip {{ display:flex; justify-content:space-between; align-items:center; }} }}
footer {{ padding-block:1.5rem 3rem; border-top:1px solid var(--line); color:var(--muted); font-size:.95rem; }}
footer .wrap {{ display:flex; gap:1rem 1.5rem; flex-wrap:wrap; }}
</style>
</head>
<body>
<header><div class="wrap"><a class="home" href="/">&larr; Cache</a>
<p class="kicker">Next release: Cache {RELEASE}</p>
<h1>{html.escape(the_theme)}</h1>
<p class="lede">What Cache {RELEASE} brings, and where each feature stands on each kind of device. Must-haves are the promise: {RELEASE} ships when they all work. Stretch features ride along if they are ready, and never hold the release.</p>
<p class="platforms"><strong>Devices in {RELEASE}:</strong> Android, iPhone and iPad, and Linux and Raspberry Pi (the full app in a browser). Windows comes in 1.2.</p>
</div></header>
<main class="wrap">
<section aria-labelledby="key"><h2 id="key">How to read this</h2><ul class="legend">{legend}</ul></section>
{group("Must-have", "Must-have", f"The promise. Cache {RELEASE} is not stable until every one of these works.")}
{group("Stretch", "Stretch", "Ride along if ready; never hold the release.")}
<section class="box" aria-labelledby="stable"><h2 id="stable">What "stable" means</h2><ul>{stable_html}</ul></section>
<section aria-labelledby="later"><h2 id="later">Later</h2><p class="note">Planned for later releases. Details and dates are not set.</p><div class="later-grid">{later_html}</div></section>
<p class="meta">Updated <time datetime="{today}">{today}</time>. Generated from the <a href="{PROJECT_URL}">Cache roadmap project on GitHub</a>.</p>
</main>
<footer><div class="wrap"><span>Happy Little LLC</span><a href="mailto:info@happylittlellc.com">info@happylittlellc.com</a><a href="/changes">What's new</a><a href="/roadmap">Roadmap</a><a href="/features">Features</a><a href="/privacy">Privacy</a></div></footer>
</body>
</html>
"""
# Final pass over the whole page; the project link is the one allowed mention of the account name.
check(page.replace(PROJECT_URL, ""), "generated page")
open(out, "w", encoding="utf-8").write(page)
print(len(cur), "items,", sum(len(t) for t in later.values()), "later,", f"{done}/{total} platform cells done")
