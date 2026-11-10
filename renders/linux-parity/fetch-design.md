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

## Decisions (coordinator, 2026-11-09)
- The `user` scope is on by default, for parity with the phone.
- `/api/fetch` (every scope but catalog) and the server's download, checksum and icon paths are guarded: private, loopback, link-local, Tailscale 100.64/10 and the metadata address 169.254.169.254 are refused at connect time, including after redirects. The three catalog hosts are the one exception. The core-crate network paths reachable from `/api/core` are not guarded yet (next section). Tests for the guarded paths: LAN, loopback, 169.254.169.254, a hex-spelled 127.0.0.1, a redirect to loopback, a redirect to 169.254.169.254, and a public address that still passes (server/tests/library.rs, fetch_scope.rs).
- Each non-catalog `/api/fetch` read has one 90 s deadline (redirects and body included), so a slow trickle cannot hold the 8 slots. The checksum and icon fetches keep their own 30 s limit. The main download has no overall deadline (files are large); it stops on a 30 s idle read.

## Core-crate paths (built: item core-guard)
Built as designed, with these specifics. The address rule and the resolver live once, in the small crate `cache_netguard` (packages/cache_search/native/cache_netguard); `server/src/fetch_scope.rs` re-exports them. cache_video, cache_live, cache_layers and cache_regions build their client through `cache_netguard::guarded` (guard only when `CACHE_NET_GUARD=public`, which server/src/helper.rs sets in the helper's environment; a no-op on a phone). The model's web read and search (cache_search/src/web.rs) use `cache_netguard::always`: guarded on every platform, with no setting; a blocked read is the existing connect-layer failure (`[full page not available]` for a read, fetch_failed for a search). The search provider's own endpoint is owner configuration and is not guarded; everything the model reads through it is. The owner allow-list is not built: `PublicResolver.allow` is an empty, unread hook. Sync is out of scope. The original design text follows.
A signed-in tab reaches these through POST /api/core, then the helper, then the shared core crates (packages/cache_search/native). All use ureq with the system resolver, follow redirects unchecked (ureq's default is 5), and have no address check.
| Path | Where | Reached by | Address comes from |
|---|---|---|---|
| Video: instance add, API, tokens, captions, files | cache_video/src/http.rs:12-18 (agent), :95 get_json, :107 post_form, :117 post_empty, :124 get_bytes, :146 get_file; api.rs:159-162 `instance_add` fetches `{base}/api/v1/config`; `check_url` http.rs:23 allows plain http to loopback | the video ops (add instance, list, search, download) | the typed instance address (store.rs:27 `normalize` accepts `http://127.0.0.1:9000`), and URLs inside PeerTube answers |
| Live sources and connectors | cache_live/src/request.rs:678-681 agent, :95 `check_url`; preview at preview.rs:121 via ffi.rs:839 `cs_live_preview` | weather start/refresh, own sources, livePreview | connector definitions, which a tab can supply, and URLs in responses |
| Map layers | cache_layers/src/http.rs:135-141 agent, :152 get, :250 get_once, :294 get_ok; callers core.rs:299, :352, :455, :534, pmtiles.rs:340 | layer ops, tile and TileJSON reads | a user layer's tile or TileJSON URL |
| Regions and routing data | cache_regions/src/http.rs:32-33 agent, :51 get; lib.rs:559, :588, :723 | region ops, region download | `base` (data.cached.info by default; compile-time `CACHE_DATA_BASE`), so low risk |
| Web search and the model's web read | cache_search/src/web.rs:325-327 `web_agent` (redirects 5), :402-407 request, :461 `fetch_page` | the chat tool loop (`web_read` takes a URL the model chose, so prompt injection can aim it) | the model |
| Sharing and sync | cache_sync/src/lib.rs:1623 (relay config), iroh QUIC and mDNS | sync ops | paired devices; LAN is the point. Not HTTP, out of scope here |
Not reachable from a tab: places_pack and offroad_pack (build tools); cache_embed and cache_llama (no network).

### Mechanism (server-only; phones unchanged)
- Add a small module in a crate every one of these already depends on (cache_live is shared by video, layers and search; or a tiny new `cache_netguard`): a process-wide `OnceLock<Guard>` and `fn guarded(builder: AgentBuilder) -> AgentBuilder` that sets a ureq `Resolver` only when the guard is installed. Each crate's `AgentBuilder::new()` call (the six places above) goes through it. With the guard not installed it is a no-op, so the phone path is byte-identical.
- ureq asks the resolver at every connect, and a redirect is a new connect, so one resolver covers redirects and DNS rebinding, with no per-crate redirect code. It is the same address rule as `fetch_scope::is_public` (the rule moves to the shared module and the server imports it).
- Install only in the server's helper: the server sets `CACHE_NET_GUARD=public` in the helper's environment when it spawns it (server/src/helper.rs), and the library reads it once on first use. Phones and the desktop `cs` CLI never set it.
- The plain-http-to-loopback allowance in `check_url` (cache_video, cache_live) stays for tests; under the guard the resolver refuses it anyway.

### Should the owner be able to allow named LAN addresses (a home PeerTube)?
Recommend yes, narrowly: a phone reaches a home server, so full parity needs it. `CACHE_NET_ALLOW` (set from the server's own config file, never from the API or a tab, so a tab cannot widen it) lists exact hosts or CIDRs, default empty. It applies to every guarded path (core crates, `/api/fetch`, downloads). Link-local (169.254/16, so the metadata address), multicast and unspecified can never be allowed; loopback and 100.64/10 only if named exactly. A change needs a server restart. This is a policy choice for the owner; it is not built.

### Tests
- Guard unit tests (shared module): every case in `is_public`, the allow-list (exact host, CIDR, never link-local), resolver refuses a name that resolves to loopback, a hex-spelled address.
- Per crate, with the guard installed and a local listener: video `instance_add("http://127.0.0.1:PORT")` is refused and the listener sees no request; a redirect from an allowed host to loopback and to 169.254.169.254 is refused; same for cache_live request, layers get, web `fetch_page`.
- Per crate, guard not installed: the same loopback call still works (the existing tests), proving the phone path is unchanged.
- Server: spawn the helper (fake-helper) and check it receives `CACHE_NET_GUARD=public`; an end-to-end `instance_add` of a LAN address through /api/core returns an error and makes no connection.

## Left alone
The embedder model download (embed.rs) uses a fixed address the server owns, not one a tab supplies, so it is unchanged. io code paths in the app are unchanged.
