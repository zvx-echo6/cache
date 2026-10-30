# 3. Settings, page by page

## Opening Settings

To open "Settings", tap the gear at the top right of "Home", or open "Settings" from "Modules".

There are eight rows:
1. "Cache model and web search"
2. "Maps"
3. "Weather and alerts"
4. "Notifications"
5. "Storage"
6. "Sharing and sync"
7. "Appearance"
8. "Credits and licences"

Each row has a short status line, so you can see the state without opening it. For example:
- "Cache model and web search" shows the model and "web search on" or "web search off".
- "Weather and alerts" shows how many sources are on and how many places.
- "Notifications" shows "Serious alerts", "All alerts" or "No pop-ups", and the quiet hours.
- "Storage" shows how much Cache uses and how much is free on the phone.
- "Sharing and sync" shows "Not linked yet" or which devices are linked.

There is no Library page or Videos page in Settings. Open "Library" and "Videos" from "Modules" or the bar. Saved videos are removed in "Videos" itself, or in "Settings" > "Storage" > "Videos and weather".

A row that says "Not available" means that part of Cache could not start on this phone. Restart Cache; if it stays, see chapter 6.

## Cache model and web search

Go to "Settings" > "Cache model and web search".

"Model":
- The model row shows the loaded model, "On this phone", its size and "Ready", or "No model chosen". Tap it to open the Models screen, where you download, load, unload and delete models.

"Web search":
- "Search service" shows "Kagi key saved on this phone", or "Not set up" with "Kagi, paid, your own key". Tap "Set up" (or "Change") to add, replace or remove the key.
- "Search the web when online" lets the assistant search the web when you have a connection. It can only be turned on once a search service is set up; until then it says "Set up a search service to turn this on".

"Location":
- "Use my location" is a switch. It is the same switch as in the + menu in "Ask". When the phone blocks location for Cache, the row says so and links to the phone's settings.

"Conversations":
- "Saved conversations" opens the list of chats on this phone.
- "Reported answers" lists the answers you reported, each with "Share" and "Remove", and "Share all reports".
- "Delete all conversations" asks first, then removes every saved chat. This can't be undone.

To add the Kagi key, see the section Web search with Kagi in chapter 4.

## Maps

Go to "Settings" > "Maps".

"Downloaded" lists every map area you downloaded, with its size and date, or a download in progress. If nothing is there, it says "Nothing downloaded". Tap a row to open the list of layers.

"Regions" opens the "Regions" sheet, where you download, update and delete regions. Each region has routing, map, places and off-road.

"Layers" shows how many layers there are, how many are on the map, and how much space they use. Tap it to open the list of every layer.

"Advanced" ("Layer definitions and source addresses") opens a page that lists how each layer is defined:
- Each definition has a switch. A definition switched off is not offered or drawn.
- The edit button lets you change a definition, for example to point Cache at your own map server.
- "Add a layer definition" adds a new layer, written as JSON. Tap "Save" when done.
- On a built-in definition you changed, "Remove my version of this definition" puts it back.

Most people never need "Advanced". If a layer stops working after an edit, remove your version.

## Weather and alerts

Go to "Settings" > "Weather and alerts".

At the top, one line says when the data was last updated, for example "Updated 1 hour ago". Next to it is a small round refresh button. Tap it to fetch the data again. When the data is old, the line turns into a warning, for example "Updated 3 days ago".

Under it is one list of sources. Cache loads it from its catalogue. Each row says what the source gives and who provides it:
- The featured sources come first, for example "Weather forecast", "Weather alerts", "Wildfires" and "Satellite fire hotspots".
- The rest are under "More sources", with a count such as "9 more". Tap it to open the list. It has a search box. It holds sources such as earthquakes, river levels, avalanche danger, road conditions and space weather. At the bottom of that list are "Add sources from a link" and "Catalogues in use".

Each row has a switch that turns the source on or off, and a "Get key" button if it needs a key. Tap the row itself to open the source's page. It has "Use this source", and for a key, "Replace" and "Remove the key".

