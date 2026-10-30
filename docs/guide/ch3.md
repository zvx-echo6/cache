# 3. Settings, page by page

## Opening Settings

Settings has eight rows, each with a one-line status.

![The Settings page](shot:settings)

1. Tap the gear at the top right of "Home", or open "Settings" from "Modules".
2. Pick a row:
   - "Cache model and web search"
   - "Maps"
   - "Weather and alerts"
   - "Notifications"
   - "Storage"
   - "Sharing and sync"
   - "Appearance"
   - "Credits and licences"

The status lines show the state without opening the row. For example, "Storage" shows how much Cache uses and what is free.

There is no Library or Videos page here. Open them from "Modules".

- If a row says "Not available", that part of Cache couldn't start. Restart Cache. See When part of Cache is not available in chapter 6.

## Cache model and web search

This page sets your model, web search, location and chats.

![Cache model and web search](shot:settings-assistant)

1. Go to ["Settings" > "Cache model and web search"](cache://settings/assistant).
2. Use a row:
   - "Model": tap it to open the Models screen. It shows the loaded model and its size, or "No model chosen".
   - "Search service": tap "Set up" (or "Change") to add, replace or remove the Kagi key.
   - "Search the web when online": lets the assistant search the web. It needs a search service first.
   - "Use my location": see below.

To get a Kagi key, see Web search with Kagi in chapter 4.

## Use my location in Settings

"Use my location" is the same switch as in the + menu in "Ask". The line under it says "Cache finds things near you".

- If the phone blocks location, the row says "Blocked in the phone's settings" or "The phone's location is switched off". Tap "Phone settings".

## Conversations in Settings

On ["Settings" > "Cache model and web search"](cache://settings/assistant), "Conversations" holds your chats.

- "Saved conversations": opens the list of chats.
- "Reported answers": your reports, each with "Share" and "Remove", and "Share all reports".
- "Delete all conversations": asks first, then removes every chat. This can't be undone.

## Maps

This page lists your regions and your map layers.

![Settings, Maps](shot:settings-maps)

1. Go to ["Settings" > "Maps"](cache://settings/maps).
2. Under "Regions", each region on the phone has one row. A downloading region shows its parts, for example `Map stopped at 80% · Places 40% · Off-road waiting`, with "Carry on".
3. Tap a region to open its page. Press and hold it for "Carry on", "Check for update" and "Delete".
4. Tap "Download another region" to get more ("Directions, map, places and off-road for an area").
5. Under "Layers", tap "Layers" for the full list. It shows how many layers exist, how many are on, and the space they use.
6. Tap "Advanced" for layer definitions. Most people never need it.

- If nothing is downloaded, the page says "Nothing downloaded".
- For the region page and the pop-up, see A region's own page in chapter 1.

## Layer definitions (Advanced)

A layer definition says how a map layer is drawn and where it comes from.

![Layer definitions](shot:settings-maps-advanced)

1. Go to ["Settings" > "Maps"](cache://settings/maps) and tap "Advanced" ("Layer definitions and source addresses").
2. Use the page:
   - the switch hides or shows a definition;
   - the edit button changes one, for example to use your own map server;
   - "Add a layer definition" adds a new layer, written as JSON. Tap "Save".
   - "Remove my version of this definition" puts a built-in one back.

- If a layer stops working after an edit, remove your version.

## Weather and alerts

This page turns weather sources on and off.

![The Weather and alerts settings](shot:settings-weather)

1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather).
2. Check the top line, for example "Updated 1 hour ago". Tap the small round button next to it to refresh. If data is old, the line warns, for example "Updated 3 days ago".
3. Under it, find a source. Featured ones come first, such as "Weather forecast", "Weather alerts", "Wildfires" and "Satellite fire detections near the place (NASA FIRMS)".
4. Turn its switch on or off.

Each row says what the source gives and who provides it. Tap a row to open the source's page. It has "Use this source".

The rest are under "More sources", with a count such as "9 more". Open it for a search box and sources such as earthquakes, river levels, avalanche danger, road conditions and space weather. Its bottom has "Add sources from a link" and "Catalogues in use".

- If the row has a "Get key" button, the source needs a free key. See Keys for data sources.
- If the list says "No sources downloaded yet. Connect to the internet and they load by themselves.", connect and come back.

Which places the data covers is set in the Places notebook (chapter 5).

## Keys for data sources

Some sources need your own free key from the provider. The key goes on the source's row.

![The key sheet](shot:key-sheet)

1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather) and find the source.
2. Tap "Get key" on its row.
3. Tap "Get a key from [provider]" and follow their steps.
4. Copy the key, come back, and paste it.
5. Tap "Check and save".

Cache checks the key with one real download. If it works, the key is saved and the source turns on.

- If it fails, the sheet says why and nothing is saved.

Keys stay on this phone, in secure storage. They are never shown again and are not shared to your other devices. For where to get each key, see chapter 4.

## Replace or remove a key

1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather).
2. Tap the source's row to open its page.
3. Tap "Replace" for a new key, or "Remove the key".

![A source's page](shot:source-page)

- Removing a key turns off every source that uses it.

## Add sources from a link

Other people can publish lists of data sources, called catalogues. You can add one by its link.

![Add sources from a link](shot:add-catalogue)

1. Go to ["Settings" > "Weather and alerts" > "More sources"](cache://settings/weather).
2. At the bottom, tap "Add sources from a link".
3. Paste the link and tap "Check this link". Nothing is added yet.
4. Read the card: who publishes it, how many sources it adds, and any it left out.
5. Tap "Add these sources", or "Cancel".

New sources stay off until you switch them on. Only add links from people you trust.

## Manage catalogues

"Catalogues in use" is at the bottom of the "More sources" list. It lists every catalogue on the phone.

- Tap "Remove" on one you added to take its sources off.
- The main catalogue has "Address" instead, to change where it comes from.
- Tap "Check for updates" to download every catalogue again. Cache says "Sources are up to date" or what went wrong.

## Notifications

This page decides which alerts pop up.

![The Notifications page](shot:settings-notifications)

1. Go to ["Settings" > "Notifications"](cache://settings/notifications).
2. Under "Pop up for", choose one:
   - "Serious only": evacuations, severe warnings, and fires within 10 mi. This is the default.
   - "All alerts": adds watches and advisories.
   - "None": nothing pops up.
- A place set to "Custom for this place" overrides this. See Alerts for a place in chapter 5.

Every alert is listed in "Weather" either way.

- If you choose "None", Cache asks "No pop-ups at all?". It won't interrupt you, even for an evacuation order. Tap "Turn off" or "Keep pop-ups".
- If you refused notifications, allow them for Cache in your phone's settings.

## Quiet hours

Quiet hours make alerts arrive silently. Serious ones still ring.

![Quiet hours](shot:quiet-hours)

1. Go to ["Settings" > "Notifications" > "Quiet hours"](cache://settings/notifications).
2. Turn on the "Quiet hours" switch.
3. Tap "From" and choose the start.
4. Tap "To" and choose the end.

Quiet hours don't change what "Weather" lists.

## Storage

This page shows what Cache uses and lets you free space.

![The Storage page](shot:settings-storage)

1. Go to ["Settings" > "Storage"](cache://settings/storage).
2. Read the usage bar and the line such as "118 GB used by Cache · 103 GB free on the phone".
3. Open a row to see its items: "Library", "Models", "Regions", "Notebooks" or "Videos and weather".
4. Remove an item. A pop-up shows what it frees. Confirm.

The page also has "Clean up", "Mobile data downloads" and "Kept free for the phone". Each has its own section below.

- If a download won't fit, the "Not enough space" pop-up has "Free up space". It opens this page.

## Clean up

"Clean up" removes unfinished downloads, damaged files and temporary files. It never touches what you saved.

![The Storage page](shot:settings-storage)

1. Go to ["Settings" > "Storage"](cache://settings/storage).
2. Tap "Clean up". It shows how much it will free.

- If there's nothing to remove, it says "Nothing to clean up".
- If a download is running, wait for it to finish first.

## Off-road data in Storage

Open "Regions" in ["Settings" > "Storage"](cache://settings/storage) to see an "Off-road data" group. It has a row for each state, with its size and `used by` the regions that use it. It says "Downloading" while it runs.

![Storage, Regions](shot:storage-regions)

A note explains: "Each state's off-road data is downloaded once and kept while a region that uses it is on this phone."

## Mobile data downloads

This switch decides whether big downloads may use mobile data.

![The Storage page](shot:settings-storage)

1. Go to ["Settings" > "Storage"](cache://settings/storage).
2. Find "Mobile data downloads".
3. Turn it on to allow mobile data. Off is the start setting.

It covers models, Library items, regions, videos, libraries from a link, and sharing. Weather and alerts always update, on any connection. Changes apply at once, even to a download already running.

- If it's off and you're on mobile data, the pop-up offers "Wait for Wi-Fi". Tap "Download now" to go ahead once.

## Room kept free for the phone

Cache never uses the last part of your storage, so the phone keeps working. You can't change this.

The row "Kept free for the phone" shows "10% of storage, 5 to 20 GB" and the current amount.

- It keeps 10% of total storage free, never less than 5 GB and never more than 20 GB.
- On iPhone, Cache also stays within what iOS says is available. The stricter limit wins.

- If a download won't fit, the pop-up is titled "Not enough space". It says "[Name] needs [X]. You have [Y] to use; Cache keeps [Z] free for the phone." Tap "Free up space".

## Sharing and sync: set up and link devices

Sharing keeps your own Cache devices the same. They talk to each other directly.

![Sharing and sync](shot:settings-sharing)

1. On each device, go to ["Settings" > "Sharing and sync"](cache://settings/sharing).
2. Tap "Set up sharing".
3. On the first device, tap "Show my link code". It works once, for 15 minutes.
4. Tap "Copy code" and get the text to the other device.
5. On the other device, tap "Enter a link code", then "Paste", then "Link".

Cache names the other device, for example "Linked with Android phone". To rename this device, tap its name under "This device".

Under "Linked devices", each device shows whether it is connected directly or through a relay. To stop one, tap it, then "Unlink". Files already here stay.

- If a device shows "Not reachable", open Cache on it.

## Sharing and sync: choose what to share

After linking, pick what to share.

![Sharing and sync](shot:settings-sharing)

1. On each device, go to ["Settings" > "Sharing and sync"](cache://settings/sharing).
2. Under "Shared with linked devices", tick:
   - "Library": ZIM files and your own libraries;
   - "Maps": downloaded regions;
   - "Models": chat models and the search model;
   - "Videos": saved videos;
   - "Notebooks": notebooks, with their photos;
   - "Shared folder": any files you want on every device.
3. Tick the same kinds on both devices.

"Transfer" shows progress. "Sync now" checks straight away. "Activity" lists what happened.

Unticking stops sharing. The files stay. Files whose names start with a dot are never shared.

- If sharing waits, "Mobile data downloads" may be off. Sync waits for Wi-Fi.
- If the other device offers more than fits, Cache fetches what fits and pauses.
- Private notebooks are left out by default. See Private notebooks in chapter 5.

## Appearance

Appearance changes how Cache looks. Changes apply straight away.

![The Appearance page](shot:settings-appearance)

1. Go to ["Settings" > "Appearance"](cache://settings/appearance).
2. Under "Theme", choose:
   - "Dark": the default;
   - "Light": bright, for indoors;
   - "Parchment": warm paper, easy in daylight;
   - "Tactical": red on black, protects night vision.
3. Under "Module icons", choose "Small" (three across) or "Large" (bigger).

## Credits and licences

This page says what Cache is and what it is built on.

![Credits and licences](shot:settings-credits)

1. Go to ["Settings" > "Credits and licences"](cache://settings/credits).
2. Read:
   - "Version": which Cache you have;
   - "Licence": the GNU Affero General Public License, version 3 or later;
   - "Source code": where to get it;
   - "Credits": the maps, data, libraries and art used;
   - "Open-source licences": the full text for every package.
