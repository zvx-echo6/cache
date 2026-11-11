# Link version gate: every string a person can see

"Approved" = in the link-version renders reviewed earlier. "NEW" = added since; frames for each are in this folder (390, light, dark, Tactical).

| Where | String | Status | Frame |
|---|---|---|---|
| Linked devices row, they are older | warning icon, "Version mismatch: <name> needs to update Cache · 1.0 or earlier · this device 1.1.0" (the version reads "1.0 or earlier" when the device sends none) | approved | 1-list-* |
| Row, we are older | warning icon, "Version mismatch: update Cache on this device to sync with <name> · 1.2.0 · this device 1.1.0" | approved | 1-list-* |
| Row, not heard from yet | "Checking…" (the existing string) | existing | - |
| Row, matching | "Connected directly · Last seen 2 min ago" (existing) | existing | 1-list-* |
| Device page card, line 1 | same as the row | approved | 2-, 3-device-* |
| Device page card, line 2 (they are older) | "Nothing syncs with <name> until <name> is updated. The link stays, and syncing starts again by itself once both devices run matching versions." | approved | 2-device-* |
| Device page card, line 2 (we are older) | "Nothing syncs with <name> until this device is updated. The link stays, ..." | approved | 3-device-* |
| Buttons | "Check again"; "Checking…" while it asks; "Sync now" greyed | approved | 2-, 3-, 4-device-* |
| Device page, settings section | hidden while mismatched (no string) | approved | 2-, 3- |
| After Check again, matching | toast "Versions match. Syncing with <name> starts again." | NEW | 8-toast-match-* |
| After Check again, still different | toast "Still a different version." | NEW | 7-toast-still-different-* |
| After Check again, not reached | toast "Could not reach <name>." | NEW | 5-toast-not-reached-* |
| After Check again, network not allowed | toast "Sync is paused: no network it may use." (the engine's existing paused text) | NEW (reused text) | 6-toast-network-off-* |
| Check again while one is already running | no toast (the button already says "Checking…") | - | 4-device-checking-* |
| Kind page "Sync all" and each item's sync button | greyed when every linked device is on a version that cannot sync; no new string, no frame | NEW state | - |

# Answers from code

**(a) Build 49 (tag build-1.1.0-49), no sync version.** Same path as 1.0.30. Its `fetch_index` sends the bare `index` request; the current build treats a request with no version as incompatible and closes the connection with an error, so build 49's read fails ("read error: connection lost") and it sets `st.error`, skips that device, applies nothing and deletes nothing. Its peer row (`peerStatus`, sharing_page.dart) reads exactly: "Not reachable" (warning tone) followed by " · Last seen <ago>", or " · Never connected since linking" if it never answered. The ago is the last time it did reach us, from before we updated. Build 49 never shows the error text.

**(b) Linux.** The same constants (`SYNC_PROTO`, `SYNC_MIN_PROTO`) live once in cache_sync's lib.rs, and every build of the core uses them, so there is no Linux-side number to set. The server crate (`server/Cargo.toml:27`) uses cache_sync only for `identity::load_or_create`; no code under `server/src` opens a `SyncEngine` or calls `cs_sync_open`, so the server takes no part in the exchange and has no `app_version`. The only callers that open the engine are the Flutter app (`sync_core_io.dart` through `cs_sync_open`; `sharing_state.dart` passes `kAppVersion`) and the `cache-sync` terminal binary, which takes `--app-version` and otherwise reports the crate's own version (0.1.0). The desktop (Linux) app gets the same numbers from the same core and needs no change; a Linux `cache-sync` run by hand should be given `--app-version` for a sensible version label.
