# C.A.C.H.E. — Crisis Assistant for Contingencies, Hardship & Emergencies

An offline survival and preparedness assistant for phones and computers. Everything runs on the device with no network: a local LLM, a library, Kiwix, maps and routing.

Cache is a framework. No data and no models ship inside the app: people add the sources they want (models, ZIMs, library packs, region packs). The app must never depend on hosting run by the owner, so it can go to the app stores later.

- **Repo:** github.com/zvx-echo6/cache (private)
- **Board:** GitHub project "C.A.C.H.E." (owner zvx-echo6). Status lives on the board.
- **Audience:** the owner, family and close friends first; the app stores possibly later.
- **Decided 2026-10-20 to 2026-10-24.**

## Decisions

| Area | Decision |
|---|---|
| Name | C.A.C.H.E. — Crisis Assistant for Contingencies, Hardship & Emergencies. Called "Cache". |
| Assistant name | Not decided yet. The assistant is not called AIDA in Cache. |
| App layout | Four tabs: Home, Ask, Browse, Maps. Home: an Ask box, quick actions (Hospital, First aid, Water, Navigate) and small status cards (model, reading, maps, search). Ask: ChatGPT-style chat, sources collapsed into one pill. Browse: the offline browser. Maps: full-screen map with one search bar; nearby and routing appear after a search or a tap. Models and Downloads open from Home. Dark theme, calm screens, one main thing per screen. Decided 2026-10-24 from mockups. |
| Platforms | Android and iPhone first; Windows later. |
| Framework | Flutter, with native C/C++ libraries called through FFI (and Rust through flutter_rust_bridge for Tantivy). |
| App is a framework | No data or models are bundled. Every source is added by the user or picked from a public catalogue. Nothing depends on owner-run hosting. Decided 2026-10-24. |
| LLM runtime | llama.cpp (GGUF) for every model. LiteRT-LM may be added later for the E models only, if memory needs it. |
| Models | Downloaded in the app from Hugging Face: search the whole catalogue, with each model's size and whether it fits the device. The owner's trained models ("Cached models") are published on Hugging Face under a neutral account and listed at the top of the Hugging Face section. |
| Recommended model | Gemma 4 E2B, uncensored (huihui-ai or TrevorJS; choose by quiz). Optional: Gemma 4 E4B (TrevorJS), Qwen3 8B (Josiefied), Gemma 4 12B (AIDA). The app recommends the largest that fits the device's RAM; the user can pick any that fits. |
| Answer style | Complete answers are fine. Cache is not the mesh, so the 300-byte mesh limit does not apply. |
| Library | User-loaded library packs. The pack format follows recon concepts without the verbatim `content` field: title, summary, key facts, keywords, book title and page. Answers cite book and page. The app ships no library; the owner's recon library is loaded privately like any other pack. The owner's recon library pack excludes the PeerTube (video) concepts. The recon code is to be published on GitHub so people can build their own library packs; this is a to-do before any public release and needs the owner's go. |
| Browse (Kiwix) | An offline browser: ZIMs and library packs open like websites, with a start page of sites, an address bar, tabs, back and forward, bookmarks, history and one search. ZIMs come from Kiwix's public catalogue, from any other catalogue in Kiwix's catalogue (OPDS) format added as a source (for example the owner's recon ZIMs, privately), or imported from a file on the device or SD card. ZIMs are used as they are, through libzim / libkiwix. |
| Search | One search box across all ZIMs and library packs, with Tantivy-quality full-text indexing. The phone indexes each newly added ZIM itself, slowly and in the background. Ready-made indexes for large, popular ZIMs are published with the region packs. Keyword search (Tantivy) and meaning search (vectors in the library packs) run together and merge into one ranked list; the assistant uses the same search. |
| Maps | Full parity with navi's layers, places and features: basemap, hillshade and terrain, land cover, land ownership (US: PAD-US, MVUM), places and geocoder, nearby (hospital, ER, fuel, trailhead and the rest), road and off-road routing. Delivered as downloadable region packs. |
| Region packs | Built by the owner from public open data and published to free hosting (Hugging Face datasets; GitHub Releases caps files at 2 GB). The owner builds and maintains a baseline set; nothing is served from owner-run hosting. State- and country-sized regions build on GitHub Actions; continent-sized ones (about 14 GB disk and 6 h limits on free runners) build on the owner's machines and are only uploaded. OSM data needs ODbL attribution in the app's credits. |
| Map data sources | Basemap: Protomaps planet builds (PMTiles). Terrain: Copernicus DEM (AWS Open Data). Land cover: ESA WorldCover (AWS Open Data). Places: Overture Maps (AWS/Azure Open Data). Roads, routing and geocoder: OSM regional extracts (Geofabrik). US land ownership: PAD-US (USGS), MVUM (Forest Service). No public host offers ready-made Valhalla tiles, so the packs carry them. |
| Coordinates | Offline, for any point (with copy) and accepted in map search: latitude/longitude (decimal and degrees-minutes-seconds), USNG/MGRS, and Plus Codes (Open Location Code). what3words through its official API (Flutter package `what3words`) when online: words for a point, words accepted in search with autosuggest; words for saved places are cached for offline. The what3words offline SDK is a paid licence and is not planned. The API key is never committed to the repo. Decided 2026-10-24. |
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

## Build order

Each step ends with something usable on a phone. Riskiest first. Updated 2026-10-24.

1. **Chat on the phone.** Flutter app with a chat screen running uncensored E2B in llama.cpp, fully offline. Proves the model on the Pixel 8 and the iPhone 15 Pro Max. Built inside the app shell from the mockups (four tabs; tabs other than Ask are placeholders). Code and builds on the owner's desktop in `C:\src\cache`.
2. **Library.** Load a library pack (one SQLite file: recon concepts without `content`, plus vectors). The on-device embedding model is chosen in this step. Answers cite book and page.
3. **Browse.** The offline browser: ZIMs and library packs open like websites. Kiwix's public catalogue (showing mini, no-pictures and full variants with sizes), added catalogues (OPDS), import from a file; start page, tabs, bookmarks, history.
4. **Search.** Tantivy (Rust) index across ZIMs and library packs, one search box. Background indexing of each new ZIM on the phone; ready-made indexes for large ZIMs published with the packs.
5. **Model library.** Hugging Face search and download inside the app, with size and RAM fit. Cached models (the owner's trained models) listed at the top.
6. **The assistant's brain.** Train E2B on a C.A.C.H.E. version of the AIDA course (same tool use, complete answers), quiz it, then wire its tools to the library, Kiwix and search. Then E4B, 12B, and last Qwen (needs the course converted to ChatML). Published on Hugging Face as Cached models.
7. **Region packs.** The build pipeline from public open data (see Map data sources) and publishing to Hugging Face datasets. Baseline regions chosen by the owner.
8. **Maps.** Offline maps from region packs at full navi parity: basemap, hillshade and terrain, land cover, land ownership, places, geocoder, nearby (MapLibre + PMTiles). Coordinates: lat/long, USNG/MGRS and Plus Codes offline; what3words online with cached words for saved places.
9. **Routing.** Valhalla road routing on the device, then off-road (navi-offroute rewritten to run on the device, without PostGIS).
10. **iPhone.** Same app on iOS, built and sent to TestFlight by a GitHub Actions macOS workflow.

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

## Known facts from testing

- Gemma 4 E2B, E4B and both E2B uncensored variants train cleanly on the AIDA course with the box's pinned env (2026-10-21): same token ids as the 12B tokenizer, assistant-only masking correct, llama.cpp converts to Q6_K. On one H100: E2B about 2.35 h, E4B about 2.7 h for 881 steps. Prep files: `/mnt/mesh-train/export/aida-training-candidates-20261020-v25b/small-gemma-prep/`.
- Gradient offload is hard-coded in the trainer (`train_gemma_trajectory.py:465`, `use_gradient_checkpointing='unsloth'`); worth testing off on a machine with spare GPU memory.
- Trained Josiefied Qwen3 8B models exist (`mesh-8b-tuned` r1-r3), but on the older passages course, not the current tool course.
- Stock E2B on an iPhone (PocketPal, 2048 context): a well-organised answer with confident factual slips. Library grounding is the fix.
- The owner's desktop (2026-10-24): Windows 11 Pro, Ryzen 7 3700X, 64 GB RAM. Flutter 3.44.8, Android Studio 2026.2.1, Android SDK 37, NDK 28.2, CMake 3.22; `flutter doctor` clean; emulator acceleration (WHPX) works.

## To check before the step that needs it

- Protomaps' terms for downloading regions from their planet builds (step 7).
- Overture places size per region, to keep packs a sensible size (step 7).

## Open questions

- On-device embedding model for the library (step 2): the library pack format fixes one embedding model. bge-m3 matches recon's existing vectors but is large; a smaller model means re-embedding the concepts.
- Which E2B variant (huihui-ai or TrevorJS) becomes the recommended model: decided by the quiz.

## Proposed — not approved

- "Lighter model, longer battery" switch in settings.
- Custom-area (draw a box) map packs, after the standard region packs.
- Online mode: stream and cache map tiles and other data from public sources when there is a connection, alongside region packs.
- Voice conversations in Ask (the owner wants to look into this).
- Offline video saving (the owner's idea, not decided; the PeerTube concepts could come back with it).
