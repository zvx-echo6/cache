# Changes

What changed in Cache, newest first. Each change is one short bullet under Unreleased when it is merged. When a build goes
out, Unreleased becomes that build's section, and its bullets are the testers' notes (TestFlight "What to test", Google Play
release notes).

## Unreleased

### New
- Android Auto: a climb-ahead card, a mini map of the whole route, the four themes, and End, Mute and Route overview buttons. Android Auto is off in store builds for now
- Weather: the screen is now a weather page for one place at a time: the temperature and conditions at the top, everything happening nearby in one list with the most serious first, and the forecast one line per day; tap the place's name to see all your places with the worst thing happening at each
- Navigation: a row of lane arrows appears under the turn banner as a turn comes within the first voice prompt's distance (800 m driving), with the lane to be in lit and the other usable lanes marked; screen readers say which lanes to use
- Places: drag and zoom the map when adding a place, or Choose on map for a full-screen picker
- Notebooks: tap a photo to see it full screen; pinch to zoom, swipe between photos, turn the phone for wide photos; share or save it

### Fixed
- Weather: Home no longer shows a forecast's temperature for tonight or tomorrow as the temperature now when no current reading is stored (seen with the NWS by point forecast); with that forecast alone, Home shows the forecast for the period under way, such as Tonight
- Weather: when the app is opened, or comes back to the screen, hours after the last update, Home no longer shows the earlier temperature, or yesterday's high and low, as the weather now; a reading counts for three hours, as on the Weather screen, and after that Home shows today's forecast
- Weather: a source whose first download failed says why on the Weather screen, instead of "Not downloaded yet. Update now to get it."
- Weather: the status line in Settings > Weather and alerts no longer turns into a warning only because the last update was more than 15 minutes ago; it warns when the data is more than three hours old, there is no connection or an update failed
- Home: on narrow phones the weather card's conditions with the high and low take a second line instead of being cut off
- Home: "No alerts known, data expired" is marked with a warning sign, not a green tick
- Search: words with hyphens, apostrophes or dots, like COVID-19, don't and U.S., now find passages, not only titles
- Library: when a book is removed, the next search index update deletes its words too (they used to stay in the index), and a search index that is far behind (more than 2,000 new pieces) is rebuilt in one pass instead of being held in memory
- Places: the map when adding a place always opens close in on where you are
- Library: adding a PDF, going to Home and coming back no longer adds the PDF twice or fills the log with "waiting for the earlier run" lines; one run handles each PDF
- Library: the PDF viewer and a PDF being added in the background can no longer use PDFium at the same moment, which could corrupt its memory
- Library: adding a PDF no longer crashes Cache when it moves to the background: PDFium's font lookups no longer depend on which part of the app started first
- Library: a book you add is found by its words as well as by its meaning: its words are added to the search index in a short background job (the finished card and the book's row say "Adding to search index" until then), and a library that missed them before is brought up to date by itself
- Library: on Android the search index of your own books no longer fails and retries on every open
- Sharing and sync: one file that cannot be fetched or deleted no longer holds up the rest of its share
- Ask: Stop now also works while the model is still reading the question and its sources, so Send comes back at once
- Sharing and sync: a link the other device never finished is cleaned up after a week, not kept for ever as a device that never answers
- Sharing and sync: when a shared folder moves (as after an iPhone update), files missing from the new folder can no longer be recorded as deleted
- Weather and alerts: a source that needs a key (satellite fire hotspots, or a source of your own with a key) now updates from Update now, in the background and when you move, not only when Ask looks it up
- Home: the weather card no longer says "no forecast yet" while a forecast is stored; when the current reading is too old to show, it shows today's forecast under the day's name, with its age
- Home and Weather: a warning that has ended no longer shows again for a moment each time Cache opens
- Weather alerts: an alert no longer pops up twice when two updates or two checks run in the same moment, and a damaged record of what you were already told is read from a spare copy, so it no longer brings every alert back
- Weather and alerts: a source's address can no longer be redirected from https to plain http, and a source's key is no longer sent on to a server the source does not name
- Weather and alerts: with Cache left open on the screen, weather and alerts now keep updating every 30 minutes on iPhone and on Linux (before, only when Cache was opened or brought back to the front)
- Weather alerts: with Where I am watched, the same fire no longer pops up again each time you move about a kilometre; it pops up once more only if it comes close enough to be serious
- Weather alerts: a warning that reaches another of your places now pops up for that place even if you were told about it elsewhere, and an update pops up again when it becomes more severe; an update that only changes the end time or the wording stays quiet
- Weather alerts: a fire whose mapped edge you are inside now counts as serious and pops up under Serious only (before, only fires with a distance in miles did)
- Weather alerts and Home: with Satellite fire hotspots on, named fires are no longer left out; every fire source is listed and can pop up, and a fire two sources both name is shown once
- Weather: a source that is switched on without its key now says it needs a key, instead of telling you to update
- Home and Weather: data that ran out while Cache was closed is marked expired as soon as Cache opens, not only after the first update
- Bookshelves: a book Cache is not sure about now stays in Unsorted with its top three suggested shelves, instead of being shelved on a guess; books an earlier build shelved that way come back to Unsorted once, and anything you shelved yourself stays where you put it (a device that is still on build 49 keeps shelving guesses, and those books are not returned)
- Bookshelves: after Go to a number takes you to a shelf or book, the box is emptied and the keyboard stays closed when you come back; dragging the list closes the keyboard
- Weather: Latitude and Longitude in Add your own source put their text in the web address without taking the keyboard from it, and the cursor stays right after it
- Notebooks: a new place no longer gets a color of its own; it follows its notebook's color, and hiding a place on the map no longer gives it one. A place has its own color only when you pick one that differs from its notebook's
- Notebooks: changing a notebook's color asks, when some of its places have a color of their own, whether to change all of them (Change all) or keep their colors; the Pin color line now says its places use the notebook's color unless you give one its own
- Library: the main page of a ZIM shows the ZIM's own title at the top, not the title the page carries (a Wikipedia ZIM's main page said just "Wikipedia")
- Home search: words said in videos and passages of EPUB books are now listed, and a PDF passage opens with the passage marked
- Library: a passage on a page numbered with letters, such as iv or A-3, now opens and shows that page
- Maps: after a guided trip ends, directions, distances and search start from where you are now, not from where that trip ended
- Maps: once you have arrived, guidance no longer reroutes or speaks again if you walk on, and its GPS tracking and notification stop then, not when you tap Done
- Places: Directions on a place while a route is being followed now says to finish or end the route first, as elsewhere, and no longer drops the route and leaves GPS tracking running

