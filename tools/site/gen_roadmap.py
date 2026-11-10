"""Builds cached.info's Roadmap page (roadmap.html) from the public GitHub project "Cache roadmap".
Usage: gen_roadmap.py out.html
Needs `gh` signed in with read access to user projects, and ROADMAP_BLOCKLIST: a regular expression of words that must
never reach the public page. It lives in a repository secret so this public file does not repeat what it guards.
Any match in an item's title or body, the readme text used, or the finished page stops the build with an error.
"Where things stand" is driven by status.json next to this script (cards of state-chip lines, an optional timing table, links);
its text goes through the same blocked-word checks as the board text.
A body line "Summary: ..." sets the item's one-line description; "Release: X" overrides the Release field (e.g. 1.3)."""
import datetime, html, json, os, pathlib, re, subprocess, sys

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

def theme(readme, release=RELEASE):
    """A release's title: the readme's "## <release>: <title>" line ("" when there is none)."""
    m = re.search(r"^##\s*" + re.escape(release) + r":\s*(.+)$", readme, re.M)
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
later_titles = {r: theme(readme, r) for r in LATER}
for r, t in later_titles.items(): check(t, f"{r} release title")
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
    f'<div><h3>{r}' + (f': {html.escape(later_titles[r])}' if later_titles.get(r) else "") + '</h3><ul>'
    + "".join(f"<li>{html.escape(t)}</li>" for t in ts) + "</ul></div>"
    for r, ts in later.items() if ts)
today = datetime.date.today().isoformat()
done = sum(1 for i in cur for p in PLATFORMS if i.get(p) == "Done")
total = sum(1 for i in cur for p in PLATFORMS if i.get(p) not in ("n/a", "Later", None))


def load_status():
    p = pathlib.Path(__file__).resolve().parent / "status.json"
    if not p.exists(): sys.exit("STOP: tools/site/status.json is missing; nothing was written")
    d = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(d, dict) or not isinstance(d.get("cards"), list): sys.exit("STOP: status.json has no cards; nothing was written")
    return d

def safe_link(u):
    """Only plain https links are published."""
    return u if isinstance(u, str) and re.match(r"https://[^\s\"'<>]+$", u) else ""

TONES = ("ok", "warn", "bad", "info")
E = lambda s: html.escape(str(s if s is not None else ""))

def status_texts(d):
    """Every string status.json can publish, for the blocked-word check."""
    out = [d.get("updated"), d.get("lede")]
    for c in d["cards"]:
        out += [c.get("id"), c.get("title"), c.get("goals")]
        t = c.get("table") or {}
        out += list(t.get("head") or []) + [x for r in t.get("rows") or [] for x in r]
        for g in c.get("groups") or []:
            out.append(g.get("heading"))
            for ln in g.get("lines") or []: out += [ln.get("chip"), ln.get("tone"), ln.get("text")]
        for l in c.get("links") or []: out += [l.get("label"), l.get("href")]
    return "\n".join(str(x) for x in out if x)

def st_lines(lines):
    rows = []
    for ln in lines:
        tone = ln.get("tone") if ln.get("tone") in TONES else "info"
        rows.append(f'<li><span class="st-chip st-{tone}">{E(ln.get("chip"))}</span><span>{E(ln.get("text"))}</span></li>')
    return '<ul class="st-list">\n' + "\n".join(rows) + "\n</ul>"

def st_table(t):
    head = "".join(f"<th>{E(h)}</th>" for h in t.get("head") or [])
    rows = "\n".join(f'<tr><td>{E(r[0])}</td><td class="n{" f" if len(r) > 2 and r[2] == "bad" else ""}">{E(r[1])}</td></tr>'
                     for r in t.get("rows") or [])
    return f'<table class="st-tbl"><thead><tr>{head}</tr></thead><tbody>\n{rows}\n</tbody></table>'

def st_card(c):
    cid = E(c.get("id"))
    h = [f'<section class="st-card{" st-wide" if c.get("wide") else ""}" aria-labelledby="{cid}">',
         f'<h3 id="{cid}">{E(c.get("title"))}</h3>']
    if c.get("goals"): h.append(f'<p class="st-bar">{E(c["goals"])}</p>')
    groups, table = c.get("groups") or [], c.get("table")
    if table and c.get("wide"):
        cols = [f"<div>{st_table(table)}</div>"]
        for g in groups:
            cols.append("<div>" + (f'<h4>{E(g["heading"])}</h4>\n' if g.get("heading") else "") + st_lines(g.get("lines") or []) + "</div>")
        h.append('<div class="st-cols">' + "\n".join(cols) + "</div>")
    else:
        if table: h.append(st_table(table))
        for g in groups:
            if g.get("heading"): h.append(f'<h4>{E(g["heading"])}</h4>')
            h.append(st_lines(g.get("lines") or []))
    links = [(safe_link(l.get("href")), l.get("label")) for l in c.get("links") or []]
    links = [f'<a href="{E(u)}">{E(t)}</a>' for u, t in links if u]
    if links: h.append('<div class="st-links">' + "".join(links) + "</div>")
    h.append("</section>")
    return "\n".join(h)

