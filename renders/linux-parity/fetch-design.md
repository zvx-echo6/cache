# fetch: network fetch parity in the browser (audit DIFFERENT item 6, "Network fetch policy")

## What the phone fetches from (app/lib, checked on this branch)
| Feature | Host / pattern | Where | On web today |
|---|---|---|---|
| Published data: region, off-road catalogues, discover, app/latest.json, routing and places | data.cached.info (`kDataBaseUrl`) | search/core_config.dart:11-17, regions/region_catalogue.dart:12, offroad_catalogue.dart:10, discover_state.dart:16, update/app_update.dart:10 | works (catalog) |
| Connector catalogue | data.cached.info, cache.echo6.co; a list the person typed (any https) and its definitions | settings/app_settings.dart:9, weather/catalogue_store.dart:23-75 | default works; typed list blocked |
| Recommended models | data.cached.info/models/recommended.json | models/recommendations.dart:11,246 | works |
| Models: search and file list | huggingface.co `/api/models`, `/api/models/<repo>/tree/main` | models/hf_hub.dart:60 (dart:io HttpClient) | MISSING |
| Models: file download | huggingface.co `/<repo>/resolve/<rev>/<path>`, then its CDN (`*.hf.co`); Cache's own files on data.cached.info | hf_hub.dart:139, models/model_downloads.dart, browse/zim_download.dart:98 | models item (server job) |
| Kiwix catalogue and icons | opds.library.kiwix.org | browse/opds.dart:15,292, catalogue_screen.dart:437 | works (catalog) |
| ZIM and library downloads, own-library link | any https the person gives | server job `/api/library/download` (library.rs add_download) | works (server job) |
| Library icons | any https (OPDS or link) | browse/browse_state.dart:746 | blocked |
| Video captions | a PeerTube site: `/lazy-static/video-captions/..`, `/static/..`, its object storage | video/captions.dart:74 | blocked |
| PeerTube API (list, search, login), weather and live sources, Kagi | the Rust core in the helper reads them | cache_video, cache_live (server side) | works (no browser fetch) |
| Video thumbnails, avatars, the stream | PeerTube host, from the browser | screens/videos/widgets.dart:56, instance_screen.dart:187, player_screen.dart:269 | videos item (Image.network and video tag, no fetch) |
| Own data source, "Try this address" | any https the person typed | weather/own_source.dart:229 | blocked |
| Local tile server (127.0.0.1) | this machine | maps/layers/core_layer_engine.dart:260-307, nav/elevation/route_sampler.dart:28 | maps item (`/api/tiles`) |

Direct dart:io HttpClient uses: net/fetch.dart:67, opds.dart:294 (both already go through the device on web), hf_hub.dart:56 (fixed here), zim_download.dart:98 (models item), core_layer_engine.dart:305 and route_sampler.dart:28 (local, maps item).

## Decision: scopes on /api/fetch, not one wider list, not many routes
`GET /api/fetch?url=&scope=catalog|models|video|user[&plain=1]`. Default `catalog` is the old behaviour. One route and one code path (redirects re-checked each hop, 8 MB cap, size from the declared length, sandbox headers), with a rule per scope (server/src/fetch_scope.rs):
- catalog: the three hosts, as before (50 MB).
- models: huggingface.co `/api/models...` only, plus the catalog hosts. With `download` set (for the models item's server job) also its `/resolve/` paths and `*.hf.co`, `*.huggingface.co` redirect targets.
- video: any public host, but only `/api/v1/`, `/lazy-static/`, `/static/` on the first request; a redirect (object storage) may go to any public host.
- user: any public host; for what the person typed (own data source, own catalogue list, library icons).
A wider catalog list was rejected: PeerTube sites and typed addresses have no fixed host. Per-feature routes were rejected: they repeat the fetch, redirect and size code for no extra safety. Scopes give the safety by narrowing path and type.

## Not an open proxy, and no SSRF
- Every non-catalog scope refuses addresses that are not public, checked on what the name resolves to at connect time (`PublicResolver`, an ureq resolver), so redirects, rebinding names and odd spellings of 127.0.0.1 are covered. Refused: loopback, 10/8, 172.16/12, 192.168/16, link-local (169.254, cloud metadata), 100.64/10 (Tailscale), multicast, reserved; IPv6 loopback, ULA, link-local, and IPv4 inside IPv6 (mapped, NAT64, 6to4). Any one bad address in the answer refuses the name. IP-literal and `.local`/`.internal` names are stopped before lookup.
- Only small readable answers leave a non-catalog scope: JSON, XML, text (not html), images (not svg), at most 8 MB. A video, a file or a page is 415. So a tab cannot use it to pull files or to host a page of this origin. Headers: CSP sandbox and nosniff.
- GET only, no cookies or keys sent, session required, at most 8 non-catalog reads at once (429 busy).
- `user` is the one scope with no host or path rule (the phone also reads any https address it is given). It can be switched off on the server (`LibraryOptions.fetch_user`, 403 scope_off). This is the owner's call; see the report.

## Data policy (settings/data_policy.dart)
The phone's policy is "Mobile data downloads": it gates big downloads on a mobile connection. Updates (catalogues, lists, captions, icons) always use any connection. /api/fetch carries only that second kind, and its caps (8 MB, 50 MB for catalog) mean a big file is refused (413) rather than fetched. Big files go through download jobs, which the app gates with the same `DataPolicy.checkDownload` before it starts the job, in the browser too. The server has no mobile-data notion of its own.

## API for the other items
Rust: `fetch_scope::Policy::new(scope, catalog_hosts)` with `.plain`, `.download`; `policy.check(url, first_hop)`; `fetch::open_with(&policy, url, max)`; `fetch_scope::PublicResolver` with `fetch::agent_with(Some(..))` for a streaming download that must apply the same address rule.
Dart: `fetchBytes(url, scope: FetchScope.video|models|user, httpsOnly:)`, `fetchText(...)`, `DeviceApi.fetch(url, {scope, plain})`; failures arrive as `FetchException` (notAllowed, unreachable, status, tooLarge, unreadable).
- Videos: captions already use `FetchScope.video`. Thumbnails and avatars are not fetches (img tag); if CORS blocks them use `/api/fetch?scope=video&url=` as the Image.network address.
- Models: search and file list already use `FetchScope.models` (hf_hub.dart). For the file download, use `Policy{scope: Models, download: true}` and the public resolver in the server job.

## Left alone
Server downloads (library.rs add_download, icons) do not apply the public-address rule yet; they accept any https address. Applying `PublicResolver` there is a one-line change but alters the download path, so it is reported, not done. io code paths are unchanged.