## 1.1.0 (build 49, test) - 2026-11-11

### Fixed
- Home: the weather card shows the forecast even when a weather station lists no temperature
- Home: a phone that is already set up no longer shows the Set up Cache card for a moment when Cache opens
- Ask: Stop now works while Ask is searching or reading, not only while the answer is being written
- Sharing and sync: a file dated in the future now syncs; a damaged links file no longer loses your linked devices; and syncing starts again by itself after an internal error

### New
- Sharing: after linking, one answer sets how settings sync on both devices, and you can take the other device's settings.
- Discover is now a module: open it from Modules or pin it to the bottom bar.
- Library: Watch a folder: new PDFs in a folder you choose are added by themselves, when you open Cache or, on Android, in the background while charging
- Notebooks and Maps: a notebook has a map icon and a color, and each place can have its own icon and color; pick them from a searchable icon set, and choose how pins look in Settings > Maps > Pin style (Icon, Teardrop or Badge). A place's icon, color and Show on map now sync between your devices
- Ask: shows each step as it works, such as what it's searching for and reading, and folds them away once the answer starts
- Ask: other apps are less likely to be closed while Ask loads and answers, and background work pauses while Ask answers
- Ask: a phone that stays in one place keeps its location between questions, so nearby answers no longer lose track of where you are
- Library: Add to Library now shows Your own (Your own library, Add a PDF, Add a folder) at the top
- Ask: when a chat is full, it says so plainly with a New chat button, and marks an answer cut short

