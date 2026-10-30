# 1. Getting started

## Set up Cache

On a fresh install, "Home" shows a "Set up Cache" card. It lists four things that make Cache useful. Each one works right from the card.

1. "Choose a model": the AI that answers your questions, on this phone. Tap the row.
2. "Get your area": maps, directions and places for where you live. Tap the row.
3. "Turn on weather": forecasts and alerts for your places. Tap the row.
4. "Add a library": Wikipedia, medical and survival references. Tap the row.

A tick shows on each row when it is done. While "Get your area" is still downloading, its row says "[region] · Not offline yet" with a percentage. If the download stopped, for example because Cache was closed, the row says "[region] · Stopped. Tap to carry on". Tap the row and Cache says "Carrying on with [region]". On mobile data with "Mobile data downloads" off, that message has a "Download anyway" button. When all four are done, the card goes away by itself. Before that, "Edit Home" can hide it like any other block on Home.

You can do the four things in any order. Each one is also described on its own in this guide:
- the model: see Choose a model;
- the area: see Download a region;
- weather: see Turn on weather and alerts;
- the library: see Add to your Library.

Nothing is downloaded or switched on until you tap. Every download asks you first, in one pop-up that shows what it will use. See the section Downloads, Wi-Fi and mobile data.

## Choose a model

Cache's assistant runs a language model on your phone. Nothing is downloaded for you: you pick the model. You need one before "Ask" can answer.

