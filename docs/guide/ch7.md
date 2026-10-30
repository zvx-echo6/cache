# 7. Privacy

## What stays on your phone

Cache works on your phone, with no account and no Cache server in the middle.

These stay on your phone:
- the assistant and its model, so your questions and answers are worked out there;
- your chats, and your reports from "Report this answer";
- your notebooks, places, Home layout and settings;
- your Library, libraries, maps, regions, models and saved videos;
- your keys, in the phone's secure storage.

Cache has no sign-in. The phone's own encryption and screen lock protect the data. Keep a screen lock on.

## Remove what Cache keeps

- Chats: ["Settings" > "Cache model and web search" > "Delete all conversations"](cache://settings/assistant), or delete one in the chat list.
- Reports: "Reported answers" > "Remove" on the same page.
- Keys: see Remove a key.
- Downloads and everything else: ["Settings" > "Storage"](cache://settings/storage).

## What goes online, and when

Cache goes online only for these, each talking directly to the service named:
- Weather, alerts, fires and other sources you turned on: each source's provider, for each place you watch. This happens on a refresh, in the background, and when you ask the assistant. These small updates use any connection.
- Web search, if you set up a Kagi key and turned on "Search the web when online": Kagi gets the assistant's searches.
- Map layers that stream: the tile provider gets requests for the areas you view.
- Place search for an area you haven't downloaded: Cache's data server.
- Downloads you start: models from Hugging Face, ZIMs from Kiwix, regions from Cache's data server, videos from your PeerTube sites, libraries from the link you gave.
- Lists Cache reads itself: regions, data sources, map layers and recommended models.
- Sharing and sync, if you set it up: your own linked devices.

## Stop Cache going online

- Data sources: switch them off in ["Settings" > "Weather and alerts"](cache://settings/weather).
- Web search: turn off "Search the web when online" in ["Settings" > "Cache model and web search"](cache://settings/assistant).
- Big downloads use mobile data only if you allow it. See ["Settings" > "Storage"](cache://settings/storage).

## Your location

Cache uses your location whenever your phone allows it. It never asks in "Ask". "Find me" in "Maps" and "Turn on weather" ask the first time, only while you use the app.

It is used for:
- showing you on the map and following you in directions;
- answering questions about places near you;
- weather, alerts and fires for "Where I am", the first row of the Places notebook.

When your location is used for weather, your coordinates go to the source's provider in each request, so it can send data for that spot. Background updates use the last position Cache saved while open, rounded to about 100 metres. The same goes for every place you watch.

When you search a place in an area you haven't downloaded, Cache's data server sees the area, in squares about 100 km across. It doesn't see your exact position.

## Limit your location use

- Turn off "Use my location" to keep your position out of your questions. It is in ["Settings" > "Cache model and web search"](cache://settings/assistant) and the + menu in "Ask".
- Turn off "Weather and alerts" on "Where I am" in the Places notebook. Add a nearby town as a place instead.
- Turn off "Show my position" in "Maps" > "Layers". Cache then stops reading your position and forgets the last one.
- Refuse location in the phone's settings. Maps, Ask and weather keep working. You choose places by hand.

## Keys and logins

Keys and logins are stored in the phone's secure storage (Android Keystore or iOS Keychain). They are never shown again after saving.

- Kagi key: entered in ["Settings" > "Cache model and web search"](cache://settings/assistant).
- Data source keys: entered on the source's row in ["Settings" > "Weather and alerts"](cache://settings/weather).
- PeerTube logins: Cache doesn't keep your password. It keeps only the login the site returns.

When you save a key, Cache checks it once with a real search or download. The provider sees that one request. Each key goes only to its own provider.

Keys aren't shared between devices. Add them on each device.

## Remove a key

1. Kagi: go to "Settings" > "Cache model and web search", tap "Change" next to "Search service", then "Remove the key".
2. Data sources: tap the source's row in "Settings" > "Weather and alerts", then "Remove the key". Its sources turn off.
3. PeerTube: open the instance in "Videos", tap "Account and details", then "Log out".

## The assistant and web search

The assistant runs on your phone. It reads your Library, libraries, notebooks, downloaded places and maps, and weather data. None of this is sent anywhere to answer you.

It goes online only for:
- Web search: Kagi gets the search words the assistant writes, not your whole chat. This needs a Kagi key and "Search the web when online" on.
- Live data: if a source is on and its data isn't fresh, Cache may download it for the place.
- Places: for an area you haven't downloaded, Cache may fetch places.

To never search the web, leave "Search the web when online" off, or remove the Kagi key.

When "Use my location" is on, your position goes to the assistant on the phone, to answer about nearby places.

"Report this answer" stays on your phone.

## Private notebooks

"Private" leaves a notebook or entry out of sharing and sync by default. It doesn't hide it from the assistant.

- A private notebook isn't sent to your other devices unless you include it. Open "Edit notebook" and turn on "Include in sync and sharing". It's off by default.
- Once Cache is open, the assistant can read everything in your notebooks, private ones too. It does this on your phone.
- Private is not encryption or a lock. Keep a screen lock on.

Obsidian and Logseq are an exception. If you connect a folder in ["Notebooks" > "Connections"](cache://notebooks), private entries are written to it too, with a private mark in their properties. Any app that can open that folder can read them as plain Markdown.

Starter logs for health, such as medication or blood pressure, start private. You can switch it off.

## Sharing and sync

Sharing is off until you tap "Set up sharing" in ["Settings" > "Sharing and sync"](cache://settings/sharing).

When it's on:
- It links only your own devices, by a link code you copy across. A code works once, for 15 minutes.
- Devices talk directly. Nothing goes through a Cache server.
- If a direct link isn't possible, they use a relay ("Connected through a relay"). What they send is encrypted end to end, so the relay can't read it.
- Devices look for each other on the local network and on the internet.
- Only the kinds you tick under "Shared with linked devices" are shared: "Library", "Maps", "Models", "Videos", "Notebooks" and "Shared folder".
- Chats, settings and keys aren't shared.
- Files and folders whose names start with a dot are never shared.
- Private notebooks are left out by default.

Sharing follows "Mobile data downloads" in ["Settings" > "Storage"](cache://settings/storage).

## Stop sharing

- To stop sharing a kind, untick it. The files stay on this device.
- To stop a device connecting, tap it under "Linked devices", then "Unlink". Files already here stay.
