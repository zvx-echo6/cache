# Wording: the foreground-service add notifications

Cache's voice: plain, short, middle dots between parts, no exclamation marks. Existing strings are reused as they stand (source
in the last column); NEW means not in the app today. File names are the person's own; the lock screen never shows them.

## Channels (Android's "Notifications" settings page lists these)

| Where | Words | Status |
|---|---|---|
| Channel, while adding (low importance, silent) | Adding PDFs | NEW |
| Channel description | Shown while Cache adds PDFs in the background | NEW |
| Channel, results (low importance, silent) | PDFs added | NEW |
| Channel description | Where adding PDFs ended, paused or failed | NEW |

## While adding (the ongoing notification; header line "Cache · 12 min left · now")

| Part | Words | Status |
|---|---|---|
| Title, several PDFs | Adding PDFs to My books | NEW (plural of "Adding a PDF", library name as in "Added to My books") |
| Title, one PDF | Adding a PDF | existing (Add PDF page title) |
| Text | 2 of 5 PDFs · Radio field manual | NEW pattern ("N of M" as `indexOf`, file name as the Add PDF card) |
| Text, one PDF | Radio field manual | existing pattern (the card's title line) |
| Header, what is left | 12 min left | existing (`aboutMinutes(...) left`, Add PDF card) |
| Opened out, second line | Garden notes and 2 more waiting | NEW |
| Action | Pause | existing (Add PDF card) |
| Bar | determinate: (PDFs done + the current one's share) / PDFs; indeterminate until the first estimate | NEW behaviour |
| Tap | opens Adding a PDF (the progress page) | existing page |

## Ended

| Part | Words | Status |
|---|---|---|
| Added, title | Added 5 PDFs to My books | NEW (plural; one PDF: "Added to My books", existing) |
| Added, text, index still going | Adding to search index | existing (`Added to {where} · Adding to search index`) |
| Added, text, index done | Searchable | existing word ("searchable") |
| Added, some failed, title | Added 4 of 5 PDFs to My books | NEW |
| Added, some failed, text | 1 could not be added · tap to see | NEW (from "could not be added", existing slice words) |
| Failed, title | This PDF could not be added | existing (`AddPdfErrorWords`) |
| Failed, text | Radio field manual · Nothing was added. Your PDF was not changed. | existing words, with the file name |
| Failed, several, title | 3 PDFs could not be added | NEW |

## Paused (the service has stopped; an ordinary notification stays, which can be swiped away)

| Part | Words | Status |
|---|---|---|
| Title | Paused · 2 of 5 PDFs | NEW pattern ("Paused · N PDFs waiting" is existing, `index_overview.dart`) |
| Paused by the person | Paused by you | existing (from "Paused by you · Resume") |
| Action | Resume | existing |
| Battery low | Battery low (12%) · plug in to continue | existing (`indexWaitWords`, lower-cased after the dot) |
| Action | Resume anyway | existing |
| Warm | Paused · device is warm / Paused · keeping the device cool | existing; here as "Device is warm · it carries on when it cools" NEW only if the owner wants the second half |
| Android's time limit | Android limits background work. It carries on while charging, or open Cache. | NEW |
| Waiting for charging (long PDF) | no notification: the service is not started; the in-app card says "Waits for charging (long job)" with Start now, as today | existing |

## Lock screen (private version; no file names or library names)

| Part | Words | Status |
|---|---|---|
| Adding, title / text | Adding PDFs / In the background | NEW |
| Finished, title / text | PDFs added / Open Cache to see them | NEW |

## Asking for notifications (Android 13 and later; shown once, before Android's own prompt, when the first background add could start)

| Part | Words | Status |
|---|---|---|
| Title | Show how adding is going? | NEW |
| Text | Cache can keep adding PDFs when you leave it, and show you how it is going. Allow notifications to see it and to pause it. | NEW |
| Buttons | Allow / Not now | NEW |
| If refused | Cache still adds PDFs, but shows nothing. You can allow notifications in Settings. | NEW |

(The permission is already in the manifest and already asked for weather alerts. If it was granted then, nothing is asked.)
