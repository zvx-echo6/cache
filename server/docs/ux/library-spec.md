# Cache for Linux: Library flows

Based on the phone code (browse, download, catalogue, theme). Mock: library-mock.html (`?theme=&state=`), viewed at 1920x1080. Sample numbers. User-visible text never says "server" or "job". One device word everywhere: "this device". Phone and tablet move to it in 1.0.30; Linux and Windows use it from the start. Model-visible "this phone" text (system prompt, tool definitions) is unchanged; that is the training session's call.

## Layout
1.0.29 frame: rail 80, list pane 340, detail pane at most 640. The list keeps the phone's rows, badges and transfer cards. "Add to Library" opens in the detail pane (the phone pushes a page), so progress stays visible beside the catalogue.

## 1. Downloads
Same catalogue and dialog, plus one line: "It keeps downloading if you close this tab." After Download: snackbar "Download started. It keeps downloading if you close this tab." and the phone's transfer card (pause, cancel, Try again). List hint while any run: "Downloads keep going if you close this tab."
On reopen the list shows the current state. A card "While this tab was closed" lists what finished, still runs or failed, with Dismiss. Running cards show "started yesterday 22:10".

## 2. Upload from this computer
Add to Library, first section "From this computer": drop zone and Choose a file. Dropping anywhere on Library shows an overlay naming the file and size.
- Progress: card "Uploading", name, bytes, speed, time left, Cancel (discards the partial file). Hint: "Keep this tab open until the upload ends."
- After 100%: Checking, Building the search index, Putting it in place run on the device and survive the tab.
- Not enough space: checked before sending, using the phone's dialog (reserve line, Free up space). Full disk mid-upload: failed card "Not enough space on this device. The partly uploaded file was removed."
- Wrong type: by extension (.zim, .cache-library, snapshot) before sending; inline warning plus snackbar; nothing sent.

## 3. List
Phone rows unchanged; ready has no badge (exceptions only): "Indexing 34%", "Can't be read" / "Can't be opened". Hover shows a "..." button opening the phone's item menu (no hold on a mouse). Delete keeps the phone's confirm; for uploaded items the last line is "You uploaded this file. To get it back, upload it again." The mock keeps the app's "Delete" for "Remove".

## 4. Free space
Footer of the list pane, always visible: "Device storage, 58.4 GB free of 500 GB", bar, "Cache keeps 20 GB free for the device" (the phone's own wording), and while transfers run "56.9 GB still to download, 29.7 GB will be free after". Also in each confirm dialog, as on the phone.

## Proposed, not approved
Resuming an interrupted upload; right-click menu; Replace prompt for a same-name upload; leave-tab warning during upload; one device word read from one place, so each string is written once (the mechanism is not approved; the wording is the owner's decision).

## Open questions
Does the device count in-progress downloads against free space? Can the page read total disk size? Chunked or single-request upload decides whether resume is feasible.

# Strings (phone wording to 1.0.29, then wording from 1.0.30 on every platform)

The device word is the same on every platform. Rows that only swap "this phone" for "this device" apply to all; upload and the dropped Wi-Fi rules apply to the Linux/Windows variant only. Model-visible text is excluded (see above).

Library and add flows
| Phone (to 1.0.29) | From 1.0.30 |
|---|---|
| On this phone (catalogue badge) | On this device |
| That source is not on this phone any more. | That source is not on this device any more. |
| Phone storage (delete and download dialogs) | Device storage |
| Cache keeps X free for the phone | Cache keeps X free for the device |
| From a file on this phone | From this computer |
| Copying <name> | Uploading |
| ...and read them with no signal. | They are kept on this device and work with no internet. |
| ...change one from the hold menu. | ...change one from the item's menu. |
| Delete: "You can download it again later." | Unchanged; uploaded items: "You uploaded this file. To get it back, upload it again." |
| From a download link: "A link to a library file" | Unchanged |
| Waiting for Wi-Fi, Wait for Wi-Fi, Download now, mobile-data lines | Removed (no mobile data on this device) |
| Add dialog: no equivalent | "It keeps downloading if you close this tab." |
| Not enough space: "...the device is out of space" | "Not enough space on this device." |

Outside Library (only the device word differs)
| Phone (to 1.0.29) | From 1.0.30 |
|---|---|
| Report saved on this phone. | Report saved on this device. |
| No places on this phone. | No places on this device. |
| Wikipedia is not on this phone. | Wikipedia is not on this device. |
| Part of this trip is off the roads, and the off-road map data is not on this phone | ...not on this device |
| Not saved. Your phone may be out of space. | Not saved. This device may be out of space. |
| Layers use X on this phone. / X on this phone (maps) | ...on this device |
| The downloaded tiles are removed from this phone. | ...from this device. |
| Saved on this phone (Videos) | Saved on this device |
| This video isn't saved on the phone... | ...isn't saved on this device... |
| This region is no longer on this phone. / Not on this phone / On this phone · size | ...this device... |
| The file and its index are deleted from this phone. | ...from this device. |
| Every saved chat is removed from this phone. | ...from this device. |
| The key stays on this phone and isn't shown again. / Saved on this phone, not shown again | ...this device... |
| N on this phone (Assistant settings) | N on this device |
| The model... runs on this phone | ...runs on this device |
| Fits / May be tight on / Too big for this phone | ...this device |
| Choose from phone | Choose from this computer |
| The phone's location is switched off; Blocked in the phone's settings; Phone settings | This device's location...; Location settings (the browser asks) |
| Waiting for your position... once the phone knows where it is | ...once the device knows where it is |
| You are Cache... running on this phone (assistant prompt) | ...running on this device |
