# Changes

What changed in Cache, newest first. Each change is one short bullet under Unreleased when it is merged. When a build goes
out, Unreleased becomes that build's section, and its bullets are the testers' notes (TestFlight "What to test", Google Play
release notes).

## Unreleased

### New
- Notebooks: keep several notebooks, starting with a Journal; make more from Journal, Log, Notes or Places, or from 16 starter logs
- Notebooks: an entry can have a title, text, a date, a place, photos, attached documents and the notebook's own fields
- Notebooks: type Markdown in any entry and it formats as you type (headings, bold, lists, checkboxes, quotes, code, links, tables); "?" shows how; tap a checkbox's box to tick it
- Places notebook: your saved places, with "Where I am" and your downloaded regions, each place with its own marker colour; tap the marker to show or hide it on the map
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
- Regions: the sizes no longer hold up the map, the Library and the reader's pictures while they are worked out; each region's size shows as soon as it is known, and sizes already worked out show at once
- Regions: "Draw your own area instead" from Home's Set up Cache opens the map to draw the area
- Library: the guide that comes with Cache is labelled "Built in", and a library still opening when Cache starts no longer stays on "Opening"
- About shows the full version, 1.0.27; the version number now matches the build on iPhone and Android
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