### Changed
- Android: Cache now ships for 64-bit ARM phones only (x86 devices and Chromebooks are not supported)
- Ask and search: the search model loads when you open Ask or tap a search box, not every time Cache opens, so Cache holds less memory when you aren't searching

## 1.1.0 (build 48, test) - 2026-11-10

### Fixed
- Sharing and sync: after Cache updates on an iPhone, syncing works again (it kept looking in the app's old folders); while it rechecks a moved folder, nothing is deleted
- Storage: free space is shown correctly on iPhone, and downloads and sync keep space in reserve and clean up if storage runs out

### New
- Sharing and sync: each linked device shows when it was last seen, and Unlink asks once to confirm
- Library: a ZIM's menu has "Get icon from source", which fetches its icon again from Kiwix, or reads the one inside the ZIM

## 1.1.0 (build 47, test) - 2026-11-09

This build covers everything new since the public release 1.0.29.

### New
- Library: the new Library has ZIM Collections, Bookshelves, the Catalog and the Cache guide (with What's new and Credits)
- Library: add a PDF, several at once, or a whole folder; scanned pages are read too; each book becomes searchable and is shelved by subject with a call number; if Cache is not sure, the book waits in Unsorted with a best guess to place it
- Bookshelves: list, drawers and spines views, and Go to a number; a book's page lets you rename it, hide it, and mark spare copies of the same book
- Search and Ask: find text inside your PDFs and inside the PDFs, EPUBs and video captions in your ZIMs; answers cite the page, chapter or moment
- Reader: read PDFs and EPUBs inside Cache
- Discover: ready-made setups (Ready, Backcountry, Homestead) plus libraries and maps, each showing what it adds before you get it
- Setup: a step-by-step welcome setup, which you can run again from Settings
- Maps: while navigating, a smaller turn banner, an elevation profile you pull up from the guidance card, and a mini map of the whole route (tap to swap it with the live map)
- Videos: one Videos list and a new player with captions, quality choice, resume and a transcript on larger screens; saved videos are searchable by what is said in them
- Sharing and sync: choose what to share item by item, with Sync now at every level, and a page for each linked device where settings can match or follow one device
- Add your own source: plug in a web service as a weather or data source
- No model needed: search-only mode when no model is installed
- Obsidian and Logseq: tag a note `#cachesync` to bring it into Cache
- Layout: better layouts for phones held sideways, tablets and large iPads
- Known: Ask can still take a long time to answer on some phones
- Known: Ask sometimes offers to search instead of searching

## 1.0.30 (unreleased, test)

### New
- Library: search reaches inside the PDFs, EPUBs and video captions in your ZIMs, and an answer cites the exact PDF page, EPUB chapter or moment in the video
- Library: Cache makes them searchable by itself in the background, easing off when the battery is low, the phone is warm or you are using Cache; Settings shows the progress, and Storage > Advanced has the speed
- Sharing and sync: search and map indexes built on one linked device are used on your others, so each is built only once
- PDF reader: read PDFs inside Cache, with find, go to page, fit and zoom, and dark pages; a citation opens the PDF at its page
- Library reader: EPUB entries in ZIMs open in the reader, and an EPUB citation opens its chapter at the cited passage
- Videos: one Videos list and a new player with captions, quality choice, resume where you stopped, and a transcript beside the video on larger screens
- Videos: saved videos are searchable by what is said in them
- Videos: sign in to a video site the way the site offers it, and play private videos at any quality
- No model needed: with no model on the device Cache is search only (Library, Notebooks, Places, Maps and the guide still work, and saved chats stay readable); Ask comes back when a model is added
- Obsidian and Logseq: tag a note `#cachesync` to import it into Cache
- Layout: a layout for wide windows (computers and a large iPad held sideways)

### Fixed
- Search: a match snippet on text with multibyte characters no longer crashes the search
- Library: no second Add to Library button on wide screens
- Library: source icons from the Kiwix catalogue show again (they were asked for at a size the catalogue does not serve)
- Sharing and sync: a library's search index is no longer copied to your linked devices; each device builds its own, and a copy an earlier version sent is kept or rebuilt
- Sharing and sync: Regions no longer copies what each device fetches or caches for itself (tile indexes, the cache of map tiles viewed online, database working files); every downloaded part still syncs

## 1.0.29 - 2026-11-01

The changes of 1.0.1 to 1.0.28 are listed here too; they had no sections of their own.

### New
- Emergency alerts: official FEMA IPAWS alerts for your area, along with the weather alerts
- Downloads: region maps download many times faster; every download shows what it is doing, with speed and time left
- Models: Gemma 4 E2B tuned for Cache is recommended; uncensored models are listed apart, under Experimental
- Places: places and addresses are ready in seconds after a download; places with a Wikipedia article show a short summary and open the article
- Repeaters: tap one on the map for its details; each repeater list is a notebook
- Weather and alerts settings: choose which places weather watches (your location, regions and saved places)
- iPad and tablets: two panes side by side, and every list can be hidden for more room
- Update notices: Cache says when a new version is ready
- Library: open the Cache guide and read it like a book, with chapters, links between sections, links that open the part of Cache a section is about, and search; a guide citation in Ask and the guide buttons on Set up Cache open the exact section
- Notebooks: keep several notebooks, starting with a Journal; make more from Journal, Log, Notes or Places, or from 16 starter logs
- Notebooks: an entry can have a title, text, a date, a place, photos, attached documents and the notebook's own fields
- Notebooks: type Markdown in any entry and it formats as you type (headings, bold, lists, checkboxes, quotes, code, links, tables); "?" shows how; tap a checkbox's box to tick it
- Places notebook: your own saved places, each with its own marker colour; tap the marker to show or hide it on the map
- Places: one screen to add or edit a place: search an address, place or coordinates, or tap the map; name, colour, notes, photos, and weather and alerts
- Places: each place's alerts can follow your alert setting, have their own distance and kinds (which pop up whatever Pop up for says), or be off
- Maps: press and hold the map for a ring: To here, From here, Add stop (while a route is shown), Save and Measure; Save opens your notebooks (most used first) and makes an entry at that spot; the centre opens the spot's coordinates
- Maps: Measure draws a line from the held spot; each tap adds a point, with the running total, Undo and Done
- Directions: start from a spot you hold on the map, and add up to 10 stops on the way
- Notebooks: keep them in an Obsidian vault or a Logseq graph you pick on the phone (classic Markdown graphs both ways, Logseq 2 by export); changes made in both places are merged and only the same words changed twice are asked about (Notebooks > Connections)
- Maps: add places from a KML, KMZ, GPX or GeoJSON file as a Places notebook, and repeater lists from a RepeaterBook KML or CHIRP CSV, under My layers
- Notebooks: notebook sync keeps your notebooks and their photos the same on your linked devices (tick Notebooks in Sharing and sync); changes made on two devices are merged, and only the same words changed on both are asked about; private items stay on the device unless you include them (Notebooks > Connections)
- Logs: quick add with your last values filled in, "Last done" and "Due again", and a Home card that logs in two taps
- Notebooks: search across all notebooks, and delete any entry (with Undo) or a whole notebook
- Maps: notebooks with places show their pins, each notebook a layer under My layers
- Assistant: can add a journal entry or an entry to one of your logs after you confirm on a card
- Regions include off-road: the off-road data of the state or province the region is in (checked against its published checksum) and its terrain heights, with their size in the download pop-up; off-road directions work wherever a region with off-road is on the phone
- Ask: a source from a video transcript opens the video at the moment it cites (libraries map `fields.time` and `fields.link`)
- Home: a "Set up Cache" card with four steps (choose a model, get your area, turn on weather, add a library), each ticked when it is done and showing its download while it runs; it goes away by itself when all four are done
- Directions: routes to airports, parks and campuses arrive where people actually go, and starts snap to the right road
- Regions include places and addresses for map search
- Map search says when places for the area are missing or on their way, and offers the region
- The search model (605 MB) now comes with your first chat model and gives meaning search to maps, the library and the assistant
- Assistant: can save places, watch places for weather and start navigation after you confirm on a card
- Add your own library from a file on the device or a download link, in Library > Add to Library > Your own library
- A newer copy of a library you have is offered as an update and swapped in safely
- Remove a library, and see its size, entries and whether it is ready
- Get a blank library template to build your own library
- Weather: turn it on in one tap from the Weather screen or Home
- A place you save is watched for weather and alerts
- Models starts with a short list of recommended models, each with its size and whether it fits your phone
- Maps: off-road directions on foot or by vehicle, with a land-access choice, where off-road data is installed
- Assistant: says why live data is not up to date (source switched off, no connection, mobile data updates off, or the refresh failed)
- Assistant: nearby places and navigation destinations show the website and whether the place is open now
- Assistant: the calculator works out dates, such as the days between two dates or the date 30 days from today
- Assistant: when a route can't reach a point away from the roads, it says whether the off-road data is missing or no off-road way was found
- Assistant: reading a library entry shows its author and page when known
- Import repeater lists (a RepeaterBook KML, a CHIRP CSV, or both from the same export, merged) and export them as KML for Google Earth
- Import your own map layers from KML, KMZ, GPX or GeoJSON, and export them as KML or GPX
- Assistant: its actions (saved places, watched places, data sources, starting navigation, checking setup) now run through the search core; anything that changes something still waits for your tap on the card
- Assistant: can check what is set up on the phone (connection, regions, libraries, live data, web search key set or not, models, location) and points to the guide section for each, to answer setup questions; keys are never shown to it
- Weather: "Ask about this" on an alert opens the chat with that alert's live data already looked up, so the answer starts from it
- Assistant: a conversation can be in voice mode, where answers are kept to a few plain spoken sentences (the voice controls come later)
- Assistant: finds your nearest imported repeaters with their settings, and the points of your own map layers by name or nearby
- Library: one list of everything, your ZIMs and your own libraries, each with its icon, a short description and its size; a badge shows only for an exception such as "Update ready"
- Library: press and hold an item (or "..." when it is open) for Check for update, Change icon, Add to Home and Delete; one Add to Library screen holds Kiwix's collections, each with its own download button, and your own library
- Library: a download can be paused and resumed
- Downloads: one pop-up before every download lists what it brings with its size and the phone's storage after; when it does not fit it says how much more is needed and offers Free up space
- Downloads: Cache always leaves 10% of the phone's storage free (at least 5 GB, at most 20 GB)
- Downloads: on mobile data with Mobile data downloads off, the pop-up offers Wait for Wi-Fi, and the download starts by itself on Wi-Fi
- Delete always asks first, saying what it frees and the storage after
- Home: one search box searches the Library, places and addresses, and map layers; the first row always asks Cache exactly what you typed, and Enter starts that chat
- Home: one Weather and alerts card with a weather icon and the temperature, and each warning and fire near you with its own icon
- Settings: eight rows, each with its state in one line: Cache model and web search, Maps, Weather and alerts, Notifications, Storage, Sharing and sync, Appearance, Credits and licences
- Notifications: one choice, Pop up for: Serious only (the default), All alerts or None; serious alerts still ring in quiet hours
- Storage: what each kind of thing uses (Library, Models, Regions, Videos and weather), each opening a list to remove items, Clean up for unfinished downloads and temporary files, and the space kept free for the phone
- Weather and alerts settings: one line says how old the data is, with a small refresh button; the sources come from the catalogue, featured ones first and the rest under More sources, and a key is added from the source's own row
- Models: tighter cards; the search model is one line in the first model's download pop-up (for searching by meaning), with no separate question
- Ask: Cache uses your location whenever the phone allows it and never asks; the + button beside the box holds the Use my location switch
- Ask: tap the model name for the model and the memory it takes, Switch model, Unload and Manage models
- Library: the Cache guide comes with the app, so its setup help is there from the first start with no download; it cannot be deleted
- Library: a library file compressed with gzip can be added (from a file or a link) like an uncompressed one, and the blank template is saved compressed
- Regions: one sheet lists the regions where the map is, smallest first, each with its size and a download button or "On this phone"; Select (or press and hold) picks several for one download
- Regions: on mobile data with Mobile data downloads off, Wait for Wi-Fi starts a region by itself once on Wi-Fi
- Settings > Cache model and web search: the Use my location switch (the same as in Ask); when the phone blocks location it says so and opens the phone's settings
- Alerts: a fire within 10 mi of a watched place, and an evacuation order, are serious and pop up under Serious only; farther fires are listed in Weather
- Videos: playback speed, and true full screen (landscape for a wide video, the phone's bars hidden) with the controls on a tap

### Fixed
- Regions: places not published for an area yet say "not available yet" instead of failing; the region counts as done
- Regions: a part left waiting with nothing downloading offers Carry on; places published after a region was downloaded are added at the next start
- Weather: Home no longer says "Not set up yet" for weather that is on while Cache is still starting after an update; an update never resets your settings
- Library: what a sync brings shows in the list at once, without restarting Cache
- Ask: a source from the phone's setup opens the guide section it names
- Library reader: a ZIM made without pictures no longer shows white boxes in dark mode
- Obsidian and Logseq: only Cache's own notes are synced; notes you make there stay yours, and a Cache note deleted there comes back
- Regions: a region's size shows at once in the Regions sheet, from the region list (only an area you draw is worked out on the phone); a region the list has no size for says "Size unknown"
- Regions: tapping a region always opens the one download pop-up: download, carry on with what stopped, or add off-road; a region partly on the phone is never "Can't be downloaded here"
- Regions: a region's row says which parts are not ready yet and labels its bar; tap it for the region's page (each part, its state and its fix), press and hold for Carry on, Check for update and Delete
- Regions: anything that stopped or failed has its fix next to it (Carry on, Try again, Delete); messages say what happened and what to do, never the core's own text
- Regions: Update on a region no longer fails with "a download needs bbox"; a download stopped in an older build carries on
- Maps: map downloads made layer by layer by earlier builds join the region they are in (or list as one area), and duplicates are removed; Settings > Maps shows one line per region; hillshade and contour lines download their elevation once
- Home: "Hide" on Set up Cache, with Undo; Edit Home brings it back
- Weather: a condition that starts a line starts with a capital ("Rain")
- Library: the Cache guide reads better: short paragraphs, labels as chips, links in the text, Previous and Next, contents with sections, search with the words around each match and "Ask Cache instead"
- Regions: the sizes no longer hold up the map, the Library and the reader's pictures while they are worked out; each region's size shows as soon as it is known, and sizes already worked out show at once
- Regions: "Draw your own area instead" from Home's Set up Cache opens the map to draw the area
- Library: the guide that comes with Cache is labelled "Built in", and a library still opening when Cache starts no longer stays on "Opening"
- About shows the full version, 1.0.27; the version number now matches the build on iPhone and Android
- Weather: the forecast and alerts on the phone show at once, with their age, while newer ones are read
- Weather: while "Where I am" waits for the position, the Weather screen says so instead of offering to turn weather on
- Regions: a download stopped because Cache was closed (iPhone stops it in the background) carries on when you tap Get your area or Update, after Cache starts again
- Regions: each part of a region (map, directions, places, off-road) works as soon as it is saved, and downloads from where you are outwards; the region's line says where each part stands, and Set up says "Not offline yet" until all of it is saved
- Regions: a region downloads the terrain heights for its own area, and a state's off-road data is downloaded once for all its regions ("Already on this phone"); Storage > Regions lists it
- Library: "Opening" is now "Getting ready"
- Weather: fires show how far away they are on Home again
- Ask: Try again after Cache's search could not start starts it again, instead of failing the same way
- Assistant: a reopened chat stays in the mode it was started in, voice or text; switching mode starts a new chat
- Turn-by-turn: the arrive time shows instead of "--", and on Android the spoken directions can find the phone's text-to-speech
- Directions: starting navigation no longer asks to allow notifications and waits on the answer before finding your position; notifications are asked for when you turn on weather and alerts
- Directions: when there is no off-road data for the area, Walk and Drive buttons show under the message and switch to that way of travel
- Regions: a part that cannot be downloaded says so in plain words, such as "Places for this area aren't available yet.", instead of the server's error and address
- Library: adding the blank template says it is empty and needs your own entries first, and a file that is not a library says "This file isn't a Cache library." instead of showing internal error text
- Weather: when you open Cache or come back to it, weather, alerts and fires update if the last update is more than 30 minutes old, since iPhone runs background updates only when it chooses
- Weather: Update now downloads the forecast again even when the last copy is less than 3 hours old, and the Weather page always shows which place it is showing, also when only one place is watched
- Maps: the base map is on the first time the map opens, also when the map catalogue arrives after the app starts, so a fresh start no longer shows a blank map
- Ask: after Use my location, the message says your location is ready only once the assistant has it, like the Location ready button
- Saved places can be removed: Remove place on the place card and in Settings > Weather and alerts > Places, after a confirm; a removed place is no longer watched
- About: shows the version and build number of the installed app, and the note about builds names TestFlight only on iPhone and Google Play on Android
- Regions: the size before downloading is closer to the real size for maps, and the sheet also shows the size in all, counted the way Local counts it, when part of the region is already on the phone
- Library: when the phone runs low on memory while you read, the page stops and offers Reload instead of closing Cache
- Home: the Weather and alerts card picks up your position as soon as the phone has it, and say "Waiting for your position" until then instead of asking you to choose a place
- Home: the Weather and alerts card shows warnings and fires for one place, the same place as the forecast, instead of adding up every watched place
- Weather places: each watched place is on its own line, and a dropped pin is named like "Pin 40.76, -111.89", so its coordinates no longer read as two places
- Cache no longer asks where you are when the phone already knows
- Assistant: asking to open a place, route, live data or location result no longer fails with an internal error
- Map search: chains like Maverik or Subway show the nearest stores, a street address finds the house in the town you name, and short searches like "ER" or "vet" find the kind of place rather than names that start with those letters
- iPhone: free space matches iPhone Storage in Settings, so downloads (libraries, Wikipedia, models, maps) are no longer refused when there is room
- Regions: the keyboard no longer pops up after the download sheet closes
- Unload the model in use from Models to free memory
- The keyboard closes when you tap outside a text box or scroll
- With no model, the Ask screen has a button to get or choose one
- Model names show the right quantisation in more cases
- iPhone: the Hugging Face file list shows whether each file fits your phone
- Map search: street and town names in addresses are no longer shown in capitals (North State Street, Hurricane)
- Maps: BLM roads and trails and Forest Service trails draw in their own colours and dashes
- Ask: a question asked while Cache is starting shows Starting… and is answered with Cache's search once it is up; if search cannot start, it says so with Try again instead of answering without it

### Changed
- Maps: a layer no longer has a download of its own; Draw your own area instead, in the Regions sheet, draws an area on the map and downloads it as a region through the same sheet and pop-up
- Storage: Clean up also removes damaged off-road data (a file whose size or checksum does not match what was published), so it can be downloaded again
- Weather, alerts and other small updates always use any connection; the Mobile data downloads switch in Storage is for big downloads only

## 1.0.0 (iOS build 22) - 2026-10-28

### Fixed
- iPhone: Cache no longer closes as soon as it opens

## 1.0.0 (iOS build 21, Android 3) - 2026-10-28

### New
- Find and download models from Hugging Face
- Weather module with forecast, alerts and wildfires for your places
- Weather and alerts update in the background
- Pop-up alerts for new warnings and fires near your places
- Sharing and sync between your devices
- Weather answers for today, tonight, tomorrow or any day
- Tonight's low from the hourly forecast
- Download regions for offline road routing and maps
- Regions at every size, from part of a state to a country
- Routes online without downloading anything first
- Modules screen shows app icons; tap and hold for options
- Small or large module icons in Settings > Appearance

### Fixed
- Interrupted downloads no longer leave broken files
- Unfinished model downloads stay hidden until done
- Restarting a cancelled library download no longer deletes it
- Search indexes of removed books are cleaned up
- Settings are always saved whole

## 1.0.0 (iOS build 18, Android 2) - 2026-10-28

### New
- New Cache look, icons and themes
- Settings rebuilt into groups with their own pages
- Report this answer in Ask