A source that needs a free key has a "Get key" button on its row. See the section Keys for data sources.

If the list says "No sources downloaded yet. Connect to the internet and they load by themselves.", connect and come back.

Which places the data is kept for is set per place, in the Places notebook. "Where I am" is its first row ("Follows the phone"). Each place has its own "Weather and alerts" switch. See the section Add or edit a place in chapter 5.

You choose which alerts pop up in "Settings" > "Notifications".

## Keys for data sources

Some data sources need your own key from the provider. The key is free for the sources in the list, but you have to get it yourself. Keys go on the row of the source. There is no separate key screen.

To add a key:
1. Go to "Settings" > "Weather and alerts". Find the source. Featured sources are at the top. Others are under "More sources".
2. Tap "Get key" on its row.
3. The sheet explains what the key gives. Tap "Get a key from [provider]" to open their page.
4. Follow their steps to get a key, then copy it.
5. Come back to Cache, paste it, and tap "Check and save".

Cache checks the key with one real download. If it works, the key is saved and the source turns on. If not, the sheet says why, and nothing is saved.

To replace or remove a key, tap the source's row to open its page. There, "Replace" gives a new key, and "Remove the key" deletes it. Removing a key turns off every source that uses it.

Keys stay on this phone, in its secure storage. They are never shown again, and they are not shared to your other devices.

For where to get each key, see chapter 4.

## Add sources from a link

Other people can publish lists of data sources (catalogues). You can add one with its link.

1. Go to "Settings" > "Weather and alerts" > "More sources". At the bottom, tap "Add sources from a link".
2. Paste the link into the field and tap "Check this link".
3. Cache downloads the list and checks every source. Nothing is added yet.
4. Read the card: who publishes it, how many sources it adds, and any it left out with the reason.
5. Tap "Add these sources", or "Cancel".

The new sources stay off until you switch them on.

"Catalogues in use", at the bottom of the same list, lists every catalogue on this phone. Tap "Remove" on one you added to take its sources off. The main catalogue has "Address" instead, to change where it comes from.

"Check for updates" downloads every catalogue again. Cache says "Sources are up to date" or what went wrong.

Only add links from people you trust: their sources decide what is downloaded and shown.

## Notifications

Go to "Settings" > "Notifications".

"Pop up for" is one choice. It decides which alerts appear as notifications:
- "Serious only": evacuations, extreme and severe warnings. This is the default.
- "All alerts": adds watches and advisories.
- "None": nothing pops up. Cache warns you once, "No pop-ups at all?", because it will not interrupt you for anything, not even an evacuation order. Tap "Turn off" to confirm or "Keep pop-ups" to cancel.

"Quiet hours" shows the times and the words serious still ring. Tap it to change them. See the section Quiet hours.

Every alert is listed in "Weather" either way.

Pop-ups also need your phone's permission for notifications. If you refused it, allow notifications for Cache in your phone's settings.

## Quiet hours

Go to "Settings" > "Notifications" > "Quiet hours".

1. Use the "Quiet hours" switch to turn them on or off.
2. Tap "From" and choose when they start.
3. Tap "To" and choose when they end.

During quiet hours, alerts arrive silently. Serious ones still ring. There is no separate ring-through switch.

Quiet hours do not change what is listed in "Weather". Every alert is listed there either way.

## Storage

Go to "Settings" > "Storage".

The top shows a usage bar and a line such as "118 GB used by Cache · 103 GB free on the phone".

Below it:
- "Clean up": removes unfinished downloads, damaged files and temporary files. It shows how much it will free and has a "Clean up" button. It never touches anything you saved. With nothing to remove it says "Nothing to clean up".
- "Mobile data downloads": a switch. Off means big downloads wait for Wi-Fi. Weather and alerts always update.
- "Kept free for the phone": information, not a setting. See the section Room kept free for the phone.
- One row for each kind of thing Cache keeps: "Library", "Models", "Regions", "Notebooks" and "Videos and weather". Each row shows how many items and how much space.

