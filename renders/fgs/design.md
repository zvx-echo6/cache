# Adding PDFs in the background with a foreground service: design

Branch `design/fgs-background-add` (off `rel-1.1`). Renders and design only: no service code, manifest or Dart changed. For the
build after 51. Nothing here ships until the owner approves the renders and the open decisions at the end.

Renders (390 wide, light and dark, Android 15 shade look): `1-adding`, `2-ended`, `3-paused`, `4-lock-screen`. Wording and which
strings are new: `wording.md`. The cards are drawn by a test (`app/test_shots/fgs_notification_renders_test.dart`), not on a
device: spacing, corner size and tints follow Android 15's Material You shade as closely as a mock-up can, and a device will
differ a little with its wallpaper colours.

## The problem, as measured

The background Add PDF run is about 10 times slower than in front: a 6-page PDF took 56 s at the front and 9 min in the
background (the background cpuset keeps the process on the little cores; proven). After Back, Android's cached-app freezer
freezes the process, so pending adds stop altogether. The approved answer: while a background add runs, the app runs a foreground
service with a notification. A foreground process is not put in the background cpuset and is not frozen.

## Which service type: `dataSync`

| Type | Limit | Needs | Fit |
|---|---|---|---|
| `dataSync` | none before Android 15; on 15, 6 hours in any 24, then `Service.onTimeout` | `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` | The documented use list includes local file processing, import and export. Adding a PDF reads a file and builds the library entry and its index parts. Chosen. |
| `shortService` | about 3 minutes, then `onTimeout` | `FOREGROUND_SERVICE` only | A 6-page PDF takes 56 s at best; a book is many minutes. Too short, and meant for work that must finish at once. Rejected. |
| `specialUse` | none | `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE`, a `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` text in the manifest, and a free-text justification that Play reviews by hand | For work no listed type covers. dataSync covers this, so using it would invite a review for nothing. Rejected; the fallback if Play refuses dataSync. |
| `mediaProcessing` (new in 15) | 6 hours in 24 | its own permission | Transcoding audio and video. A PDF is not media. Rejected. |

What changes on Android 14 and 15, and what the app needs:

- Android 14 (API 34): every foreground service must name its type in the manifest, and must hold that type's permission, or
  starting it fails. Cache targets a recent SDK, so both are needed.
- Manifest, new: `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>`, and a `<service>` for the
  add (`android:foregroundServiceType="dataSync"`, `android:exported="false"`). Already there: `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_LOCATION` (guidance, run by geolocator, a separate service), `POST_NOTIFICATIONS`, `WAKE_LOCK`.
- Android 13 and later: `POST_NOTIFICATIONS` is a runtime permission. It is already declared and already asked for weather
  alerts. If refused, the service still runs, but its notification is not shown in the shade; the person can still see and stop
  it in Android's "Active apps" list. The first-run question is in `wording.md`.
- Android 14 also lets the person swipe an ongoing foreground-service notification away; the service keeps running.
- Android 15: the dataSync limit of 6 hours in a rolling 24 hours, counted over all of the app's dataSync services together;
  when it is reached the system calls `onTimeout(startId, fgsType)` and the service has a few seconds to stop itself, or the app
  gets an error. The count is reset when the person brings the app to the front. After the limit, a new dataSync service cannot
  be started until then.
- Starting: since Android 12 an app cannot start a foreground service from the background, except for listed cases (it is in
  front or has just been; a tap on a notification or on one of its actions). Hence "when it starts" below.
