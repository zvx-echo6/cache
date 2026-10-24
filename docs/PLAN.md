# C.A.C.H.E. — Crisis Assistant for Contingencies, Hardship & Emergencies

An offline survival and preparedness assistant for phones and computers. Everything runs on the device with no network: a local LLM (AIDA's brain), the recon library, Kiwix, and navi maps and routing.

- **Repo:** github.com/zvx-echo6/cache (private)
- **Board:** GitHub project "C.A.C.H.E." (owner zvx-echo6). Status lives on the board.
- **Audience:** the owner, family and close friends. Not a public store release for now.
- **Decided 2026-10-20 to 2026-10-24.**

## Decisions

| Area | Decision |
|---|---|
| Name | C.A.C.H.E. — Crisis Assistant for Contingencies, Hardship & Emergencies. Called "Cache". |
| Platforms | Android and iPhone first; Windows later. |
| Framework | Flutter, with native C/C++ libraries called through FFI. |
| LLM runtime | llama.cpp (GGUF) for every model. LiteRT-LM may be added later for the E models only, if memory needs it. |
| Default model | Gemma 4 E2B, uncensored (huihui-ai or TrevorJS; choose by quiz). |
| Optional models | Gemma 4 E4B (TrevorJS), Qwen3 8B (Josiefied), Gemma 4 12B (AIDA). Downloadable; the app recommends the largest that fits the device's RAM, and the user can pick any that fits. |
| Answer style | Complete answers are fine. Cache is not the mesh, so the 300-byte mesh limit does not apply. |
| Library | Recon concepts without the verbatim `content` field: title, summary, key facts, keywords, book title and page. Answers cite book and page. No PDFs or copied book text ship. |
| Kiwix | ZIM files used as they are, through libzim / libkiwix. |
| Maps (navi) | Downloadable region packs, anywhere in the world: basemap (Protomaps PMTiles), DEM (cut from the planet DEM), Valhalla road tiles, OSM geocoder in SQLite, WorldCover land cover. PAD-US and MVUM land ownership exist for the US only. |
| Distribution | Android: APK sideload. iPhone: TestFlight, through the Apple Developer Program (no device IDs to register). |
| Build machine | Android and Windows: the owner's Windows desktop (Flutter, Android SDK, phone over USB). Never cortex. |
| iPhone builds | GitHub Actions macOS runners: the workflow runs `flutter build ipa`, signs with a distribution certificate and provisioning profile kept in the repo's Actions secrets, and uploads to TestFlight with an App Store Connect API key. No Mac needed: the signing request is made with openssl. The iPhone job runs only on demand (manual trigger), not on every push, because macOS runner minutes cost about 10x Linux. Decided 2026-10-24. |

## Device tiers

| Model | Q4 GGUF | Who gets it |
|---|---|---|
| E2B (default) | 3.4 GB | phones with 6-8 GB RAM |
| E4B | 5.3 GB | 8 GB phones (at the edge), 12 GB phones |
| Qwen3 8B | 5.0 GB | 12 GB phones, laptops |
| Gemma 4 12B | about 6.7 GB | 12-16 GB phones, Windows and Mac computers |

Test phones: Pixel 8 (8 GB, Tensor G3, weakest), iPhone 15 Pro Max (8 GB, A17 Pro). Context on 8 GB phones: 4-8k tokens.

## Build order

Each step ends with something usable on a phone. Riskiest first.

1. **Chat on the phone.** Flutter app with a chat screen running uncensored E2B in llama.cpp, fully offline. Proves the model on the Pixel 8 and the iPhone 15 Pro Max.
2. **Library search.** Recon concepts (no `content`) exported to one SQLite file with full-text search and vectors. On-device embedding model chosen in this step. Answers cite book and page.
3. **Kiwix.** ZIM reading and search inside the app.
4. **AIDA's brain.** Train E2B on a C.A.C.H.E. version of the AIDA course (same tool use, complete answers), quiz it, then wire its tools to the library and Kiwix. Then E4B, 12B, and last Qwen (needs the course converted to ChatML).
5. **Maps.** Offline basemap and elevation for a downloaded region (MapLibre + PMTiles).
6. **Routing.** Valhalla road routing on the device, then off-road (navi-offroute rewritten for the device).
7. **Pack server.** Catalog and downloads for regions, library, Kiwix and models. New infrastructure; needs the owner's approval.
8. **iPhone.** Same app on iOS, built and sent to TestFlight by a GitHub Actions macOS workflow.

## Known facts from testing

- Gemma 4 E2B, E4B and both E2B uncensored variants train cleanly on the AIDA course with the box's pinned env (2026-10-21): same token ids as the 12B tokenizer, assistant-only masking correct, llama.cpp converts to Q6_K. On one H100: E2B about 2.35 h, E4B about 2.7 h for 881 steps. Prep files: `/mnt/mesh-train/export/aida-training-candidates-20261020-v25b/small-gemma-prep/`.
- Gradient offload is hard-coded in the trainer (`train_gemma_trajectory.py:465`, `use_gradient_checkpointing='unsloth'`); worth testing off on a machine with spare GPU memory.
- Trained Josiefied Qwen3 8B models exist (`mesh-8b-tuned` r1-r3), but on the older passages course, not the current tool course.
- Stock E2B on an iPhone (PocketPal, 2048 context): a well-organised answer with confident factual slips. Library grounding is the fix.

## Open questions

- On-device embedding model for library search (step 2): bge-m3 matches the existing vectors but is large; a smaller model means re-embedding the concepts.
- Which E2B variant (huihui-ai or TrevorJS) becomes the default: decided by the quiz.

## Proposed — not approved

- "Lighter model, longer battery" switch in settings.
- Custom-area (draw a box) map packs, after the standard region packs.