Tap a row to open a list of its items. Remove an item from there. A pop-up shows what it frees and asks you to confirm.

To free space when a download will not fit, tap "Free up space" in the download pop-up. It opens this page.

## Mobile data downloads

Go to "Settings" > "Storage" and find the "Mobile data downloads" switch.

- Off (the start setting): big downloads wait for Wi-Fi. This covers models, Library items, regions, videos, libraries from a link, and sharing between your devices.
- On: big downloads also use mobile data.

Weather and alerts always update, on any connection. They are small.

When a download would use mobile data and the switch is off, the download pop-up says so. Its default button is "Wait for Wi-Fi". The download starts by itself when you are on Wi-Fi. To go ahead once on mobile data, tap "Download now".

Changes apply at once, even to a download already running.

## Room kept free for the phone

Go to "Settings" > "Storage" and look at "Kept free for the phone".

Cache never uses the last part of your storage, so the phone keeps working. The rule is fixed:
- It keeps 10% of total storage free.
- Never less than 5 GB, and never more than 20 GB.
- On iPhone, Cache also stays within the amount iOS says is available for important use. The stricter limit wins.

The row shows the rule, "10% of storage, 5 to 20 GB", and the amount in use right now. You cannot change it.

When a download will not fit, the pop-up says how much more room is needed, for example "Needs 28 GB more. Cache always leaves 20 GB for the phone." The button becomes "Free up space". Tap it, then remove things you no longer need from "Storage".

## Sharing and sync: set up and link devices

Sharing links your own Cache devices so they keep the same library, maps, models and videos. Devices talk to each other directly, over Wi-Fi nearby or the internet.

To set up, on each device:
1. Go to "Settings" > "Sharing and sync".
2. Tap "Set up sharing".

To link two devices:
1. On the first device, tap "Show my link code". A code appears, as a QR picture and as text. It works once, for 15 minutes.
2. Tap "Copy code", and get the text to the other device (for example in a message to yourself).
3. On the other device, tap "Enter a link code", tap "Paste" (or type it), then "Link".
4. Cache names the other device, for example "Linked with Android phone".

Under "This device", tap the name to rename it ("Device name").

Under "Linked devices", each device shows whether it is connected, directly or through a relay, or "Not reachable" and when it was last seen. Tap a device and tap "Unlink" to stop it connecting. Files already here stay.

## Sharing and sync: choose what to share

After linking, go to "Settings" > "Sharing and sync" on each device and tick what to share under "Shared with linked devices":
- "Library": your ZIM files and your own libraries, together.
- "Maps": your downloaded regions.
- "Models": your chat models and the search model.
- "Videos": saved videos.
- "Notebooks": your notebooks, with their photos.
- "Shared folder": a folder for any files you want on every device.

Tick the same kind on both devices. If the other device has files you do not, the line says how many files it has, and that you can tick the box to get them.

If the other device offers more than fits, Cache says so; it fetches what fits and pauses.

While files move, "Transfer" shows the progress. "Sync now" checks for changes straight away. "Activity" lists what happened recently.

Unticking stops sharing; the files stay on this device. Files and folders whose names start with a dot are never shared.

Sharing follows "Mobile data downloads". With it off, sync waits for Wi-Fi.

Private notebooks are left out of sync and sharing by default. See the section Private notebooks in chapter 5.

## Appearance

Go to "Settings" > "Appearance".

"Theme":
- "Dark": the default.
- "Light": bright, for indoors.
- "Parchment": warm paper, easy reading in daylight.
- "Tactical": red on black, protects night vision.

"Module icons":
- "Small": three across.
- "Large": bigger, easier to tap.

Changes apply straight away.

## Credits and licences

Go to "Settings" > "Credits and licences".

- "Version" shows which Cache you have.
- "Licence": Cache is free software under the GNU Affero General Public License, version 3 or later.
- "Source code" shows where to get Cache's source code.
- "Credits" lists the maps, data, libraries and art Cache is built on.
- "Open-source licences" shows the full licence text of every package Cache uses.
