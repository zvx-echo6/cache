# 7. Privacy

## What stays on your phone

Cache is built to work on your phone, without an account and without a Cache server in the middle.

These stay on your phone:
- The assistant. The model runs on the phone, so your questions and its answers are worked out there.
- Your chats. They are saved on the phone and are still there after a restart. You can share one yourself with "Share chat" or "Share as Markdown".
- Your reported answers. "Report this answer" saves the report on the phone; nothing is sent anywhere. You can share reports yourself from ["Settings" > "Cache model and web search" > "Reported answers"](cache://settings/assistant).
- Your notebooks and places, Home layout and settings.
- Your Library, libraries, maps, regions, models and saved videos.
- Your keys, in the phone's secure storage.

Cache does not ask you to sign in, and has no Cache account.

The data on the phone is protected by the phone's own encryption and screen lock. Keep a screen lock on the phone.

To remove things:
- chats: "Settings" > "Cache model and web search" > "Delete all conversations", or delete one in the chat list;
- reports: "Settings" > "Cache model and web search" > "Reported answers" > "Remove";
- keys: "Settings" > "Cache model and web search" > "Change" > "Remove the key", and the source's page in ["Settings" > "Weather and alerts" > "Remove the key"](cache://settings/weather);
- downloads and everything else Cache keeps: ["Settings" > "Storage"](cache://settings/storage).

## What goes online, and when

Cache goes online only for the things below. Each talks directly to the service named:

- Weather, alerts, fires and other data sources you turned on: each source's provider, for each place you watch. This happens when you tap the refresh button or "Update now", in the background while a source is on, and when you ask the assistant about it. These small updates use any connection, including mobile data.
- Web search, only if you set up a Kagi key and "Search the web when online" is on: Kagi gets the searches the assistant makes.
- Map layers that stream when online: the map tile provider gets requests for the areas you look at.
- Place search for an area you have not downloaded: Cache fetches places for that area from Cache's data server.
- Downloads you start: models from Hugging Face, ZIMs from the Kiwix library, regions from Cache's data server, videos from the PeerTube sites you added, libraries from the link you gave.
- Lists Cache reads by itself when there is a connection: the list of regions, the list of data sources, the list of map layers and the list of recommended models.
- Sharing and sync, only if you set it up: your own linked devices.

Big downloads use mobile data only if you allow it: ["Settings" > "Storage" > "Mobile data downloads"](cache://settings/storage).

To stop data sources going online, switch them off in ["Settings" > "Weather and alerts"](cache://settings/weather). To stop web search, turn off "Search the web when online" in ["Settings" > "Cache model and web search"](cache://settings/assistant).

## Your location

Cache uses your location whenever your phone allows it. In "Ask" it does not ask. Other places ask the first time you need them: "Find me" in "Maps", or "Turn on weather". Cache asks only for permission while you use the app. The switch "Use my location" is in ["Settings" > "Cache model and web search"](cache://settings/assistant), and in the + menu in "Ask".

What it is used for:
- showing you on the map and following you during directions;
- answering questions about places near you;
- weather, alerts and fires for "Where I am", the first row of the Places notebook ("Follows the phone").

What leaves the phone: when "Where I am" has its "Weather and alerts" switch on and weather or other data sources are on, the coordinates of where you are go to those sources' providers as part of each request, so they can send data for that spot. Background updates use the last position Cache saved while it was open, rounded to about 100 metres. The same is true of every other place you watch.

When you search for places in an area you have not downloaded, Cache's data server sees which area is asked for, in squares about 100 km across, not your exact position.

To limit this:
- turn off "Use my location" (in "Settings" > "Cache model and web search" or the + menu in "Ask") to keep your position out of your questions;
- turn off the "Weather and alerts" switch on "Where I am" in the Places notebook, and add a nearby town as a place instead;
- turn off "Show my position" in "Maps" > "Layers": Cache then stops reading your position and forgets the last one;
- refuse or remove location permission in the phone's settings. Maps, Ask and weather keep working; you choose places by hand.

## Keys and logins

Cache stores keys and logins in the phone's secure storage (Android Keystore or iOS Keychain).

- Kagi key (web search): entered in ["Settings" > "Cache model and web search"](cache://settings/assistant). After saving, the key is never shown again.
- Data source keys: entered on the source's row in ["Settings" > "Weather and alerts"](cache://settings/weather). Keys stay on this phone, in its secure storage. They are never shown again.
- PeerTube logins: your password is not kept. Cache keeps only the login the site gives back, so you stay logged in.

When you save a key, Cache checks it once with a real search or download, so the provider sees that one request.

Each key is sent only to its own provider, as part of the requests that need it.

Keys are not part of sharing and sync. To use a key on another device, add it there too.

To remove a key:
1. Kagi: "Settings" > "Cache model and web search" > "Change" next to "Search service" > "Remove the key".
2. Data sources: tap the source's row in "Settings" > "Weather and alerts" and tap "Remove the key". Its sources turn off.
3. PeerTube: open the instance in "Videos", tap "Account and details", then "Log out".

## The assistant and web search

The assistant runs on your phone. It reads your Library, your libraries, your notebooks, your downloaded places and maps, and the weather data on the phone. None of this is sent anywhere to answer you.

The assistant goes online only in these cases:
- Web search: when you set up a Kagi key and "Search the web when online" is on, the assistant may search the web for a question. Kagi receives the search words the assistant writes, not your whole chat.
- Live data: when you ask about weather, alerts or another source that is switched on and the data on the phone is not fresh, Cache may download it from that source's provider for the place.
- Places: when you ask about places in an area you have not downloaded, Cache may fetch places for that area.

If you want Cache never to search the web, leave "Search the web when online" off, or remove the Kagi key.

When "Use my location" is on, your position is given to the assistant on the phone so it can answer about nearby places.

"Report this answer" stays on your phone. Nothing is sent to the makers of Cache.

## Private notebooks

You can mark a notebook, or an entry, "Private". In "Notebooks", "Private" means the item is left out of sharing and sync by default. It does not mean the item is hidden from the assistant.

- A private notebook is not sent to your other devices, and is not synced, unless you include it. To include it, open "Edit notebook". When the notebook is private, a switch "Include in sync and sharing" appears. It is off by default.
- Once Cache is open, the assistant can read everything in your notebooks, including private ones, to answer you. It does this on your phone. It is not sent anywhere to do so.
- Private is not encryption or a lock. The data is protected by the phone's own encryption and screen lock. Keep a screen lock on the phone.
- Obsidian and Logseq folders are an exception to being left out. If you connect a folder in ["Notebooks" > "Connections"](cache://notebooks), entries in private notebooks are written to it too, with a private mark in their properties. The folder is on your phone or in the storage you chose. Once they are in the folder, any app that can open that folder can read them as plain Markdown.

Starter logs for health, such as medication or blood pressure, start as private. You can switch it off.

## Sharing and sync

Sharing is off until you tap "Set up sharing" in ["Settings" > "Sharing and sync"](cache://settings/sharing).

When it is on:
- It links only your own devices, and only by a link code you copy from one device to the other. A code works once, for 15 minutes.
- Devices talk to each other directly; nothing goes through a Cache server. When a direct connection is not possible, they connect through a relay ("Connected through a relay"). What they send is encrypted end to end, so the relay cannot read it.
- To find each other, devices look on the local network and on the internet.
- Only the kinds you tick under "Shared with linked devices" are shared: "Library" (ZIM files and your own libraries), "Maps" (downloaded regions), "Models", "Videos", "Notebooks" (with their photos) and "Shared folder".
- Chats, settings and keys are not shared.
- Files and folders whose names start with a dot are never shared.
- Private notebooks are left out by default.

To stop sharing a kind, untick it. The files stay on this device.

To stop a device connecting, tap it under "Linked devices" and tap "Unlink". Files already here stay.

Sharing follows "Mobile data downloads" in ["Settings" > "Storage"](cache://settings/storage).
