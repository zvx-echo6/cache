# C.A.C.H.E. — Crisis Assistant for Contingencies, Hardship & Emergencies

An offline survival and preparedness assistant for phones and computers. Everything runs on the device with no network: a local LLM, a library, Kiwix, maps and routing.

Cache is a framework. No data and no models ship inside the app: people add the sources they want (models, ZIMs, library packs, region packs). The app must never depend on hosting run by the owner, so it can go to the app stores later.

Cache is built to pull data while online and then work offline for long periods, until it can get back online. Data with a clear end date, such as weather forecasts and alerts, carries the time it was fetched and when it stops being valid. Once it has expired, the app and the assistant say so plainly (for example: "I no longer have weather data. We need to go online for more.") instead of using it, and the app refreshes it when a connection returns.

Cache aims to be an all-in-one emergency app: install it, configure it while things are normal, and not find out in a crisis that some other app should have been installed beforehand.

- **Repo:** github.com/zvx-echo6/cache (private)
- **Board:** GitHub project "C.A.C.H.E." (owner zvx-echo6). Status lives on the board.
- **Audience:** the owner, family and close friends first; the app stores possibly later.
- **Decided 2026-10-20 to 2026-10-24.**

## Decisions

| Area | Decision |
|---|---|
| Name | C.A.C.H.E. — Crisis Assistant for Contingencies, Hardship & Emergencies. Called "Cache". |
| Assistant name | Not decided yet. The assistant is not called AIDA in Cache. |
| App layout | Four tabs: Home, Ask, Browse, Maps. Home: an Ask box, quick actions (Hospital, First aid, Water, Navigate) and small status cards (model, reading, maps, search, weather; a card shows when data has expired and needs a connection). Ask: ChatGPT-style chat, sources collapsed into one pill. Browse: the offline browser, including connected video sources and downloaded videos. Maps: full-screen map with one search bar; nearby and routing appear after a search or a tap. Models and Downloads open from Home. Dark theme, calm screens, one main thing per screen. Decided 2026-10-24 from mockups. |
| Platforms | Android and iPhone first; Windows later. |
| Framework | Flutter, with native C/C++ libraries called through FFI (and Rust through flutter_rust_bridge for Tantivy). |
| App is a framework | No data or models are bundled. Every source is added by the user or picked from a public catalogue. Nothing depends on owner-run hosting. Decided 2026-10-24. |
| LLM runtime | llama.cpp (GGUF) for every model. LiteRT-LM may be added later for the E models only, if memory needs it. |
| Models | Downloaded in the app from Hugging Face: search the whole catalogue, with each model's size and whether it fits the device. The owner's trained models ("Cached models") are published on Hugging Face under a neutral account and listed at the top of the Hugging Face section. |
| Recommended model | Gemma 4 E2B, uncensored (huihui-ai or TrevorJS; choose by quiz). Optional: Gemma 4 E4B (TrevorJS), Qwen3 8B (Josiefied), Gemma 4 12B (AIDA). The app recommends the largest that fits the device's RAM; the user can pick any that fits. |
| Network models (optional) | Any OpenAI-compatible model server the phone can reach, on the internet or only on local Wi-Fi (no internet needed): cloud services (OpenAI, OpenRouter, Groq and similar) or the user's own servers (Ollama, LM Studio, llama-server, Open WebUI; Open WebUI's OpenAI-compatible API lives under /api with a key from its user settings, and its models show up as models). Two ways to connect: automatic discovery on the local network (mDNS), or typing an IP address and port (plus an optional API key). Users bring their own key where one is needed. Anthropic and Gemini connectors only if asked for later. A network server provides only compute and the model; all data stays on the phone. Server-side knowledge, documents, RAG and tools (for example Open WebUI knowledge bases) are not used. Search tools and citation checks run on the device, and the setup screen says plainly that questions and matching source snippets go to that server. Only models that pass the tool check can be used (see Tool-capable models). If the server can't be reached, the app falls back to the on-device model if one is installed and says so. The Windows version of Cache can serve its model to phones on the same Wi-Fi, so one computer can be the household's model server. Decided 2026-10-24. |
| Tool-capable models only | Every model, on-device or network, must support tool calls, so the model always decides what to search and every answer can cite the phone's data. On-device: the GGUF's chat template must support tool calls (read through llama.cpp's chat engine); models without it are marked "Not supported" and can't be activated, flagged in Hugging Face search where the template is visible, otherwise checked right after download. Network: on connecting, the app sends one test request asking the model to call a test tool; a model that doesn't return a proper tool call is marked as not supporting Cache's tools and can't be picked (Ollama also reports tool support directly). There is no fallback for models without tool support. Decided 2026-10-24. |
| Answer style | Complete answers are fine. Cache is not the mesh, so the 300-byte mesh limit does not apply. |
| Library | User-loaded library packs. The pack format follows recon concepts without the verbatim `content` field: title, summary, key facts, keywords, book title and page. Answers cite book and page. The app ships no library; the owner's recon library is loaded privately like any other pack. The owner's recon PeerTube (video) concepts become a separate video library pack; their citations open the video at the right time. The recon code is to be published on GitHub so people can build their own library packs; this is a to-do before any public release and needs the owner's go. |
| Browse (Kiwix) | An offline browser: ZIMs and library packs open like websites, with a start page of sites, an address bar, tabs, back and forward, bookmarks, history and one search. ZIMs come from Kiwix's public catalogue, from any other catalogue in Kiwix's catalogue (OPDS) format added as a source (for example the owner's recon ZIMs, privately), or imported from a file on the device or SD card. ZIMs are used as they are, through libzim / libkiwix. |
| Search | One search box across all ZIMs and library packs, with Tantivy-quality full-text indexing. The phone indexes each newly added ZIM itself, slowly and in the background. Ready-made indexes for large, popular ZIMs are published with the region packs. Keyword search (Tantivy) and meaning search (vectors in the library packs) run together and merge into one ranked list; the assistant uses the same search. |
| Videos | Video source connectors, starting with PeerTube through its official REST API (for example the owner's stream.echo6.co, with login where the instance needs it). Browse and search a connected instance, stream when online, and download videos for offline use where the instance allows downloads, choosing the resolution (or audio only) to save space. Downloaded videos play offline. The assistant can cite video concepts (from a video library pack) and open the video at the cited time, offline if downloaded, otherwise streamed. Optional YouTube connector, online only: the user follows in-app instructions to connect with their own YouTube Data API key; it can search, play in YouTube's official embedded player and bookmark. No YouTube downloads (YouTube's terms forbid them, and store rules reject downloaders); the assistant can cite bookmarked YouTube videos by title and description only. Only sources with an official API; no scraping. Decided 2026-10-24. |
| Maps | Full parity with navi's layers, places and features: basemap, hillshade and terrain, land cover, land ownership (US: PAD-US, MVUM), places and geocoder, nearby (hospital, ER, fuel, trailhead and the rest), road and off-road routing. Delivered as downloadable region packs. |
| Region packs | Built by the owner from public open data and published to free hosting (Hugging Face datasets; GitHub Releases caps files at 2 GB). The owner builds and maintains a baseline set; nothing is served from owner-run hosting. State- and country-sized regions build on GitHub Actions; continent-sized ones (about 14 GB disk and 6 h limits on free runners) build on the owner's machines and are only uploaded. OSM data needs ODbL attribution in the app's credits. |
| Map data sources | Basemap: Protomaps planet builds (PMTiles). Terrain: Copernicus DEM (AWS Open Data). Land cover: ESA WorldCover (AWS Open Data). Places: Overture Maps (AWS/Azure Open Data). Roads, routing and geocoder: OSM regional extracts (Geofabrik). US land ownership: PAD-US (USGS), MVUM (Forest Service). No public host offers ready-made Valhalla tiles, so the packs carry them. |
| Coordinates | Offline, for any point (with copy) and accepted in map search: latitude/longitude (decimal and degrees-minutes-seconds), USNG/MGRS, and Plus Codes (Open Location Code). what3words through its official API (Flutter package `what3words`) when online: words for a point, words accepted in search with autosuggest; words for saved places are cached for offline. The what3words offline SDK is a paid licence and is not planned. The API key is never committed to the repo. Decided 2026-10-24. |
| Live sources | An on-device source engine for online data the app pulls before going offline, modelled on the owner's Conduit broker. A source is a definition file (data, never code): URL template, API key alias, static headers, refresh interval and validity (when the data expires), quota caps per minute, day and month, and a field mapping that says which JSON fields are name, value, place and time. Fetch once and share across the map, Home cards and assistant tools; concurrent requests coalesce into one fetch; keys live in the phone's secure storage (Android Keystore, iOS Keychain), entered once and never shown again. When an upstream fails, the last good copy is shown "as of" its time; once past its end date the app and assistant say it has expired and needs a connection. When online, sources for saved places refresh on a schedule. Source definitions are added or shared like other sources; a starter catalogue is offered like the ZIM catalogue, never built in. Each source definition states whether it needs an API key. Sources that need no key (for example NWS, SWPC, USGS, WFIGS, Celestrak, Open-Meteo) work out of the box after setup; sources that need a key are opt-in, with step-by-step setup instructions in the app, and each user brings their own key. A Conduit server can itself be a source. Assistant tools are generic per kind of source (weather, fuel_prices, alerts and so on), each citing its source and age. Decided 2026-10-24. |
| Weather | Cached forecasts from Open-Meteo, as a live source. When online, the app downloads forecasts for saved places and the current area (hourly for a few days, daily up to about 16 days); offline it shows the cached forecast with its age stated plainly. A `weather` tool returns the cached forecast as a numbered source, so the assistant can answer and cite it, and says so when a question is past the cached range or nothing is cached. Once the cached forecast has run out, it says plainly that it no longer has weather data and needs to go online for more. Source: Open-Meteo's public API by default (free for non-commercial apps without subscriptions or ads; limits per IP of 10,000 calls a day, 5,000 an hour, 600 a minute; data under CC BY 4.0, attribution in the app's credits), or a self-hosted Open-Meteo added as a source. No weather model runs on the phone. Weather alerts are online-only and the last ones are shown "as of". Decided 2026-10-24. |
| Fuel prices | Live sources, in the US EIA format only. The app has one fuel-price source built against EIA's official API (weekly retail prices by area and grade, with period and series ID; free key), and that format is Cache's fuel-price format. The source's address can be changed to any EIA-compatible endpoint, so other providers are added by a translator that serves their data in the EIA format; translators live outside the app (for example next to a Conduit server) and nothing about them is in this repo or any store build. Optional per-station prices from Google Places (New) with the user's own key, online only: shown live and never stored for offline use, because Google's terms restrict caching Places content. Prices carry their period and expire like weather; a `fuel_prices` tool cites them. Decided 2026-10-25. |
| Starter emergency catalogue | Source definitions offered in the catalogue, based on the feeds the owner's Conduit already brokers: NWS alerts, SWPC space weather, wildfires (WFIGS incidents, FIRMS hotspots), avalanche forecasts, USGS river gauges, USGS earthquakes, road conditions (511 / WZDx), TomTom traffic, satellite passes (Celestrak), utility outages (Idaho Power), Open-Meteo weather, EIA fuel prices. Users elsewhere add their own region's feeds. |
| Alerts | The alerts source refreshes while online; each alert's area is matched against the current location and saved places, and a match raises a notification (for example "Wildfire near Home: prepare to evacuate", with its time). "Ask about this alert" opens Ask with the alert attached as a numbered source; the assistant then searches the library and ZIMs (evacuation checklists, wildfire preparation, go-bag lists) and can use weather (wind) and maps (routes, shelters) to build a cited, alert-specific answer such as what to grab. New alerts arrive only while connected; offline the last alerts show with their age and expire like other dated data. Decided 2026-10-25. |
| Repeaters | Users import repeater lists they already have (for example a CHIRP CSV or a radio programming file); imported repeaters show on the map and in nearby, and a `repeaters` tool can cite them. The RepeaterBook API is not used: its terms forbid apps from working as repeater directories, maps or nearby finders, and forbid offline bundling, without written permission. Decided 2026-10-25. |
| Distribution | Android: APK sideload. iPhone: TestFlight, through the Apple Developer Program (no device IDs to register). |
| Build machine | Android and Windows: the owner's Windows desktop (Flutter, Android SDK, phone over USB). Never cortex. |
| iPhone builds | GitHub Actions macOS runners: the workflow runs `flutter build ipa`, signs with a distribution certificate and provisioning profile kept in the repo's Actions secrets, and uploads to TestFlight with an App Store Connect API key. No Mac needed: the signing request is made with openssl. The iPhone job runs only on demand (manual trigger), not on every push, because macOS runner minutes cost about 10x Linux. Decided 2026-10-24. |

## Device tiers

| Model | Q4 GGUF | Who gets it |
|---|---|---|
| E2B (recommended) | 3.4 GB | phones with 6-8 GB RAM |
| E4B | 5.3 GB | 8 GB phones (at the edge), 12 GB phones |
| Qwen3 8B | 5.0 GB | 12 GB phones, laptops |
| Gemma 4 12B | about 6.7 GB | 12-16 GB phones, Windows and Mac computers |

Test phones: Pixel 8 (8 GB, Tensor G3, weakest), iPhone 15 Pro Max (8 GB, A17 Pro). Context on 8 GB phones: 4-8k tokens. Until a phone is at hand, Android is tested on the desktop emulator (`cache_test`, Pixel 8 profile).

## Cache 1.0

Everything in this plan stays in it, but the work is ordered so a usable app reaches the family's phones first. Cache 1.0 is the line; everything else is labelled 1.x and comes after. Decided 2026-10-25. PeerTube moved into 1.0 on 2026-10-25 at the owner's request.

**In 1.0**
- Step 1: chat with the tool loop and citation check.
- Step 2: library packs.
- Step 3: Browse (ZIMs and library packs, Kiwix catalogue, import).
- Step 4: one search across ZIMs and library packs.
- Step 5: model library (Hugging Face, Cached models, tool check). The network model connector is 1.x.
- Step 6: the assistant's brain (training for tool use and citations).
- Step 7: region packs for a baseline set of regions chosen by the owner. The worldwide pack pipeline is 1.x.
- Step 8: the live source engine with weather and alerts (including the alert flow), with expiry. Fuel prices and the rest of the emergency catalogue are 1.x.
- Step 9: offline map, place search, nearby (hospital, ER, fuel, water and the rest), latitude and longitude. Land cover, land ownership, USNG/MGRS, Plus Codes, what3words and imported repeaters are 1.x.
- Step 10: road routing. Off-road routing is 1.x.
- Step 11: iPhone.
- Step 12: Videos, PeerTube part: connect to an instance (login where needed), browse and search, stream when online, offline downloads with resolution choice, offline player, and video library pack citations that open the video at the cited time. The YouTube connector is 1.x.

**1.x (after 1.0)**
- Network models (local Wi-Fi or internet), including Windows Cache as a household model server.
- Fuel prices (EIA, Google Places, translators).
- The rest of the starter emergency catalogue (earthquakes, river gauges, avalanche, space weather, wildfire hotspots, road conditions, traffic, satellite passes, outages).
- Coordinates beyond latitude and longitude: USNG/MGRS, Plus Codes, what3words.
- Imported repeater lists.
- Full navi layer parity (land cover, PAD-US, MVUM) and off-road routing.
- The worldwide region pack pipeline.
- The optional YouTube connector (step 12).
- The Windows version.

## Build order

Each step ends with something usable on a phone. Riskiest first. Updated 2026-10-24.

1. **Chat on the phone.** Flutter app with a chat screen running uncensored E2B in llama.cpp, fully offline. Proves the model on the Pixel 8 and the iPhone 15 Pro Max. Built inside the app shell from the mockups (four tabs; tabs other than Ask are placeholders). It includes the tool loop and citation check: the model calls a search tool, results come back tagged with numbered IDs, the model cites them, and the app shows only citations that match a real result (others are dropped and the answer is marked as not from your sources). Citations always open local content: each result's ID maps to its local address (ZIM article, library page, map point), and the model never writes the links. A small test-only search tool with test data proves this; nothing ships with it. The chat engine has a pluggable model backend (llama.cpp now, remote connectors later) so the tool loop and citations work the same with either. Code and builds on the owner's desktop in `C:\src\cache`.
2. **Library.** Load a library pack (one SQLite file: recon concepts without `content`, plus vectors). The on-device embedding model is chosen in this step. Answers cite book and page.
3. **Browse.** The offline browser: ZIMs and library packs open like websites. Kiwix's public catalogue (showing mini, no-pictures and full variants with sizes), added catalogues (OPDS), import from a file; start page, tabs, bookmarks, history. Web links the model writes (for example Wikipedia URLs) open the local ZIM copy when one exists, otherwise they are marked not available offline.
4. **Search.** Tantivy (Rust) index across ZIMs and library packs, one search box. Background indexing of each new ZIM on the phone; ready-made indexes for large ZIMs published with the packs.
5. **Model library.** Hugging Face search and download inside the app, with size and RAM fit. Cached models (the owner's trained models) listed at the top. Also the optional network model connector (OpenAI-compatible, local Wi-Fi or internet; mDNS discovery or IP address and port), picked here as on-device or network. Tool check for every model (on-device and network); only models that pass can be used.
6. **The assistant's brain.** Train E2B on a C.A.C.H.E. version of the AIDA course (same tool use, complete answers), quiz it, then wire its tools to the library, Kiwix and search. Then E4B, 12B, and last Qwen (needs the course converted to ChatML). Published on Hugging Face as Cached models.
7. **Region packs.** The build pipeline from public open data (see Map data sources) and publishing to Hugging Face datasets. Baseline regions chosen by the owner.
8. **Live sources.** The on-device source engine (definition files, fetch once and share, coalescing, quotas, secure key storage, validity and expiry, scheduled refresh when online, field mapping), the starter emergency catalogue, Home status cards for live data, and the assistant tools: weather (cached Open-Meteo forecasts per place, with their age), fuel_prices, alerts. Alert matching against location and saved places, notifications, and "Ask about this alert".
9. **Maps.** Offline maps from region packs at full navi parity: basemap, hillshade and terrain, land cover, land ownership, places, geocoder, nearby (MapLibre + PMTiles). Coordinates: lat/long, USNG/MGRS and Plus Codes offline; what3words online with cached words for saved places. Imported repeater lists on the map and in nearby.
10. **Routing.** Valhalla road routing on the device, then off-road (navi-offroute rewritten to run on the device, without PostGIS).
11. **iPhone.** Same app on iOS, built and sent to TestFlight by a GitHub Actions macOS workflow.
12. **Videos.** PeerTube connector (official API, login), browse and search an instance, streaming, offline downloads with resolution choice, offline player, optional YouTube connector (online only: search, play, bookmark; user's own API key with in-app setup instructions), video library pack with citations that open the video at the cited time.

## Size and compression

- Measure each layer's size per region in step 7 and choose compression per layer; show sizes per layer in the download screen.
- Terrain: LERC within about 1 m of error, 30 m resolution, fewer tiles over flat ground.
- Land cover: 30 m for off-road routing, run-length or zstd compression.
- Basemap: build to zoom 14 and overzoom beyond it; drop fields the app never shows.
- Places: only the columns the app uses, columnar with zstd.
- Valhalla: leave out transit and other unused data.
- ZIMs: offer the mini, no-pictures and full variants with their sizes.
- Library vectors: int8 or 1-bit (binary) with re-checking of the top results; fewer dimensions where the embedding model supports it.
- Library text: zstd with a dictionary trained on the concepts.
- Tantivy: no word positions on fields that never need phrase search.
- Packs can live on an SD card where the phone has one.
- Videos: download at a chosen resolution or audio only; show the size before downloading.

## Known facts from testing

- Gemma 4 E2B, E4B and both E2B uncensored variants train cleanly on the AIDA course with the box's pinned env (2026-10-21): same token ids as the 12B tokenizer, assistant-only masking correct, llama.cpp converts to Q6_K. On one H100: E2B about 2.35 h, E4B about 2.7 h for 881 steps. Prep files: `/mnt/mesh-train/export/aida-training-candidates-20261020-v25b/small-gemma-prep/`.
- Gradient offload is hard-coded in the trainer (`train_gemma_trajectory.py:465`, `use_gradient_checkpointing='unsloth'`); worth testing off on a machine with spare GPU memory.
- Trained Josiefied Qwen3 8B models exist (`mesh-8b-tuned` r1-r3), but on the older passages course, not the current tool course.
- Stock E2B on an iPhone (PocketPal, 2048 context): a well-organised answer with confident factual slips. Library grounding is the fix.
- The owner's desktop (2026-10-24): Windows 11 Pro, Ryzen 7 3700X, 64 GB RAM. Flutter 3.44.8, Android Studio 2026.2.1, Android SDK 37, NDK 28.2, CMake 3.22; `flutter doctor` clean; emulator acceleration (WHPX) works.

## To check before the step that needs it

- Whether Open WebUI's OpenAI-compatible API passes the phone's tool definitions through to the model; if not, Open WebUI does not qualify (step 5).
- Protomaps' terms for downloading regions from their planet builds (step 7).
- Overture places size per region, to keep packs a sensible size (step 7).
- Open-Meteo's terms for app-store distribution (their terms name free apps without subscriptions or ads as non-commercial but don't mention app stores), and the licence of the self-hosted Open-Meteo software (step 8).
- EIA API terms; Google Places (New) fuel price coverage, pricing and the exact caching terms (step 8).

## Open questions

- On-device embedding model for the library (step 2): the library pack format fixes one embedding model. bge-m3 matches recon's existing vectors but is large; a smaller model means re-embedding the concepts.
- Which E2B variant (huihui-ai or TrevorJS) becomes the recommended model: decided by the quiz.
- When the Windows version (and its model server for phones on the same Wi-Fi) gets its own build step.

## Proposed — not approved

- "Lighter model, longer battery" switch in settings.
- Custom-area (draw a box) map packs, after the standard region packs.
- Online mode: stream and cache map tiles and other data from public sources when there is a connection, alongside region packs.
- Voice conversations in Ask (the owner wants to look into this).
- Import your own video files from the phone or SD card, to play offline and add to a video library pack.
- "My supplies": a list of what the user has on hand, so alert checklists can say what is missing (the owner considers it scope creep for now).
- A tick-off checklist saved with an alert.
- Point family phones at the owner's Conduit for sources that need keys, so the keys stay on the server and quotas are shared.
