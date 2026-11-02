"""Builds cached.info's Features page (features.html) from docs/features.yml.
Usage: gen_features.py docs/features.yml out.html
Needs ROADMAP_BLOCKLIST (see gen_roadmap.py): any match in the file or the finished page stops the build."""
import html, os, re, sys
import yaml

src, out = sys.argv[1], sys.argv[2]
if not os.environ.get("ROADMAP_BLOCKLIST"): sys.exit("STOP: ROADMAP_BLOCKLIST is not set")
BANNED = re.compile(os.environ["ROADMAP_BLOCKLIST"], re.I)
# Retired product names: never published, whatever the blocklist secret says.
RETIRED = re.compile(r"\bcache\s+server\b", re.I)
PLATFORMS = [("android", "Android"), ("ios", "iPhone & iPad"), ("linux", "Linux & Pi")]

raw = open(src, encoding="utf-8").read()
if BANNED.search(raw) or RETIRED.search(raw): sys.exit("STOP: a blocked word was found in the features file; nothing was written")
data = yaml.safe_load(raw)
version = str(data["version"])

def cell_value(v, where):
    v = "-" if v is None else str(v).strip()
    if v.lower() in ("now", "yes", "true"): return "now"
    if v in ("-", ""): return "-"
    if re.fullmatch(r"\d+\.\d+", v): return v
    sys.exit(f"STOP: {where} has '{v}'; use now, a release such as 1.1, or -")

CHECK = '<svg viewBox="0 0 16 16" width="18" height="18" aria-hidden="true"><path d="M3 8.5l3.2 3L13 4.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>'

def cell(v, platform):
    if v == "now":
        return f'<td class="now">{CHECK}<span class="sr">{platform}: available now</span></td>'
    if v == "-":
        return f'<td class="na"><span aria-hidden="true">&ndash;</span><span class="sr">{platform}: not applicable or not planned</span></td>'
    return f'<td class="soon"><span class="rel" aria-hidden="true">{v}</span><span class="sr">{platform}: coming in {v}</span></td>'