To open the Models screen:
- tap the model name at the top of "Ask" and choose "Manage models", or
- tap "Get a model" or "Choose a model" in an empty chat, or
- go to ["Settings" > "Cache model and web search"](cache://settings/assistant) and tap the model row.

On the Models screen:
1. Look under "Recommended". Each card shows the model's size and how well it fits your phone: "Fits this phone", "May be tight on this phone" or "Too big for this phone".
2. Pick one that fits. If you are unsure, take the smallest one ("Small and quick.").
3. Tap its download button. A pop-up asks you to confirm. It shows the size and a storage bar.
4. Tap "Download". The download bar shows how much has arrived.
5. When it is done, the model is listed under "On this phone". Tap it to load it. Its line says "Loading…", then "Active".

The first time you download a model, the same pop-up has one more line: "Search model (once, for searching by meaning)", 605 MB. Cache uses this small second model to search by meaning in your libraries and places. It is not a chat model. You do nothing extra for it.

If you already have a chat model but the search model is missing, or its download stopped, open the Models screen. Under "On this phone" there is a line "Meaning search needs the search model." with a "Get it" button. Tap "Get it" to download it.

Models are large, about 3 to 5 GB. On mobile data they wait for Wi-Fi unless you allow mobile data. See the section Downloads, Wi-Fi and mobile data.

Cache needs a model that can use tools. A model that cannot is marked "Not supported: Cache needs a model that can use tools".

To free the memory the model uses, tap "Unload" next to the active model, or use the model name at the top of "Ask". To delete a model you are not using, tap "Delete" and confirm.

## Find a model on Hugging Face or choose a file

If you want a model that is not in the "Recommended" list, you can search Hugging Face or copy a file you already have.

To search Hugging Face:
1. Open the Models screen: tap the model name at the top of "Ask" and choose "Manage models", or go to ["Settings" > "Cache model and web search"](cache://settings/assistant) and tap the model row.
2. Tap "Search Hugging Face". The "Find a model" screen opens.
3. Type a model name and search. Only models that come as a single .gguf file are shown.
4. Tap a result to see its files. Each file shows its size and whether it fits this phone.
5. Tap "Download" next to the file you want, then confirm in the pop-up.

Some models need a Hugging Face account. Cache does not sign in to Hugging Face, so it cannot download those. Get the file in a browser instead, then use "Choose a file".

To use a file you already have on the phone:
1. Open the Models screen.
2. Tap "Choose a file" and pick the .gguf file.
3. Cache copies it into its own models folder. The progress shows while it copies.
4. Tap the model under "On this phone" to load it.

Whichever way you get it, the model must be able to use tools. If it cannot, it is marked "Not supported: Cache needs a model that can use tools".

## Downloads, Wi-Fi and mobile data

Every download in Cache asks you first, in the same pop-up. This covers models, regions, Library items and anything else big.

The pop-up shows:
- the items and their sizes;
- a storage bar, for example "103 GB free, 100.9 GB after".

Mobile data:
1. Big downloads use Wi-Fi only, unless you turn on "Mobile data downloads" in ["Settings" > "Storage"](cache://settings/storage).
2. On mobile data with that switch off, the pop-up says so and offers "Wait for Wi-Fi". This is the default. The download starts by itself when you are on Wi-Fi.
3. To go ahead on mobile data this once, tap "Download now".
4. To allow mobile data for all big downloads, turn on "Mobile data downloads".

Weather and alerts always update, on any connection. They are small.

Room on the phone: Cache never uses the last part of your storage. It keeps 10% of total storage free, but never less than 5 GB and never more than 20 GB. If a download will not fit, the pop-up says how much more is needed, for example "Needs 28 GB more. Cache always leaves 20 GB for the phone." Its button becomes "Free up space". Tap it to open "Storage" and remove things you no longer need.

You can leave Cache while a download runs. A stopped download picks up where it left off.

## Download a region

A region download lets maps, directions and place search work without a connection. Each region has routing, map, places and off-road, all in one download.

1. Open "Maps" and tap "Layers", then "Download a region". (Or go to ["Settings" > "Maps" > "Regions"](cache://maps/regions).)
2. The "Regions" sheet opens on the "Downloads" tab, with one list of regions. A search box ("Search regions") finds a region by name. You can also browse by country under "Countries".
3. Each row shows the name and size. A region already on the phone shows an "On this phone" badge.
4. To get one region, tap its download button.
5. To get several, tap "Select" in the header, tick the regions, then tap "Download N", where N is the number you ticked. The button also shows the total size.
6. A pop-up lists the regions with their sizes and a storage bar. If the state's off-road data is already on the phone, it has a line "Off-road" with "Already on this phone". Tap "Download".

If your area is not in the list, tap ["Draw your own area instead"](cache://maps/draw) at the bottom and drag on the map to mark it.

A region that cannot be downloaded shows a short reason on its row in place of the download button. For example, "This region is too big to download the map in one go." or "This region has no outline yet."

The list of regions needs a connection the first time. After that it works offline. While it downloads, the row shows where each part stands. See the section Region download progress and off-road data.

On mobile data with "Mobile data downloads" off, the pop-up offers "Wait for Wi-Fi". If there is not enough room, the button becomes "Free up space". See the section Downloads, Wi-Fi and mobile data.

## Region download progress and off-road data

A region is more than one thing to download. This section says how to read a region's row while it downloads, and how off-road data is shared.

How a region downloads: Cache downloads from where the phone is outwards. Each part works as soon as it is saved, so a part that is ready can be used while the others are still downloading. While it downloads, the region's row has one line with each part and where it stands: "Map", "Directions", "Places" and "Off-road". Each part says ready, a percentage, waiting, stopped or paused. For example: Map ready · Directions 40% · Off-road waiting.

Off-road data: each region downloads the terrain heights for its own area. The rest of the off-road data for a state is downloaded once and shared by all that state's regions. If it is already on the phone, the size line says "Already on this phone", then "terrain heights for this region about [size]".

A stopped download picks up where it left off. A download that stopped because Cache was closed carries on when you tap "Get your area" in the Set up card, or the region's update button.

On the "Regions" sheet the "Local" tab shows the same line for every region that is still downloading. To start a download, see the section Download a region.

## Keep your regions up to date

Downloaded regions are listed on the "Regions" sheet.

To open it: ["Maps" > "Layers" > "Download a region"](cache://maps/regions), or "Settings" > "Maps" > "Regions".

The sheet has three tabs: "Downloads", "Local" and "Updates". The "Local" tab lists every region on this phone, largest first, with its size and the parts it has (for example road routing, map and places). A region that is still downloading shows one line for its parts: "Map", "Directions", "Places" and "Off-road", each ready, a percentage, waiting, stopped or paused. A part that is ready already works. Cache downloads from where the phone is outwards.
- To bring one region up to date, tap its update button. A download that stopped carries on with the same button.
- To remove one, tap its delete button. A pop-up shows what it frees. Tap "Delete" to confirm. Parts that another region also uses stay on the phone. A state's off-road data stays while a region that uses it is on the phone.
- If a region says "Places not downloaded", it was downloaded before places were part of regions. Update it to add them.

The "Updates" tab shows what has newer data:
- "Road routing" and "Places" each show "Up to date", or that a new build is available with its size.
- "Map" lists each region map with the date it was downloaded.
- Tap "Update all" to get everything that is new.
- Tap "Check for updates" to look again.

Updates need a connection and, by default, Wi-Fi. While places update, search keeps using the old places until the new ones are complete.

## Add to your Library

The Library holds offline copies of Wikipedia, medical guides, survival manuals and other reference works. They come from the Kiwix catalogue and are free. Once downloaded they work with no signal.

1. [Open "Library" and tap "Add to Library"](cache://library/add). One screen opens.
2. To find something, type in "Search the catalogue". You can narrow the list with the language chip ("All languages") and category chips such as "Medicine" or "Preparedness".
3. Under "Ready-made collections · free from Kiwix", each collection has its own download button and its size.
4. Tap the download button. A pop-up shows the name, the size and a storage bar.
5. Tap "Download". If you are on mobile data it may offer "Wait for Wi-Fi" instead. If there is no room, the button says "Free up space".

When the download finishes, Cache checks the file and adds it to your Library. Then it indexes it in the background, which can take a while for a large work. While it runs the row says "Indexing". You can read the pages straight away. Text search inside it works when indexing is done.

Many works come in several versions. Versions without pictures are much smaller.

To add your own library or a ZIM file you already have, use "Your own library" on the same screen. See the section Add your own library.

## Add your own library

A library is a collection of passages that Cache searches and cites when it answers. Libraries are made outside the app. You add one from a file or from a download link someone gives you.

1. [Open "Library" and tap "Add to Library"](cache://library/add).
2. Tap "Your own library" ("From a file or a download link").
3. Choose "From a file on this phone" and pick the file, or choose "From a download link", paste the link (it must start with https://) and tap "Download". A .zim file you already have can be added the same way.
4. A card shows each step: downloading, unpacking, checking, building the search index, and putting it in place. "Cancel" stops it.
5. When it is done, the library appears in your Library list.

Building the search index can take a while for a large library. If Cache is closed before the add finishes, the unfinished part is cleared the next time Cache starts. Add the library again. Adding the same link again continues a download that was cut off.

If you add a copy of a library that is already on the phone, Cache asks whether to update it. Tap "Update". A newer copy replaces the whole library once it opens. If the new copy cannot be opened, the old one is kept.

If a library came without its settings file and Cache cannot work them out, it asks "Choose its settings file". Tap "Choose file" and pick its cache-library.json.

To start your own, tap "Get a blank library template" inside "Your own library". Cache says "Template saved. Its README says how to fill it."

A library searched by meaning uses the search model. Without it, Cache searches the library by keywords.

## Turn on weather and alerts

Nothing is switched on until you turn it on. The quickest way does it in one tap.

1. On "Home", find the "Weather and alerts" card, or open "Weather" from "Modules".
2. Tap "Turn on weather". (On a fresh install it is also a row of the "Set up Cache" card.)
3. This switches on "Weather forecast", "Weather alerts" and "Wildfires" and watches where you are.
4. If Cache does not know where you are yet, it asks "Use your location?". Tap "Continue" and allow it.
5. Cache then updates. A short message says how it went.

If you would rather not share your location, or it cannot be found:
1. On the "Weather" screen, tap "Choose a place instead".
2. In "Find a town or place", type a town and tap it.
3. Cache watches that place, switches on the same three sources and updates.

To keep a place for good, add it to the Places notebook. Each place there has its own "Weather and alerts" switch. "Where I am" is its first row, labelled "Follows the phone".

More sources are in ["Settings" > "Weather and alerts"](cache://settings/weather). The featured ones are listed first. The rest are under "More sources", with a count such as "9 more". Some need a free key; the row has a "Get key" button. Turn each source on with its switch.

The first time something is switched on, Cache asks to send you notifications. You choose which alerts pop up in ["Settings" > "Notifications"](cache://settings/notifications).

Weather and alerts need a connection to update. When you are offline, Cache shows the last data it got and how old it is.

## Let Cache use your location

Cache uses your location to show you on the map, give directions from where you are, answer questions about places near you, and keep weather and alerts for where you are. It uses your location whenever your phone allows it.

The switch is called "Use my location". It is in two places, and it is the same switch:
- ["Settings" > "Cache model and web search"](cache://settings/assistant): the row "Use my location".
- "Ask": tap the + button to the left of the box where you type, then use "Use my location".

To stop Cache using your location for your questions, turn the switch off. Cache does not ask for location in "Ask" and shows no location button there.

If the phone has blocked location for Cache, it says "Blocked in the phone's settings". If the phone's own location is off, it says "The phone's location is switched off". In "Settings" the row then shows a "Phone settings" button instead of the switch. In the + menu in "Ask" the switch is greyed out and there is an "Open the phone's settings" button. Use it to allow location.

On the map:
1. Open "Maps" and tap the locate button ("Find me").
2. Cache explains why it asks ("Use your location?"). Tap "Continue".
3. Your phone asks for permission. Allow it while using the app.

If you refuse, Cache keeps working. Chat continues without your location, and you can choose a place by hand for weather. Cache asks only for permission while you use the app.

The map has its own switch, "Show my position", in "Maps" > "Layers". When it is off, Cache does not read your position at all and forgets the last one.

"Where I am" is the first row of the Places notebook, labelled "Follows the phone". It uses your location. Its weather switch decides whether Cache keeps weather and alerts for where you are.
