# L4 slice 5: settings between devices, headless on the server (design)

Branch `ask-linux-l4-s5`, off slice 4 (e6a278ac). Written 2026-11-15 from a read-only look at the code (facts with file:line in the
cache-linux-build results file, batch 5). Builds on `l4-sync-design.md` section 3 and the owner's decisions of 2026-11-09:
settings sync on the server runs headless; changes from linked devices apply with no browser tab open; a change made in any
browser tab is sent; open tabs reload a setting when the host applies one; keys sync like on a phone.

## What the code is today

- **Where the settings live on the server.** All 17 synced settings (`appSyncedSettings`, `app/lib/sharing/synced_settings.dart`)
  are saved by the web build through AppFs (`fs.write` over `/api/core`), in five places under `<support>`:
  - `settings.json`: theme, module icons, dark PDF pages, `lastModel` (Ask model);
  - `layout.json`: Home bar, Home blocks, shortcuts;
  - `preferences.json`: weather sources on, watched here, regions and places, source links, alert pop-ups, quiet hours, web
    search on;
  - `maps.json`: layers on (this file also holds the camera, opacity and definitions, which never sync);
  - `live-catalogues/<id>/`: the person's own weather sources.
- **Nothing on the server reads those files.** Only a tab reads them, once, at start (each state class's `init`).
- **`SettingsSync` is Flutter-bound.** `settings_sync.dart` imports `flutter/foundation` and `sharing_state.dart`, uses `dart:io`
  for its log (`<settings-sync>/log/<device>.jsonl`, append-only) and its state (`.local/state.json`), and finds changes through
  each setting's `Listenable`. It does not start on web (`main.dart:1217`).
- **Keys.** On web, keys are in the server keystore (`<data>/keystore.json`), and tabs see only `keystore://` references. The
  host has `setSecrets` and `takeSecrets`, but nothing calls them.

## Design

### 1. One Flutter-free settings log, used by the phone and the server

Split `settings_sync.dart` in two, with no behaviour change on the phone:
- `settings_log.dart` (no Flutter, no `sharing_state.dart`): the log events, their lines, append, reading a peer's log from
  `seen`, `.local/state.json`, which links send and receive each key, and the newest-wins rule. Its file access goes through a small
  interface, so the phone keeps `dart:io` and the tests can fake it.
- `settings_sync.dart` keeps the phone's part: the `Listenable` watching, the 10 s pull timer, the "Sync Cache settings with ...?"
  question and the keys, now calling `settings_log.dart`.
- The phone's existing `settings_sync_test.dart` is the guard that nothing changed.

### 2. The server's settings, read and written by key, with no Flutter

`settings_files.dart` (Flutter-free, in `app/lib/sharing/`, as `indexes_fetch.dart` is): for each of the 17 keys, which file and
JSON field holds it, and how to turn the file's form into the log's value and back. The log's value must be exactly what the
phone's `read()` gives (for example, `home.blocks` is `layout.blocksJson`, not the file's `blocks` and `off`), so phones and the
server read each other's lines.
- Writes change only that field and keep everything else in the file (`maps.json` keeps the camera and opacity), written to a
  temp file and renamed, as `fs.write` does.
- Proof: an app test that, for every key, sets the value through the real state class with files in a temp folder and checks
  `settings_files.dart` reads the same value, and the other way: writes with `settings_files.dart`, opens the state class from
  the files, and checks `read()`. A key added to `appSyncedSettings` with no entry here fails the test.

### 3. The host runs the log (headless)

In the helper, `ServerSettingsSync` runs `settings_log.dart` over `<support>/settings-sync` with `settings_files.dart` as its
settings, the host as the one writer of the server's own log, and the server's device id as its name.
- **Incoming:** on the settings share's change (`onShareChanged` with `settings`) and on a timer, it reads the peers' logs and
  applies what is newer through `settings_files.dart`. This runs with no tab open.
- **Outgoing (a tab's change):** a tab saves a setting with `fs.write` to one of the five places. `FsOps` tells the host which
  file changed; the host compares the keys of that file with what it last logged and appends the changed ones. A change made
  while sharing is off is noted, not sent (the phone's rule).
- **The question and Match, Send mine, Off:** as on a phone; the browser's pages call the host through `sharing.*`, as slice 2
  does for links.

### 4. Open tabs reload

When the host applies an incoming setting, it bumps a `settings` counter in `sharing.state`, which tabs already poll every 2 s.
A tab that sees it move re-reads the changed file into its state class. Each of `AppState`, `LayoutState`, `AppSettings`,
`MapsState` and the own weather sources gets a `reload()` that reads its file again and notifies listeners without saving.

Known gap: a tab that saves a whole file in the 2 s before it reloads can write back the old value. The host sees that as a
tab's change and logs it, so it is visible, not silent. Narrowing it (the tab reloads before it saves) is in the tests.

### 5. Keys (owner: keys sync like on a phone)

The host gets the `KeyStore`. For the keys a link sends (the phone's `appSyncedKeys` names: `search.kagi.key`,
`live.key.<alias>`), it calls `setSecrets` with the values from the keystore, and it calls `takeSecrets` and writes arrivals
straight into the keystore. Key values never reach a tab.

### 6. Decisions for the owner

1. **Weather with no tab open.** The server's weather timer reads only `live_plan.json`, which a tab builds from the settings
   (sources on, watched places and their requests, own sources). So a weather change that arrives with no tab open is saved
   at once, but the server fetches by the new list only after a tab next opens.
   - (a) Accept that for now (S).
   - (b) Port the plan building to the helper (L).
   - Recommendation: (a), and record the gap.
2. **Ask model with no tab open.** An arriving `ask.model` sets `lastModel`. The server loads it when Ask is next used, as a tab
   does today; nothing loads a model at arrival. Recommendation: accept.

## Order of work (each step tests first)

1. Split out `settings_log.dart`. The phone's tests must stay green; no new behaviour.
2. `settings_files.dart` and its parity test, for all 17 keys.
3. The host's `ServerSettingsSync`: incoming applies, outgoing from `FsOps`, and a loopback test with two real engines (a phone-like
   engine and the host: a line in, applied to the file; a file change, a line out).
4. Tabs reload (`settings` counter, the `reload()` methods), with widget tests.
5. Keys through the host and the keystore.
6. The browser's pages (the question, Match, Send mine, Off), then the two-device check with an emulator.
