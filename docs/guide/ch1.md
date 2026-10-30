# 1. Getting started

## Set up Cache

On a fresh install, "Home" shows a "Set up Cache" card. It gets Cache ready in four steps.

![Home with the Set up Cache card](shot:home-setup-card)

1. Tap "Choose a model" for the AI that answers your questions.
2. Tap "Get your area" for maps, directions and places near you.
3. Tap "Turn on weather" for forecasts and alerts.
4. Tap "Add a library" for Wikipedia, medical and survival references.

A tick shows on each row when it is done. When all four are done, the card goes away by itself.

Nothing downloads or switches on until you tap. You can do the steps in any order. Press and hold a row to open its part of this guide.

To hide the card, tap "Hide". Cache says "Set up Cache hidden. Bring it back in Edit Home." Tap "Undo" to bring it back at once, or use "Edit Home" later.

- If "Get your area" shows the region and its parts, the download is running. For example `Idaho · Map stopped at 80% · Places 40% · Off-road waiting. Tap to carry on`.
- If it says to tap to carry on, tap the row. A pop-up asks "Carry on with [region]?"

## Choose a model

The model is the AI that answers in "Ask". You pick it, and Cache runs it on your phone.

![The Models screen](shot:models-screen)

1. Tap the model name at the top of "Ask" and choose "Manage models". You can also go to ["Settings" > "Cache model and web search"](cache://settings/assistant) and tap the model row.
2. Look under "Recommended". Each card says how well it fits your phone: "Fits this phone", "May be tight on this phone" or "Too big for this phone".
3. Pick one that fits. If you're unsure, take the smallest.
4. Tap its download button, then "Download" in the pop-up.
5. When it finishes, tap the model under "On this phone". Its line says "Loading…", then "Active".

A model is about 3 to 5 GB.

- If you're on mobile data, the download waits for Wi-Fi. See Downloads, Wi-Fi and mobile data.
- If a model says "Not supported: Cache needs a model that can use tools", pick another.
- If there's no room, the pop-up is "Not enough space". Tap "Free up space".

## The search model

The search model is a small second model, 605 MB. Cache uses it to search by meaning in your libraries and places. It is not a chat model.

It comes with your first model. The download pop-up has the line "Search model (once, for searching by meaning)".

If its download stops:
1. Open the Models screen.
2. In the download bar, find "Search model: download stopped ([reason])".
3. Tap "Try again".

- If a library needs a different model, a search in it says "Meaning search needs the model [name]." Cache can't download that model. It searches by keywords instead.

## Unload or delete a model

Unloading frees the memory a model uses. Deleting frees its storage.

![The Models screen](shot:models-screen)

1. Open the Models screen.
2. Tap "Unload" next to the active model, or "Delete" next to one you don't use.
3. For a delete, confirm in the pop-up.

You can also unload from the model name at the top of "Ask".

## Find a model on Hugging Face

Use this when the model you want isn't under "Recommended".

![The Hugging Face search](shot:hf-search)

1. Open the Models screen and tap "Search Hugging Face".
2. Type a model name. Only single-file .gguf models are shown.
3. Tap a result to see its files and sizes. Each says whether it fits this phone.
4. Tap "Download" next to the file you want, then confirm.

- If a model needs a Hugging Face account, Cache can't download it. Get the file in a browser, then use Use a model file you already have.
- If it is marked "Not supported: Cache needs a model that can use tools", pick another.

## Use a model file you already have

You can copy a .gguf file from your phone into Cache.

![The Models screen](shot:models-screen)

1. Open the Models screen and tap "Choose a file".
2. Pick the .gguf file. Cache copies it into its models folder.
3. Tap the model under "On this phone" to load it.

If the model can't use tools, it is marked "Not supported: Cache needs a model that can use tools".

## Downloads, Wi-Fi and mobile data

Every big download in Cache asks you first in one pop-up. It covers models, regions and Library items.

![The download pop-up](shot:download-popup-new)

The pop-up shows each item's size and a storage bar, for example "103 GB free, 100.9 GB after". Tap "Download" to go ahead.

To allow mobile data for big downloads:
1. Go to ["Settings" > "Storage"](cache://settings/storage).
2. Turn on "Mobile data downloads".

Weather and alerts always update, on any connection.

- If you're on mobile data with that switch off, the pop-up offers "Wait for Wi-Fi". It is the default. The download starts when you're on Wi-Fi.
- If you want it now, tap "Download now".
- If it won't fit, the pop-up is "Not enough space". It says "[Name] needs [X]. You have [Y] to use; Cache keeps [Z] free for the phone." Tap "Free up space" to open "Storage". See Storage full in chapter 6.
- If a download stops, it picks up where it left off. See A download stopped in chapter 6.

## Download a region

A region lets maps, directions and place search work with no connection. One download has directions, map, places and off-road.

![The Regions sheet](shot:regions-sheet)

1. Open "Maps", tap "Layers", then ["Download a region"](cache://maps/regions). You can also go to ["Settings" > "Maps"](cache://settings/maps) and tap "Download another region".
2. Find your region. Each row shows its kind and size, for example `County · 19 MB`.
3. Tap its download button.
4. In the pop-up, check the size and storage, then tap "Download".

To get several at once:
1. Tap "Select" in the header.
2. Tick the regions.
3. Tap "Download N · size", then confirm.

If your area isn't listed, tap ["Draw your own area instead"](cache://maps/draw).

- If a row says `off-road shared with Idaho`, that state's off-road data is downloaded once for all its regions.
- If a size says "Size unknown", the catalogue has none for it.
- If the list won't load, connect once. It says "Couldn't read the list of regions. It needs a connection the first time."
- If you're on mobile data, see Downloads, Wi-Fi and mobile data.
- If a download stops, see A region's own page.

## The region download pop-up

One pop-up asks before every region download. Its title says which case it is.

- New region: "Download [region]?" It lists what you get, "Map, directions, places and off-road.", and the size.
- Several regions: "Download 3 regions?" with each size.
- A region partly here: "Carry on with [region]?" It says how much is to go and how much is already here.
- Off-road missing: "Add off-road to [region]?" It says what is already here and what is to download.
- Not enough room: "Not enough space". It says "[Name] needs [X]. You have [Y] to use; Cache keeps [Z] free for the phone." The buttons are "Cancel" and "Free up space".

Every pop-up also shows "Phone storage", with the free space before and after.

Tap "Download", "Carry on" or "Free up space" to go ahead, or "Cancel".

- If you're on mobile data with "Mobile data downloads" off, the pop-up offers "Wait for Wi-Fi" first. See Downloads, Wi-Fi and mobile data.
- If the state's off-road data is already here, the pop-up says only this area's terrain is new.

## Region download progress and off-road data

While a region downloads, its row shows each part and where it stands. A part that is ready already works.

![A region downloading, part by part](shot:region-row)

1. Open the "Regions" sheet and tap the "Local" tab.
2. Read the row. For example `Map 87% · Places 40% · Off-road waiting`.
3. Read the bar under it. For example `56% of 2.8 GB in all · now map`.

- The parts are map, directions, places and off-road.
- A stopped part reads `Map stopped at 80%`.
- If it stopped, tap "Carry on". See A region's own page.

## Off-road data in regions

Off-road routing needs a state's off-road data and the terrain heights of your area. Cache shares the state's data between regions.

![A region's own page](shot:region-detail)

- A state's off-road data downloads once, for all that state's regions.
- Each region adds its own terrain heights.
- The "Local" tab lists it under "Off-road data", with `used by` the regions that use it.

It says "Each state's off-road data is downloaded once and kept while a region that uses it is on this phone."

- If a region says `On this phone · off-road not added`, open it and tap "Add".

## A region's own page

Tap a region on the "Local" tab, or in "Settings" > "Maps", to open its page. It shows the region's total size and each part with its state.

1. Open the region. The parts are "Map", "Directions", "Places" and "Off-road".
2. Read each state: "Ready", a percentage with `to go`, waiting, or "Stopped".
3. Fix a part right there. A stopped part has "Carry on". A failed one has "Try again". Missing off-road says "Not on this phone", with "Add".

Below the parts, "Map layers in this region" lists each layer the same way.

To remove the region, tap "Delete [region]" at the bottom. The "Region options" menu is at the top right.

- If a part says "Couldn't finish", tap "Try again". If it keeps failing, remove the region and download it again.
- If you're offline, connect first.

## Press and hold a region

Press and hold a region for its quick menu. It is the same on the "Local" tab, in the Regions sheet and in "Settings" > "Maps".

1. Press and hold the region.
2. Choose "Carry on", "Check for update" or "Delete". A region with no off-road also has "Add off-road".

"Open" shows the region's page. Tapping the region does the same.

- "Delete" asks first. The pop-up says its map, directions, places and off-road data are removed. Parts another region uses stay.

## Update or remove a region

A region's update means newer map, directions or places data.

1. Press and hold the region on the "Local" tab.
2. Tap "Check for update".
3. Cache says it is checking. If something is newer, it updates.

To remove a region, press and hold it and tap "Delete", then confirm. It says "[region] deleted".

## Check for region updates

The "Updates" tab shows what has newer data. Updates use Wi-Fi unless you allow mobile data.

![The Updates tab of the Regions sheet](shot:regions-updates-tab)

1. Open the "Regions" sheet and tap the "Updates" tab.
2. Tap "Check for updates" to look again.
3. Tap "Update all" to get everything new.

The tab shows:
- "Road routing" and "Places": "Up to date", or a new build with its size.
- "Map": each region map with the date it was downloaded.

- While places update, search keeps using the old places until the new ones are complete.

## Add to your Library

The Library holds offline copies of Wikipedia, medical guides and survival manuals from Kiwix. They are free and work with no signal.

![Add to Library](shot:library-add)

1. [Open "Library" and tap "Add to Library"](cache://library/add).
2. Type in "Search the catalogue". You can narrow it with the language chip or a category chip such as "Medicine" or "Preparedness".
3. Under "Ready-made collections · free from Kiwix", tap the download button of the one you want.
4. In the pop-up, check the size and storage bar, then tap "Download".

When it finishes, Cache checks the file and adds it to your Library. Then it indexes it. The row says "Indexing". You can read straight away. Search inside it works when indexing ends.

Versions without pictures are much smaller.

- If you're on mobile data, the pop-up may offer "Wait for Wi-Fi".
- If there's no room, the pop-up is "Not enough space". Tap "Free up space".
- If indexing seems slow, see An index still building in chapter 6.

## Add your own library

A library is a set of passages Cache searches and cites. You add one from a file or a link someone gave you.

![Add to Library](shot:library-add)

1. [Open "Library" and tap "Add to Library"](cache://library/add).
2. Tap "Your own library".
3. Choose "From a file on this phone" and pick the file. Or choose "From a download link", paste an https:// link and tap "Download".
4. Watch the card. It shows each step. "Cancel" stops it.
5. When it's done, the library appears in your Library.

A .zim file you already have is added the same way.

- If Cache closes before it finishes, the unfinished part is cleared. Add the library again.
- If you add the same link again, a cut-off download continues.
- If it asks "Choose its settings file", tap "Choose file" and pick cache-library.json.

## Update a library you already have

Adding a copy of a library that's already here replaces it.

1. Add the new copy as in Add your own library.
2. When Cache asks, tap "Update".

The new copy replaces the whole library once it opens.

- If the new copy can't be opened, the old one is kept.

## Make your own library

A blank template shows you how to build a library with your own tools.

![Your own library](shot:library-own)

1. [Open "Library" and tap "Add to Library"](cache://library/add).
2. Tap "Your own library".
3. Tap "Get a blank library template".

Cache says "Template saved. Its README says how to fill it."

A library searched by meaning uses the search model. Without it, Cache searches by keywords.

## Turn on weather and alerts

This switches on a forecast, weather alerts and wildfires for where you are, in one tap.

![The Weather screen](shot:weather)

1. On "Home", find the "Weather and alerts" card. You can also open "Weather" from "Modules".
2. Tap "Turn on weather".
3. If Cache asks "Use your location?", tap "Continue" and allow it.
4. Wait for the short message that says how the update went.

This switches on "Weather forecast", "Weather alerts" and "Wildfires". The first time, Cache asks to send notifications.

- If you're offline, Cache shows the last data and its age.
- If location can't be found, see Pick a place for weather.

## Pick a place for weather

Use this if you'd rather not share your location, or it can't be found.

![Choose a place for weather](shot:weather-choose-place)

1. On the "Weather" screen, tap "Choose a place instead".
2. In "Find a town or place", type a town and tap it.

Cache watches that place and switches on the same three sources.

To keep a place for good, add it to the Places notebook. Each place has its own "Weather and alerts" switch.

## Add more weather sources

More sources are in ["Settings" > "Weather and alerts"](cache://settings/weather). Featured ones come first. The rest are under "More sources", with a count such as "9 more".

![The Weather and alerts settings](shot:settings-weather)

1. Find the source.
2. Turn on its switch.

- If it needs a free key, the row has a "Get key" button.

You choose which alerts pop up in ["Settings" > "Notifications"](cache://settings/notifications).

## Let Cache use your location

Cache uses your location for the map, directions, nearby places, and weather where you are. It does this whenever your phone allows it.

![The + menu in Ask](shot:ask-plus-menu)

To turn it off or on:
1. Go to ["Settings" > "Cache model and web search"](cache://settings/assistant). You can also tap the + button left of the box in "Ask".
2. Use the "Use my location" switch.

Cache doesn't ask for location in "Ask" and has no location button there.

- If you refuse, Cache keeps working. Chat goes on without your location, and you can choose a place by hand for weather.
- If the phone blocks location, see If location is blocked.

## If location is blocked

When your phone blocks location, "Use my location" says why.

![The Use my location row, blocked](shot:settings-location-blocked)

- "Blocked in the phone's settings": location is blocked for Cache.
- "The phone's location is switched off": the phone's own location is off.

To fix it:
1. In "Settings", tap "Phone settings" on the "Use my location" row. In "Ask", tap "Open the phone's settings" in the + menu.
2. Allow location for Cache, or turn the phone's location on.

## Location on the map

The map has its own location controls.

1. Open "Maps" and tap the locate button ("Find me").
2. When Cache asks "Use your location?", tap "Continue".
3. Allow it in your phone's prompt.

"Show my position" in "Maps" > "Layers" turns your dot on or off. When it is off, Cache doesn't read your position and forgets the last one.

"Where I am" is the first row of the Places notebook ("Follows the phone"). Its weather switch decides whether Cache keeps weather for where you are.