body = []
for a in data["areas"]:
    area = a["area"]
    aid = "a-" + re.sub(r"[^a-z0-9]+", "-", area.lower()).strip("-")
    rows = [f'<tr class="area"><th colspan="4" scope="colgroup" id="{aid}">{html.escape(area)}</th></tr>']
    for f in a["features"]:
        name = f["feature"]
        cells = "".join(cell(cell_value(f.get(k), f"{name} / {k}"), label) for k, label in PLATFORMS)
        rows.append(f'<tr><th scope="row" headers="{aid}"><span class="fname">{html.escape(name)}</span>'
                    f'<span class="ftext">{html.escape(f.get("text", ""))}</span></th>{cells}</tr>')
    body.append(f'<tbody>{"".join(rows)}</tbody>')

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Cache features</title>
<meta name="description" content="What Cache does on Android, iPhone and iPad, and Linux and Raspberry Pi.">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Roboto+Slab:wght@500;700&family=Roboto:wght@400;500&display=swap" rel="stylesheet">
<style>
:root {{ --ground:#1a1d1f; --card:#2a3036; --text:#dcc9a3; --muted:#b0a58a; --clay-text:#db8a4b; --line:#3a4148; --band:#22272c;
  --now:#8fc19a; --soon:#e0a868; --na:#7d7768; color-scheme: dark; }}
@media (prefers-color-scheme: light) {{ :root:not([data-theme="dark"]) {{ --ground:#f5efe3; --card:#fffaf1; --text:#2b2722; --muted:#655b4b;
  --clay-text:#9a4c14; --line:#ddd2bf; --band:#efe6d5; --now:#2f7a43; --soon:#9a5a10; --na:#857c6c; color-scheme: light; }} }}
:root[data-theme="light"] {{ --ground:#f5efe3; --card:#fffaf1; --text:#2b2722; --muted:#655b4b; --clay-text:#9a4c14; --line:#ddd2bf;
  --band:#efe6d5; --now:#2f7a43; --soon:#9a5a10; --na:#857c6c; color-scheme: light; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--ground); color:var(--text); font:17px/1.6 Roboto, system-ui, -apple-system, "Segoe UI", sans-serif; }}
a {{ color:var(--clay-text); }}
.wrap {{ max-width:56rem; margin:0 auto; padding-left:max(16px, env(safe-area-inset-left)); padding-right:max(16px, env(safe-area-inset-right)); }}
header {{ padding-block:2.5rem 1.25rem; }}
header a.home {{ text-decoration:none; color:var(--muted); font-size:.95rem; }}
h1 {{ font:700 clamp(1.8rem, 5vw, 2.5rem)/1.2 "Roboto Slab", Georgia, serif; margin:.75rem 0 .5rem; text-wrap:balance; }}
.lede {{ color:var(--muted); margin:0; max-width:62ch; }}
.links {{ margin:.75rem 0 0; display:flex; gap:.5rem 1.25rem; flex-wrap:wrap; }}
main {{ padding-bottom:2.5rem; }}
.legend {{ list-style:none; margin:0 0 1rem; padding:0; display:flex; flex-wrap:wrap; gap:.5rem 1.5rem; color:var(--muted); font-size:.92rem; }}
.legend li {{ display:flex; align-items:center; gap:.4rem; }}
.legend .k {{ display:inline-flex; min-width:1.6rem; justify-content:center; font-weight:500; }}
table {{ width:100%; border-collapse:separate; border-spacing:0; background:var(--card); border-radius:18px; overflow:hidden; table-layout:fixed; }}
col.plat {{ width:7.5rem; }}
thead th {{ background:var(--card); font:500 .85rem/1.3 Roboto, sans-serif; color:var(--muted); padding:.9rem .5rem; text-align:center; border-bottom:1px solid var(--line); }}
thead th:first-child {{ text-align:left; padding-left:1.1rem; }}
tr.area th {{ background:var(--band); font:700 1rem/1.3 "Roboto Slab", Georgia, serif; text-align:left; padding:.7rem 1.1rem; color:var(--text); }}
tbody th[scope=row] {{ text-align:left; font-weight:400; padding:.65rem .5rem .65rem 1.1rem; border-top:1px solid var(--line); vertical-align:top; }}
.fname {{ display:block; font-weight:500; }}
.ftext {{ display:block; color:var(--muted); font-size:.9rem; line-height:1.45; }}
td {{ text-align:center; vertical-align:middle; border-top:1px solid var(--line); padding:.5rem .25rem; }}
tr.area + tr th, tr.area + tr td {{ border-top:0; }}
td.now {{ color:var(--now); }}
td.soon .rel {{ display:inline-block; font-weight:500; font-size:.85rem; color:var(--soon); border:1px solid currentColor; border-radius:6px; padding:0 .35rem; }}
td.na {{ color:var(--na); }}
.sr {{ position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); white-space:nowrap; }}
.meta {{ color:var(--muted); font-size:.9rem; margin:1rem 0 0; }}
@media (max-width: 560px) {{
  col.plat {{ width:3.9rem; }}
  thead th {{ font-size:.72rem; padding:.7rem .15rem; }}
  thead th:first-child, tr.area th, tbody th[scope=row] {{ padding-left:.75rem; }}
  .ftext {{ font-size:.85rem; }}
}}
footer {{ padding-block:1.5rem 3rem; border-top:1px solid var(--line); color:var(--muted); font-size:.95rem; }}
footer .wrap {{ display:flex; gap:1rem 1.5rem; flex-wrap:wrap; }}
</style>
</head>
<body>
<header><div class="wrap"><a class="home" href="/">&larr; Cache</a>
<h1>Features</h1>
<p class="lede">What Cache does today on each kind of device, and what is coming. Current version {html.escape(version)}.</p>
<p class="links"><a href="/roadmap">Roadmap</a><a href="/changes">What's new</a></p>
</div></header>
<main class="wrap">
<ul class="legend" aria-label="Key">
<li><span class="k" style="color:var(--now)">{CHECK}</span>Available now</li>
<li><span class="k"><span class="rel" style="color:var(--soon);border:1px solid currentColor;border-radius:6px;padding:0 .35rem;font-size:.85rem">1.1</span></span>Coming in that release</li>
<li><span class="k" style="color:var(--na)">&ndash;</span>Not applicable or not planned</li>
</ul>
<table>
<caption class="sr">Cache features by device</caption>
<colgroup><col><col class="plat"><col class="plat"><col class="plat"></colgroup>
<thead><tr><th scope="col">Feature</th>{"".join(f'<th scope="col">{html.escape(l)}</th>' for _, l in PLATFORMS)}</tr></thead>
{"".join(body)}
</table>
<p class="meta">Cache on Linux and Pi is the full app in a browser, from 1.1. Windows comes in 1.2.</p>
</main>
<footer><div class="wrap"><span>Happy Little LLC</span><a href="mailto:info@happylittlellc.com">info@happylittlellc.com</a><a href="/changes">What's new</a><a href="/roadmap">Roadmap</a><a href="/features">Features</a><a href="/privacy">Privacy</a></div></footer>
</body>
</html>
"""
if BANNED.search(page) or RETIRED.search(page): sys.exit("STOP: a blocked word was found in the finished page; nothing was written")
open(out, "w", encoding="utf-8").write(page)
print(sum(len(a["features"]) for a in data["areas"]), "features in", len(data["areas"]), "areas, version", version)
