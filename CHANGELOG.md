# Changes

What changed in Cache, newest first. Each change is one short bullet under Unreleased when it is merged. When a build goes
out, Unreleased becomes that build's section, and its bullets are the testers' notes (TestFlight "What to test", Google Play
release notes).

## Unreleased

### New
- Notebooks: keep several notebooks, starting with a Journal; make more from Journal, Log, Notes or Places, or from 16 starter logs
- Notebooks: an entry can have a title, text, a date, a place, photos, attached documents, a checklist and the notebook's own fields
- Logs: quick add with your last values filled in, "Last done" and "Due again", and a Home card that logs in two taps
- Notebooks: search across all notebooks, and delete any entry (with Undo) or a whole notebook
- Maps: notebooks with places show their pins, each notebook a layer under My layers
- Assistant: can add a journal entry or an entry to one of your logs after you confirm on a card
- Home: a "Set up Cache" card with four steps (choose a model, get your area, turn on weather, add a library), each ticked when it is done and showing its download while it runs; hide it, and find it again in Settings > Set up Cache
- Directions: routes to airports, parks and campuses arrive where people actually go, and starts snap to the right road
- Regions include places and addresses for map search
- Map search says when places for the area are missing or on their way, and offers the region
- The search model (605 MB) now comes with your first chat model and gives meaning search to maps, the library and the assistant
- Assistant: can save places, watch places for weather and start navigation after you confirm on a card
- Add a library from a file on the device or a download link, in Library > Libraries
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

### Fixed
- Turn-by-turn: the arrive time shows instead of "--", and on Android the spoken directions can find the phone's text-to-speech
- Directions: starting navigation no longer asks to allow notifications and waits on the answer before finding your position; notifications are asked for when you turn on weather and alerts
- Directions: when there is no off-road data for the area, Walk and Drive buttons show under the message and switch to that way of travel
- Regions: a part that cannot be downloaded says so in plain words, such as "Places for this area aren't available yet.", instead of the server's error and address
- Library: adding the blank template says it is empty and needs your own entries first, and a file that is not a library says "This file isn't a Cache library." instead of showing internal error text
- Models: when the search model is missing, "Meaning search needs the search model" with Get it shows under On this phone, so it can be got after the one-time question was closed or its download stopped
- Weather: when you open Cache or come back to it, weather, alerts and fires update if the last update is more than 30 minutes old, since iPhone runs background updates only when it chooses
- Weather: Update now downloads the forecast again even when the last copy is less than 3 hours old, and the Weather page always shows which place it is showing, also when only one place is watched
- Maps: the base map is on the first time the map opens, also when the map catalogue arrives after the app starts, so a fresh start no longer shows a blank map
- Ask: after Use my location, the message says your location is ready only once the assistant has it, like the Location ready button
- Saved places can be removed: Remove place on the place card and in Settings > Weather and alerts > Places, after a confirm; a removed place is no longer watched
- About: shows the version and build number of the installed app, and the note about builds names TestFlight only on iPhone and Google Play on Android
- Regions: the size before downloading is closer to the real size for maps, and the sheet also shows the size in all, counted the way Local counts it, when part of the region is already on the phone
- Library: when the phone runs low on memory while you read, the page stops and offers Reload instead of closing Cache
- Home: the Weather and Alerts cards pick up your position as soon as the phone has it, and say "Waiting for your position" until then instead of asking you to choose a place
- Home: the Alerts card counts warnings and fires for one place, the same place as the Weather card, and names it, instead of adding up every watched place
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
