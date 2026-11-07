# Cache: Build your own library from PDFs (browser)

Mock: build-mock.html (`?theme=light|dark&state=...`), viewed at 1920x1080. Same frame as the approved Library: rail 80, list pane 340, detail pane at most 640, same tokens, rows, badges, transfer cards, "This tab was closed" card, Device storage footer. Sample numbers.

## Flow
1. **Entry.** Add to Library, group "Your own": the phone's "Your own library" (file or link) stays; a second row, "Build from your PDFs", is added. Without the search model the row shows "Needs search model" and opens the download step (state `no-model`). Dropping PDFs anywhere on Library opens this flow (approved; state `drop-anywhere`).
2. **Build page.** Two steps on one screen. (1) Where: "A new library" (name field; checked for duplicates) or "A library you built" (the ones made from PDFs). (2) Drop PDFs or a folder, or Choose PDFs / Choose a folder; subfolders included; non-PDFs are left out and named. The page says what building costs: about 200-word passages with page and heading, a second per passage, slower on small devices, scanned pages slower, keeps going with the tab closed. No confirm step: dropping starts the upload.
3. **Upload.** The approved upload pattern: one card (count, bytes, speed, time left, Cancel), "Keep this tab open until the upload ends", per-file bars for the few in flight. Building starts on the first book, so uploading and building overlap.
4. **Queue.** It lives on the library's own page, not a separate screen, and the list pane carries the usual transfer card plus a "Building 8%" badge. The panel shows only work that is not finished: the active book, anything needing attention, "N more waiting" (Show). Finished books move into Books below. Per-book lines: Waiting, Reading the PDF, Reading the pages as images (OCR) · page x of y, Building passages · x of y, Skipped (same content already in this library), failed with reason and Retry (and Dismiss). Overall: "x of 214 books done", a bar, and a range ETA labelled an estimate. Pause becomes Resume; the bar turns amber. One bad PDF never stops the batch.
5. **Tab reopened.** Same "While this tab was closed" card as approved, with counts of built, failed and skipped books; running books show "started yesterday 22:10".
6. **Library page.** Header, counts, Add PDFs (adds only new books), Search this library (passages with book, page, heading, exact words; device only). Books: title, pages, passages, added; ready has no badge. Hover shows Edit title and "...". Edit title is inline: Save, Cancel, "Use file name"; titles come from the PDF's metadata, else the file name. "..." offers Replace with a newer edition (one PDF; only that book is rebuilt; the old one stays searchable until the new one is ready) and Remove (confirm with space freed; the PDF on the computer is untouched).
7. **No model.** A card above the form: what it is, 630 MB, space check, Download search model. While downloading, the same card shows bytes, speed, Pause and Cancel, and the list pane shows the transfer card. The form stays usable so PDFs can be added; building waits. Failure: reason, kept bytes, Try again.

## Why this and not the alternatives
- Queue as its own page: rejected; the library page is where people return, and one place avoids two views of one batch.
- Exact ETA: rejected; the machine and scans vary. A range with a reason.

