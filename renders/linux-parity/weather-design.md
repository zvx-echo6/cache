# Weather and alerts on Linux (item `weather`, audit MISSING 4)

Goal: everything the phone does for weather and alerts works in the browser, and the data stays fresh with no tab open.

## Why it did not start
`weather.start()` built `Directory('<support>/live-catalogues')` from path_provider and threw in a browser; `liveDir` was null (no
`openedExtra` on web); the told list and place rules were `dart:io` files. `_soft` skipped the part, so nothing worked.

## Design
1. **Files (browser).** New `weather/weather_files.dart`: `WeatherFiles` (sync read/write/delete/rename/folders over a relative
   path). `IoFiles` = the exact dart:io calls the phone made. `AppFsFiles` = folder held in memory from one read at start, every change
   queued in order to AppFs (`fs.*`). `CatalogueStore`, `LiveFolder` and WeatherState's three small files (saved places, last shown,
   status) now go through it; their old `Directory` constructors build `IoFiles`, so the phone path and every test is unchanged.
   `WeatherState` takes `catalogueFiles`/`liveFiles` (web) beside `catalogueDir`/`liveDir` (phone).
   - catalogues: support root `live-catalogues/`. Core source folder: docs root `live-defs/` (the server opens its core with
     `<docs>/live-defs`, `server/helper/test/fs_ops_test.dart:191`), so "liveDir from the server" is that folder through AppFs.
   - told list and place rules: `ToldStore.appFs`, `PlaceAlerts.appFs` (support root, same file names as the phone).
2. **Server timer.** `server/helper/bin/live_timer.dart` (`LiveTimer`), started from the helper's main (3 lines): first run 2 min after
   start, then every 30 min (the phone's `kBackgroundEvery`). It reads `live_plan.json`, calls `liveSources`, sets the fetch policy,
   starts one `liveFetchStart` job per source and place (the helper stays responsive), polls `jobProgress`, then writes
   `live-catalogues/status.json` (same fields as WeatherState) so the Weather line shows the run.
3. **The plan.** The browser's WeatherState writes `live_plan.json` (`onPlan`, `publishPlan`) when sources on, keys or watched places
   change: `{sources:[{id,title,alerts}], places:[{id,name,request}]}` with the exact `placeRequest` the core takes. This is the
   headless equivalent of `LastPlace` plus the settings a background run reads.
4. **Alerts.** While a tab is open: browser notifications (`weather/browser_notification_web.dart`, package:web Notification),
   used by `LocalAlertNotifier.show` on web (silent in quiet hours, extreme stays until dismissed, click focuses the tab and opens
   the alert like a phone tap). Permission is asked the first time something is switched on (as the phone). `watchWhileOpen`
   (web only, every 5 min) runs `updateIfDue` or else `checkAlerts`, so alerts the server fetched with no tab open pop up once
   (told list is shared on the server). Server-side record: the timer appends alerts and fires in force near each place to
   `alerts_inbox.json` (once each; newest 200). Pop-up rules stay the browser's.
5. **Own source import.** `pickTextFile` read `picked.path` (null on web); on web it reads the chosen file from the browser handle.
6. **Ask about this, Discover live items, setup card, notification settings** need nothing of their own: they run on WeatherState.

## Left / needs owner
- Keys for sources that need one are saved in the browser (secure storage) and pushed to the core's memory; after a helper restart
  the timer cannot fetch keyed sources until a tab pushes them again. Needs the server-side keystore (other item).
- "Where I am" has a position only after a tab gave one; the plan keeps the last. Choose a place (regions) is the regions item.
- The inbox has no screen: pop-ups come from the told list; the file is a record.

## Slices
1 files seam + web start; 2 notifier + browser permission + watch; 3 plan + helper timer + tests; 4 own-source import.
