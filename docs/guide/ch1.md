# 1. Getting started

## Set up Cache

On a fresh install, "Home" shows a "Set up Cache" card. It gets Cache ready in four steps.

1. Tap "Choose a model" for the AI that answers your questions.
2. Tap "Get your area" for maps, directions and places near you.
3. Tap "Turn on weather" for forecasts and alerts.
4. Tap "Add a library" for Wikipedia, medical and survival references.

A tick shows on each row when it is done. When all four are done, the card goes away by itself. "Edit Home" can also hide it.

Nothing downloads or switches on until you tap. You can do the steps in any order.

- If "Get your area" says "[region] · Not offline yet", the download is still running.
- If it says "[region] · Stopped. Tap to carry on", tap the row. Cache says "Carrying on with [region]".
- If you're on mobile data with "Mobile data downloads" off, that message has a "Download anyway" button.

## Choose a model

The model is the AI that answers in "Ask". You pick it, and Cache runs it on your phone.

1. Tap the model name at the top of "Ask" and choose "Manage models". You can also go to ["Settings" > "Cache model and web search"](cache://settings/assistant) and tap the model row.
2. Look under "Recommended". Each card says how well it fits your phone: "Fits this phone", "May be tight on this phone" or "Too big for this phone".
3. Pick one that fits. If you're unsure, take the smallest.
4. Tap its download button, then "Download" in the pop-up.
5. When it finishes, tap the model under "On this phone". Its line says "Loading…", then "Active".

A model is about 3 to 5 GB.

- If you're on mobile data, the download waits for Wi-Fi. See Downloads, Wi-Fi and mobile data.
- If a model says "Not supported: Cache needs a model that can use tools", pick another.
- If there's no room, the pop-up button says "Free up space".

## The search model

The search model is a small second model, 605 MB. Cache uses it to search by meaning in your libraries and places. It is not a chat model.

It comes with your first model. The download pop-up has the line "Search model (once, for searching by meaning)".

If it is missing or its download stopped:
1. Open the Models screen.
2. Under "On this phone", find "Meaning search needs the search model."
3. Tap "Get it".

## Unload or delete a model

Unloading frees the memory a model uses. Deleting frees its storage.

1. Open the Models screen.
2. Tap "Unload" next to the active model, or "Delete" next to one you don't use.
3. For a delete, confirm in the pop-up.

You can also unload from the model name at the top of "Ask".

## Find a model on Hugging Face

Use this when the model you want isn't under "Recommended".

1. Open the Models screen and tap "Search Hugging Face".
2. Type a model name. Only single-file .gguf models are shown.
3. Tap a result to see its files and sizes. Each says whether it fits this phone.
4. Tap "Download" next to the file you want, then confirm.

- If a model needs a Hugging Face account, Cache can't download it. Get the file in a browser, then use Use a model file you already have.
- If it is marked "Not supported: Cache needs a model that can use tools", pick another.

## Use a model file you already have

You can copy a .gguf file from your phone into Cache.

1. Open the Models screen and tap "Choose a file".
2. Pick the .gguf file. Cache copies it into its models folder.
3. Tap the model under "On this phone" to load it.

If the model can't use tools, it is marked "Not supported: Cache needs a model that can use tools".

## Downloads, Wi-Fi and mobile data

Every big download in Cache asks you first in one pop-up. It covers models, regions and Library items.

The pop-up shows each item's size and a storage bar, for example "103 GB free, 100.9 GB after". Tap "Download" to go ahead.

To allow mobile data for big downloads:
1. Go to ["Settings" > "Storage"](cache://settings/storage).
2. Turn on "Mobile data downloads".

Weather and alerts always update, on any connection.

- If you're on mobile data with that switch off, the pop-up offers "Wait for Wi-Fi". It is the default. The download starts when you're on Wi-Fi.
- If you want it now, tap "Download now".
- If it won't fit, the button says "Free up space". Tap it to open "Storage". See Storage full in chapter 6.
- If a download stops, it picks up where it left off. See A download stopped in chapter 6.

## Download a region

A region lets maps, directions and place search work with no connection. One download has routing, map, places and off-road.

1. Open "Maps", tap "Layers", then "Download a region". You can also go to ["Settings" > "Maps" > "Regions"](cache://maps/regions).
2. On the "Downloads" tab, find your region. Use "Search regions" or browse "Countries".
3. Tap its download button. A region already here shows "On this phone".
4. In the pop-up, check the sizes and storage bar, then tap "Download".

To get several at once:
1. Tap "Select" in the header.
2. Tick the regions.
3. Tap "Download N", then confirm.

If your area isn't listed, tap ["Draw your own area instead"](cache://maps/draw).

- If a region shows a short reason instead of a button, it can't be downloaded. For example, "This region is too big to download the map in one go." or "This region has no outline yet."
- If the list won't load, connect once. After that it works offline.
- If you're on mobile data, the pop-up offers "Wait for Wi-Fi". See Downloads, Wi-Fi and mobile data.
- If there's no room, the button says "Free up space".

## Region download progress and off-road data

While a region downloads, its row shows each part and where it stands. Parts you can use are ready before the rest.

The row lists "Map", "Directions", "Places" and "Off-road". Each says ready, a percentage, waiting, stopped or paused. For example: Map ready · Directions 40% · Off-road waiting.

- Cache downloads from where the phone is outwards.
- A part that says ready already works.
- The "Local" tab shows the same line for every region still downloading.

If a download stopped, tap the region's update button. If it stopped because Cache was closed, you can also tap "Get your area" in the Set up card. See A download stopped in chapter 6.

## Off-road data in regions

Off-road routing needs terrain heights and a state's off-road pack. Cache shares the pack between regions.

- Each region downloads its own terrain heights.
- A state's off-road pack downloads once, for all that state's regions.
- If the pack is already here, the pop-up has an "Off-road" line with "Already on this phone". The size line adds "terrain heights for this region about [size]".

A state's pack stays while any region that uses it is on the phone.

## Update or remove a region

Downloaded regions are on the "Regions" sheet, "Local" tab. Open it from ["Maps" > "Layers" > "Download a region"](cache://maps/regions).

The tab lists regions largest first, with size and parts.

- To update one, tap its update button.
- To remove one, tap its delete button, then "Delete". The pop-up shows what it frees.
- If a region says "Places not downloaded", update it to add places.

If you remove a region, parts another region uses stay on the phone.

## Check for region updates

The "Updates" tab shows what has newer data. Updates use Wi-Fi unless you allow mobile data.

1. Open the "Regions" sheet and tap the "Updates" tab.
2. Tap "Check for updates" to look again.
3. Tap "Update all" to get everything new.

The tab shows:
- "Road routing" and "Places": "Up to date", or a new build with its size.
- "Map": each region map and the date it was downloaded.

While places update, search keeps using the old places until the new ones are complete.

## Add to your Library

The Library holds offline copies of Wikipedia, medical guides and survival manuals from Kiwix. They are free and work with no signal.

1. [Open "Library" and tap "Add to Library"](cache://library/add).
2. Type in "Search the catalogue". You can narrow it with the language chip or a category chip such as "Medicine" or "Preparedness".
3. Under "Ready-made collections · free from Kiwix", tap the download button of the one you want.
4. In the pop-up, check the size and storage bar, then tap "Download".

When it finishes, Cache checks the file and adds it to your Library. Then it indexes it. The row says "Indexing". You can read straight away. Search inside it works when indexing ends.

Versions without pictures are much smaller.

- If you're on mobile data, the pop-up may offer "Wait for Wi-Fi".
- If there's no room, the button says "Free up space".
- If indexing seems slow, see An index still building in chapter 6.

## Add your own library

A library is a set of passages Cache searches and cites. You add one from a file or a link someone gave you.

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

1. [Open "Library" and tap "Add to Library"](cache://library/add).
2. Tap "Your own library".
3. Tap "Get a blank library template".

Cache says "Template saved. Its README says how to fill it."

A library searched by meaning uses the search model. Without it, Cache searches by keywords.

## Turn on weather and alerts

This switches on a forecast, weather alerts and wildfires for where you are, in one tap.

1. On "Home", find the "Weather and alerts" card. You can also open "Weather" from "Modules".
2. Tap "Turn on weather".
3. If Cache asks "Use your location?", tap "Continue" and allow it.
4. Wait for the short message that says how the update went.

This switches on "Weather forecast", "Weather alerts" and "Wildfires". The first time, Cache asks to send notifications.

- If you're offline, Cache shows the last data and its age.
- If location can't be found, see Pick a place for weather.

## Pick a place for weather

Use this if you'd rather not share your location, or it can't be found.

1. On the "Weather" screen, tap "Choose a place instead".
2. In "Find a town or place", type a town and tap it.

Cache watches that place and switches on the same three sources.

To keep a place for good, add it to the Places notebook. Each place has its own "Weather and alerts" switch.

## Add more weather sources

More sources are in ["Settings" > "Weather and alerts"](cache://settings/weather). Featured ones come first. The rest are under "More sources", with a count such as "9 more".

1. Find the source.
2. Turn on its switch.

- If it needs a free key, the row has a "Get key" button.

You choose which alerts pop up in ["Settings" > "Notifications"](cache://settings/notifications).

## Let Cache use your location

Cache uses your location for the map, directions, nearby places, and weather where you are. It does this whenever your phone allows it.

To turn it off or on:
1. Go to ["Settings" > "Cache model and web search"](cache://settings/assistant). You can also tap the + button left of the box in "Ask".
2. Use the "Use my location" switch.

Cache doesn't ask for location in "Ask" and has no location button there.

- If you refuse, Cache keeps working. Chat goes on without your location, and you can choose a place by hand for weather.
- If the phone blocks location, see If location is blocked.

## If location is blocked

When your phone blocks location, "Use my location" says why.

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