## Approved by the owner
Dropping PDFs anywhere on Library; renaming a library (from the library's "..." menu); Stop building (confirm; offers to turn the drop folder off too, state `stop-confirm`; replaces the old close icon); adding PDFs during the model download. The "On your phones" card is removed everywhere.

## Open questions
- Does Pause stop mid-book, or finish the book? The resume line depends on it.
- Is a duplicate judged within this library only, or across libraries?
- Does editing a title need passages rebuilt? The mock says no.
- Can the browser read folder contents on every target browser (Firefox, Safari)? Choose a folder may need a fallback.
- Full disk while building: assumed to pause with "Not enough space on this device".

## Desktop width class (Proposed, not approved)
Owner feedback: too much dead space. Today the detail pane stops at kDetailMaxWidth (640) and is centred, and the list is 340. The width classes live in the shared layout, app/lib/layout/adaptive.dart, which is the app team's file; this is a proposal for them, not a change I own. Mock: `?class=tablet` forces today's layout for comparison; any window of 1280 px or more shows the desktop class.
- **Threshold 1280.** Two columns need about 380 px each plus a gap, so the detail pane needs about 800; with the rail (80) and a 380 list that is 1260. Below it the 640 pane is not wasteful (a 1100 window leaves 680 for the detail). 1400 would leave 1280-1399 windows with gutters.
- **List 380** (was 340): longer titles, badges and transfer cards stop truncating ("Hunting and field guides" plus a badge).
- **Detail up to 1400**, two columns: left about 36% (min 380), right the rest. 1920 fills almost edge to edge; 1440 gives 380 and 530.
- **Add to Library:** left, From this computer, Your own, From a download link; right, the catalogue as a two-column grid (16 visible instead of 6).
- **Library page:** left, counts, Add PDFs, the queue; right, search and the books as a table (Title, Pages, Passages, Added, actions; a status badge only on exceptions). Search results sit in the right column at 72ch.
- **Build page:** left, where; right, the drop zone and the notes at 70ch.
- **Library with nothing chosen** shows Add to Library in the detail pane (TwoPane already takes an `initial` page) instead of "Choose an item".
- **Limits:** the new-library form still leaves space below; it is a form, and stretching it would not help. Other states (uploading, no-model, dialogs) are not re-laid; they follow the same left/right rule and are not yet rendered in the desktop class. The 1440x900 catalogue scrolls.

## Drop folder: a queue moved between folders
One device-wide folder on this device (a device path, not a browser upload). Cache creates three subfolders in it. States `ingest-setup`, `ingest-pick`, `ingest-active`, `ingest-error` (`&err=denied` for no permission); desktop class at 1920 and 1440, tablet checked with `?class=tablet`.
- **ingest/** is the queue. Files dropped here are taken in order; the table shows the position (#) and per file: Queued, Working (with progress), then moves on.
- **complete/**: a file moves here once it is added or built. A duplicate also moves here (shown as "Duplicate: the same content is already in X"), because it is already in the library.
- **failed/**: an unusable file or a failure moves here with a reason, in the UI and in a note file beside it, `<name>.why.txt`. Anything that is not a supported type goes here too, as "Not a file Cache can use", in secondary colour, without Retry.
- **Retry** on a failed file moves it back to ingest/, at the end of the queue (my assumption; open question).
- **Types:** PDF built into the chosen library; .zim added to the Library like a download; .cache-library and .gz added or updated like an upload.
- **Where:** Add to Library, row "Drop folder" (On, checked 2 min ago). Own page: settings left, queue right (tablet: one column). The leave-or-move choice is removed: moving is always what happens.
- **Settings:** folder typed or Choose from this device (picker with New folder); suggested default the ingest folder inside Cache's data folder (sample `/srv/cache/ingest`); PDFs go into one library by name; on/off; Check now; "A new library for each subfolder of ingest/" is Proposed, not approved.
- **Status:** chips with counts (All 44, Queue 4, complete/ 38, failed/ 2), "Last check 2 min ago: 2 new files found", then the three groups.
- **Errors:** folder missing (maybe an unplugged USB disk; files stay put; Cache looks again at the next check) and no permission; the table is dimmed as "last known state".
- **Stop building** offers to turn the drop folder off too.
- **Open questions:** watch or timer, and how often (no interval is shown). Does a file wait until it stops growing? Is a retried file queued last? Is `.gz` safe to tell apart from other archives? Does moving a file out of ingest/ by hand cancel it?

## ZIM pages open full window (owner decision)
State `reader-full-window` (desktop 1920): the list pane is hidden, the rail stays, the article fills the width with no 70ch cap (the ZIM's own layout, including its infobox). Back arrow and X close it the normal way, back to the Library with the list pane restored. Find in this article sits in the top bar.

## Cache Decimal System (CDS) in the UI (owner approved; source vault/projects/cache-classification.md)
States `library-classes`, `library-division`, `unsorted-place`, and the drop folder states `ingest-active` and `ingest-setup`; desktop class, 1920, light and dark. The tablet layout is not re-rendered for this.
- **Browsing:** no new page. Selecting a built library expands it in the Library list pane: first "Unsorted" (with a "3 to place" badge), then the 10 classes as number, name and book count. A class expands to its divisions with counts. Selecting a division fills the detail pane's right column with that division's books by call number; selecting the library itself lists all books by call number. A breadcrumb (library / class / division) sits above the table.
- **Call number:** a quiet monospace label before the title (`CDS 530-001`), in every book row; Unsorted books have none.
- **Unsorted:** selecting Unsorted lists each book with why it is there and a "Place it" button. It opens a picker: Cache's three best guesses by meaning (best match first), then a search box and the full list of divisions grouped by class. The button names the target ("Place it in 020"), and the note says where the file will move. Books stay searchable while they wait.
- **Drop folder:** the complete/ line of the folder key says "filed by subject"; result rows say where each book went ("Filed in 530 Water treatment · CDS 530-001, as "The Water Purification Handbook""); an unsure book shows "Filed in Unsorted" with Place it; a book placed by hand shows "moved from Unsorted". The setup page shows the numbered tree of complete/.
- **Edit classes:** a row in the library page's left column and a line at the foot of the class tree. Its detailed design is Proposed, not approved; nothing behind it is shown.
- **Open questions (now settled by the owner):** Unsorted has no number and is listed first; call numbers are `CDS ` + the division + a sequence number (`CDS 830-001`), shelved in order and never reused (a second claim on a number shows `.1`); .zim and .cache-library files go to complete/ZIM files/ and complete/Library files/; 060 is hidden in the picker; hand-moving in complete/ is not in this round; no confidence numbers.

## Same book, different file (owner approved)
States `edition-decision` and `removed` (plus `ingest-active`), 1920, light and dark. Detection and the winning copy are decided by content, as the vault doc says; the UI only reports it.
- **Result rows** in the drop folder table, each with a quiet "Removed" link: "Replaced: the new copy has 312 text pages vs 298. Rebuilt in place as CDS 530-001" (the better copy kept, the book keeps its call number and place); "Already have a better copy (CDS 840-001)"; "Exact copy of Wilderness Medicine Handbook, 7th ed (CDS 210-002)". Duplicates and replaced copies go to Removed.
- **Needs a decision:** a card at the top of the drop folder queue, never decided silently. It shows both titles side by side (pages, pages with text, year if known, where the old one is filed), a one-line "What differs", and two buttons, Keep both and Replace the older one (with a note that the older copy goes to Removed for 30 days). The waiting file shows in the queue as "Waiting for your decision". The library gets a badge in the list pane ("1 to decide"), like Unsorted's "3 to place", and a banner with Decide on its page.
- **Removed:** not a main page. A quiet "Removed · 3" link at the foot of the drop folder page (the library's "..." menu would hold the same link) opens a small list: file, why, date, "Deleted in N days", Restore. Restore puts the file back in ingest/ to be looked at again (my assumption).
- **Files by type:** .zim goes to complete/ZIM files/ and .cache-library to complete/Library files/. They are not classified.
- **Not shown:** no confidence numbers anywhere. Hand-moving files in complete/ is not part of this round.
- **Open questions:** (1) "Keep both": is the new book filed in the same division with the same three letters, and how are two books with the same call number told apart (the mock does not show it)? (2) After "Replace the older one" is it rebuilt at once or queued last? (3) Can a Removed copy be restored when its replacement is already in the library (it would then be compared again)? (4) Does Restore appear for exact copies, or only for replaced ones?

## Strings
| Where | Text |
|---|---|
| Add row | Build from your PDFs / Make a searchable library from PDF files on this computer. |
| Add row, no model | Needs the search model first (630 MB). |
| Page | Build from your PDFs |
| Step 1 | Where should the books go? / A new library / A library you built / Library name |
| Step 2 | Add your PDFs / Drop PDFs or a folder here / Choose PDFs / Choose a folder |
| Name taken | You already have a library called "X". Choose another name, or add to it. |
| Left out | 2 other files were left out (notes.txt, cover.jpg). |
| Upload | Uploading 214 PDFs / Keep this tab open until the upload ends. Building starts on the first book and carries on without this tab. |
| Hint | Building keeps going if you close this tab. |
| Queue head | Building X / 18 of 214 books done / Building is paused. Finished books are kept. |
| Buttons | Pause, Resume, Retry, Dismiss, Show, Add PDFs |
| ETA | Roughly 9 to 13 hours left. This is an estimate and gets better as books finish; scanned books take longer. |
| ETA paused | Time left is not counted while paused. |
| Book states | Waiting / Reading the PDF / Reading the pages as images (OCR) · page 118 of 340 / Building passages · 212 of 480 / Skipped. The same content is already in this library as "Y". |
| Drop folder | Drop folder / Files you copy into a folder on this device are added automatically. / Folder on this device / PDFs go into / Turn on drop folder / Turn off drop folder / Check now / Retry / ingest/: Drop files here. This is the queue. / complete/: Added or built. Duplicates too, they are already in the library. / failed/: Could not be used, with a note saying why. / Queue · in the order Cache takes them / Not a file Cache can use / The drop folder is missing / Cache can not read the drop folder |
| Stop | Stop building X? / The 196 books still waiting are taken off the list. The 18 finished books and the one being built now stay. You can add the PDFs again later. / Also turn off the drop folder |
| Failures | This PDF is protected with a password. Remove the password and add it again, or retry. / The file is damaged and could not be opened. / No text was found and the pages could not be read as images. / Not enough space on this device. |
| Reopened | While this tab was closed: 75 books were built. / X is still building. / 1 book couldn't be built. / 1 book was skipped as a duplicate. |
| Badges | Building 8%, Paused, 2 failed |
| Library | 214 books · 98,430 passages · built from your PDFs / 512 pages · 702 passages · added 1 h ago / Search this library |
| Edit title | Use file name / Only this title changes. The passages are not rebuilt. / This PDF has no title inside it, so the file name is used: F |
| Remove | Remove X from Y? / Only this book is removed. The rest of the library is not touched. Your PDF on this computer is not deleted. To get it back, add the PDF again. |
| Replace | Choose the new PDF. Only this book is rebuilt. The current one stays searchable until the new one is ready, then it is swapped in. |
| Empty | No books in this library yet. Add PDFs and Cache builds them one at a time. It keeps going if you close this tab. |
| Model | Building needs the search model / Cache uses it to read each passage so your phone can find it later. Download it once, 630 MB. It stays on this device and works with no internet. / Download search model / Downloading the search model / The search model did not download |
| Snackbars | Uploading 214 PDFs. Keep this tab open. / Building paused. Resume it any time; finished books are kept. / Title changed. / Book removed. |