- Play Console: "Foreground service permissions" under App content. For dataSync: what the service does for the person, that it
  is started by them, what happens if it is delayed or stopped (adding is paused and carries on later; nothing is lost), and a
  short screen recording of the notification. Needed with the first release that targets Android 14 or later and has the
  permission. (Confirm the form's exact wording when submitting; the questions change.)

## When it starts, and when it stops

- It cannot be started once the app is in the background, so it is started while the app is still in front: when the person
  leaves with adds pending (Home, recents, or Back at the root; `onUserLeaveHint` and the root Back handler), not when an add is
  begun. With Cache in front, adding runs at full speed and needs no notification.
  To be tested on devices at Android 12, 13, 14 and 15: Back from the root, Home, the app switcher, a call arriving.
- A notification action (Resume, Resume anyway) starts the service again; that is one of the allowed cases.
- It stops when nothing is left to add, when every PDF is paused or held (the notification is then detached with
  `stopForeground(DETACH)` and stays as an ordinary one the person can swipe away), at the time limit, or when Cache comes to
  the front (the app asks the run to stop through the existing lock; adding carries on in front at full speed).
- The notification is updated at most once a second (Android also limits update rates, and each one wakes the system UI).

## What happens at the time limit (Android 15)

1. `onTimeout` is called. The service asks the add to pause the way Pause does (the core keeps what is done; a PDF step already
   running cannot be cut short, and the job folder resumes it later: this is what the existing slice stop and the background
   hand-off already rely on), calls `stopSelf()` at once, and detaches the notification as "Paused · 2 of 5 PDFs · Android limits
   background work. It carries on while charging, or open Cache."
2. The charging run (below) is queued so the rest is added the next time the phone charges.
3. The person opening Cache resets the count, and adding carries on in front.
Six hours is far more than a normal add: a 6-page PDF is 1 to 2 minutes at foreground speed (to be measured). The limit matters
only for a very large batch.

## How it fits with what exists

- The WorkManager background run (`watch-folder-add`, slices of about 8 minutes, only while charging and not on a low battery)
  stays. It is the unattended path: the watched folders' check finds new PDFs with the app closed, and a worker cannot start a
  foreground service from the background (Android 12 and later), so that path cannot use the service and keeps its limits. The
  service covers only what the person started and then left.
- One lock, as now: the service holds `run-pdf-add` (refreshed every 30 s) so the charging run never runs at the same time,
  and Cache coming to the front asks it to stop with `stop-pdf-add` as it asks a background run today.
- The hand-off: `backgroundHandOff` still saves, lets go of the lock and queues the charging run when the watched folders have
  PDFs left. With the service, the add jobs continue in it first; when it ends, whatever is left (a pause, the time limit, a
  battery hold) falls to the charging run. The service has no 8-minute slice: it runs the same `AddPdfSlice` with a long budget,
  and keeps its checks (heat, battery, the app coming to the front).
- Battery and heat rules are the app's own, unchanged. Long PDFs that wait for charging do not start the service: nothing is
  running, so there is nothing to show (the in-app card keeps "Waits for charging (long job)" and Start now). The person's
  Start now, Resume anyway or Resume starts it.
- Needs on top: a partial wake lock while it runs (`WAKE_LOCK` is already declared). A foreground service keeps the process
  alive and at foreground priority but does not keep the CPU awake with the screen off; without the lock the add stalls.
- A small Kotlin service starts the same Dart entry point WorkManager's dispatcher uses, so there is one add code path. (A plugin
  would add a package; none is proposed without the owner's say.)

## Battery cost, against the slow path

Measured: 56 s at the front and 9 min in the background for a 6-page PDF, about 9.6 times longer. Not measured: the energy of
either. By reasoning only: the little cores draw less power than the big ones but for about 10 times as long, with the process
and (to run at all) a wake lock held for the whole time, so the slow path is not a cheaper one; it is the same work spread out.
And after Back it does not finish, because the process is frozen. The service finishes the same batch in roughly the front's
time, at a higher power for a short while. Expected: about the same or less energy than the slow path, and the work is done.
The build should measure it: the same 5 PDFs, screen off, unplugged, front speed vs the service vs the slow path, battery use
from `dumpsys batterystats` and the phone's own battery page, on one device at a fixed charge, before this is called cheap. Until
then the claim stands as an estimate.
The rules that protect the battery stay: nothing starts under the low-battery threshold, heat slows or pauses it, and the person
can pause from the notification.

## Open decisions for the owner

1. Start point: when the person leaves with adds pending (recommended), or whenever an add is begun (simpler, but a notification
   shows while Cache is in front).
2. Unplugged: the service runs on battery above the low-battery threshold because the person asked for the add (recommended; the
   charging run stays charging-only). Or it too waits for charging, which makes it much less useful.
3. Two channels, both silent (recommended), or the failed one at default importance (heads-up).
4. Lock screen shows no names (recommended; the private versions are in `4-lock-screen`).
5. If Play refuses dataSync: specialUse with a subtype text, a second review.

## Not decided here, to be checked on devices

Starting when leaving at each Android version; OEM battery managers that kill a foreground service anyway; the actual speed in
the service (the cpuset it lands in); the energy figures above.