status = load_status()
check(status_texts(status), "status.json")
standing = (f'<section class="st" aria-labelledby="standing">\n<h2 id="standing">Where things stand</h2>\n'
            f'<p class="st-lede">Updated {E(status.get("updated"))}. {E(status.get("lede"))}</p>\n'
            f'<div class="st-grid">\n\n' + "\n\n".join(st_card(c) for c in status["cards"]) + '\n</div>\n</section>')

ST_CSS = r'''/* "Where things stand": one card per track, plain words, a state chip on every line (scoped st-). */
.st{display:flex;flex-direction:column;gap:14px}
.st-lede{color:var(--muted,#55594F);max-width:68ch;margin:0}
.st-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,330px),1fr));gap:16px;align-items:start}
.st-card{background:var(--card,#FFFDF8);border:1px solid var(--line,#DDD6C2);border-radius:10px;padding:16px 18px;display:flex;flex-direction:column;gap:10px;min-width:0}
.st-card h3{font:700 19px/1.2 "Roboto Slab",Georgia,serif;margin:0;text-transform:none;letter-spacing:0;color:inherit}
.st-card h4{font:600 12px/1 Roboto,system-ui,sans-serif;text-transform:uppercase;letter-spacing:.08em;margin:4px 0 0;opacity:.75}
.st-list{margin:0;padding:0;list-style:none;display:flex;flex-direction:column;gap:8px}
.st-list li{display:grid;grid-template-columns:auto 1fr;gap:10px;align-items:baseline}
.st-list li>span:last-child{min-width:0}
.st-chip{font:600 11px/1 Roboto,system-ui,sans-serif;text-transform:uppercase;letter-spacing:.06em;padding:4px 7px;border-radius:5px;white-space:nowrap;text-align:center;min-width:76px}
.st-ok{background:#E4EEDC;color:#3F6B2E}.st-warn{background:#F4E8C8;color:#7A5200}.st-bad{background:#F6DDD8;color:#B3281E}.st-info{background:#DEE7F2;color:#2F5A8A}
.st-bar{font:500 13px "Roboto Mono",ui-monospace,monospace;opacity:.8;margin:0}
.st-tbl{border-collapse:collapse;width:100%;font-size:14px;font-variant-numeric:tabular-nums}
.st-tbl td,.st-tbl th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line,#DDD6C2)}
.st-tbl th{font:600 12px Roboto,system-ui,sans-serif;text-transform:uppercase;letter-spacing:.05em;opacity:.75}
.st-tbl td.n{font-family:"Roboto Mono",ui-monospace,monospace;white-space:nowrap}
.st-tbl td.f{color:#B3281E;font-weight:700}
.st-links{display:flex;flex-wrap:wrap;gap:8px}
.st-links a{font:600 14px Roboto,system-ui,sans-serif;padding:8px 12px;border-radius:8px;border:1.5px solid currentColor;text-decoration:none}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]) .st-ok{background:#26331F;color:#8FB36A}:root:not([data-theme="light"]) .st-warn{background:#3A3020;color:#E0B45A}:root:not([data-theme="light"]) .st-bad{background:#3E2422;color:#FF7A6E}:root:not([data-theme="light"]) .st-info{background:#1F2B3A;color:#8FB3E0}:root:not([data-theme="light"]) .st-tbl td.f{color:#FF7A6E}}
:root[data-theme="dark"] .st-ok{background:#26331F;color:#8FB36A}:root[data-theme="dark"] .st-warn{background:#3A3020;color:#E0B45A}:root[data-theme="dark"] .st-bad{background:#3E2422;color:#FF7A6E}:root[data-theme="dark"] .st-info{background:#1F2B3A;color:#8FB3E0}:root[data-theme="dark"] .st-tbl td.f{color:#FF7A6E}
</style><style>
/* polish pass */
.st-grid{grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));align-items:stretch}
.st-wide{grid-column:1/-1}
.st-cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,260px),1fr));gap:12px 28px;align-items:start}
.st-cols h4{margin:0 0 8px}
.st-list li{grid-template-columns:92px 1fr}
.st-chip{min-width:0;width:100%;padding:5px 4px;font-size:10.5px;letter-spacing:.05em}
.st-bar{font:500 14px Roboto,system-ui,sans-serif;opacity:.85}
.st-card h3{font-size:18px}
.st-links{margin-top:auto;padding-top:4px}
.card h3 .status{display:table;margin:.45rem 0 0;white-space:nowrap}
ul.parity{gap:.35rem}
.chip{padding:.4rem .45rem}
.chip .plat{white-space:nowrap;font-size:11.5px}
.chip .state{font-size:10.5px;letter-spacing:.03em;white-space:nowrap}
.list{align-items:stretch}
.legend{grid-template-columns:repeat(auto-fit,minmax(min(100%,12rem),1fr))}'''

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
<link href="https://fonts.googleapis.com/css2?family=Roboto+Slab:wght@600;700&family=Roboto:wght@400;500;700&family=Roboto+Mono:wght@500&display=swap" rel="stylesheet">
<style>
:root{{
  --bg:#F3EBD9; --card:#FFFDF8; --text:#1A1D1F; --muted:#55594F; --line:#DDD6C2; --accent:#9C5320;
  --ok:#3F6B2E; --okbg:#E4EEDC; --warn:#7A5200; --warnbg:#F4E8C8; --bad:#B3281E; --badbg:#F6DDD8; --info:#2F5A8A; --infobg:#DEE7F2;
  --neutral:#55594F; --neutralbg:#ECE5D3; --dim:#7A7565; --track:#E4DCC6;
  --display:"Roboto Slab",Georgia,serif; --body:Roboto,system-ui,-apple-system,"Segoe UI",sans-serif; --mono:"Roboto Mono",ui-monospace,Menlo,monospace;
}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{
  --bg:#1A1D1F; --card:#2A3036; --text:#DCC9A3; --muted:#B0A58A; --line:#3A4148; --accent:#DB8A4B;
  --ok:#8FB36A; --okbg:#26331F; --warn:#E0B45A; --warnbg:#3A3020; --bad:#FF7A6E; --badbg:#3E2422; --info:#8FB3E0; --infobg:#1F2B3A;
  --neutral:#B0A58A; --neutralbg:#22272C; --dim:#8A826F; --track:#1F2327; color-scheme:dark}}}}
:root[data-theme="dark"]{{
  --bg:#1A1D1F; --card:#2A3036; --text:#DCC9A3; --muted:#B0A58A; --line:#3A4148; --accent:#DB8A4B;
  --ok:#8FB36A; --okbg:#26331F; --warn:#E0B45A; --warnbg:#3A3020; --bad:#FF7A6E; --badbg:#3E2422; --info:#8FB3E0; --infobg:#1F2B3A;
  --neutral:#B0A58A; --neutralbg:#22272C; --dim:#8A826F; --track:#1F2327; color-scheme:dark}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 var(--body)}}
a{{color:var(--accent)}}
.wrap{{max-width:1100px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px))}}
header{{padding-block:2rem 1rem}}
header a.home{{text-decoration:none;color:var(--muted);font-size:.95rem}}
.kicker{{margin:1rem 0 0;color:var(--accent);font:500 13px var(--mono);letter-spacing:.04em;text-transform:uppercase}}
h1{{font:700 clamp(28px,5vw,38px)/1.15 var(--display);margin:.25rem 0 .5rem;text-wrap:balance}}
.lede{{color:var(--muted);margin:0;max-width:68ch}}
.platforms{{margin:.75rem 0 0}}
main{{display:flex;flex-direction:column;gap:28px;padding-bottom:2.5rem}}
h2{{font:700 20px/1.25 var(--display);margin:0 0 .25rem;text-wrap:balance}}
.note{{color:var(--muted);font-size:14px;margin:0 0 .75rem;max-width:68ch}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:16px;align-items:start}}
.grid.one{{margin-top:16px;grid-template-columns:minmax(0,1fr)}}
.list{{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,340px),1fr));gap:16px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px;min-width:0;display:flex;flex-direction:column}}
.card h3{{font:700 16px/1.35 var(--display);margin:0 0 .3rem}}
.card p{{margin:0 0 .85rem;color:var(--muted);font-size:14.5px}}
.card.wide .inner{{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,320px),1fr));gap:12px}}
.card.wide .card{{background:transparent}}
.big{{font:700 22px/1.2 var(--display);color:var(--text)!important;margin:.25rem 0 .6rem!important}}
.mono{{font:500 13px var(--mono);color:var(--muted)}}
ul.links{{list-style:none;margin:0 0 .75rem;padding:0;display:flex;flex-direction:column;gap:.4rem}}
.status{{font:600 11px/1 var(--body);text-transform:uppercase;letter-spacing:.06em;padding:4px 7px;border-radius:5px;vertical-align:middle;background:var(--warnbg);color:var(--warn);margin-left:.3rem}}
ul.parity{{list-style:none;margin:auto 0 0;padding:0;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.4rem}}
.chip{{border-radius:7px;padding:.4rem .5rem;min-width:0;background:var(--neutralbg);color:var(--neutral)}}
.chip .plat{{display:block;font-size:12px;color:var(--muted);line-height:1.3}}
.chip .state{{display:flex;align-items:center;gap:.3rem;font:600 11px/1.3 var(--body);text-transform:uppercase;letter-spacing:.06em;margin-top:2px}}
.chip.done{{background:var(--okbg);color:var(--ok)}} .chip.building{{background:var(--warnbg);color:var(--warn)}}
.chip.planned{{background:var(--neutralbg);color:var(--neutral)}} .chip.later{{background:var(--infobg);color:var(--info)}}
.chip.na{{background:transparent;color:var(--dim);border:1px dashed var(--line)}}
.ic{{flex:none}}
.legend{{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,15rem),1fr));gap:.5rem}}
.legend .chip{{display:flex;gap:.6rem;align-items:center}}
.legend .chip .state{{margin-top:0;min-width:5.2rem}}
.legend .mean{{color:var(--text);font-size:13.5px}}
ul.prog{{list-style:none;margin:.4rem 0 0;padding:0;display:flex;flex-direction:column;gap:.7rem}}
ul.prog li{{display:grid;grid-template-columns:1fr auto;gap:.25rem .75rem;align-items:baseline}}
.pname{{font-weight:500}} .pcount{{font:500 13px var(--mono);color:var(--muted)}}
.meter{{grid-column:1/-1;height:10px;border-radius:5px;background:var(--track);overflow:hidden}}
.meter span{{display:block;height:100%;background:var(--ok);border-radius:5px}}
ul.prog.small .meter{{height:6px}} ul.prog.small .pname{{font-size:14px;font-weight:400}}
.box{{background:var(--card);border-radius:10px;padding:16px 18px;border:1px solid var(--line)}}
.box ul{{margin:.25rem 0 0;padding-left:1.2rem}}.box li{{margin:.2rem 0;max-width:65ch}}
.later-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,16rem),1fr));gap:1rem 2rem}}
.later-grid h3{{font:600 12px/1 var(--body);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 .4rem}}
.later-grid ul{{margin:0;padding-left:1.2rem;color:var(--muted)}}.later-grid li{{margin:.15rem 0}}
.meta{{color:var(--muted);font-size:13.5px;margin:0}}
@media (max-width:380px){{ul.parity{{grid-template-columns:1fr}}.chip .plat{{display:inline;margin-right:.4rem}}.chip{{display:flex;justify-content:space-between;align-items:center}}}}
footer{{padding-block:1.25rem 3rem;border-top:1px solid var(--line);color:var(--muted);font-size:13.5px}}
footer .wrap{{display:flex;gap:1rem 1.5rem;flex-wrap:wrap}}
</style><style>
{ST_CSS}
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
{standing}
<section aria-labelledby="key"><h2 id="key">How to read this</h2><ul class="legend">{legend}</ul></section>
{group("Must-have", "Must-have", f"The promise. Cache {RELEASE} is not stable until every one of these works.")}
{group("Stretch", "Stretch", "Ride along if ready; never hold the release.")}
<section class="box" aria-labelledby="stable"><h2 id="stable">What "stable" means</h2><ul>{stable_html}</ul></section>
<section aria-labelledby="later"><h2 id="later">Later</h2><p class="note">Planned for later releases. Details and dates are not set.</p><div class="later-grid">{later_html}</div></section>
<p class="meta">Updated <time datetime="{today}">{today}</time>. Generated from the <a href="{PROJECT_URL}">Cache roadmap project on GitHub</a>.</p>
</main>
<footer><div class="wrap"><span>Happy Little LLC</span><a href="mailto:info@happylittlellc.com">info@happylittlellc.com</a><a href="/changes">What's new</a><a href="/privacy">Privacy</a></div></footer>
</body>
</html>
"""
# Final pass over the whole page; the project link is the one allowed mention of the account name.
check(page.replace(PROJECT_URL, ""), "generated page")
open(out, "w", encoding="utf-8").write(page)
print(len(cur), "items,", sum(len(t) for t in later.values()), "later,", f"{done}/{total} platform cells done")
