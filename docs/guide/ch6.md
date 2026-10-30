# 6. When something doesn't work

## When part of Cache is not available

These messages mean one part of Cache couldn't start. The rest keeps working.

- "Search is not available on this device" or "Not available" in "Settings": Library, libraries and place search won't work. Close Cache fully and open it again.
- "Search is not ready yet": Cache is still starting. Wait and try again.
- "Layers are not available on this device": close Cache and open it again.
- "Videos are not available on this device": close Cache and open it again.
- "Road routing downloads are not available: [reason]": close Cache and open it again. Check your connection.
- "Sharing could not start: [reason]": tap "Try again" in ["Settings" > "Sharing and sync"](cache://settings/sharing). If it keeps failing, restart Cache.
- "Sharing is not set up": tap "Set up sharing" in "Settings" > "Sharing and sync".

If one keeps coming back, note the exact words for whoever supports your copy.

## Home weather card messages

- "Not set up yet": no weather source is on. Tap "Turn on weather".
- "Waiting for your position": the phone doesn't know where it is. Wait, or go outdoors.
- "forecast expired, needs a connection": connect, open "Weather" and tap "Update now".
- "no forecast yet": open "Weather" and tap "Update now".
- "No alerts known, data expired": alert data is too old to trust. Connect and update.
- "No alerts nearby": none for your places when last checked.

## Home search and shortcut messages

- "Nothing found" under "Ask Cache:": nothing on your phone matches. Tap the "Ask Cache:" row to ask instead.
- "That chat is gone": the chat was deleted. Tap and hold the shortcut, then "Remove from Home".
- "That page is not on this phone any more": the ZIM was removed. Remove the shortcut, or download it again.
- "Finish or end the route first": you're being guided. Tap "End" in "Maps".

## Ask messages

- "Choose a model at the top to start.": tap "Choose a model" or "Get a model", then load one.
- "No model" in the title: tap the title, then "Manage models".
- "Starting…": Cache is starting. Your question waits.
- "Cache's search couldn't start, so this wasn't answered.": tap "Try again". If it repeats, restart Cache.
- "No answer was produced." or "The model stopped without an answer": ask again in other words, or tap "New chat". Try another model if it repeats.
- "Not from your sources": the answer isn't from your phone or a search. Check it.
- "Navigation unavailable: this route snapshot is no longer available.": ask for directions again.
- "Report saved on this phone. Find it in Settings > Assistant.": saved. That page is now "Cache model and web search".

## Location messages in Ask

Cache uses your location in "Ask" when the phone allows it. The "Use my location" switch is in the + menu and in ["Settings" > "Cache model and web search"](cache://settings/assistant). It's the same switch.

- "Blocked in the phone's settings": tap "Open the phone's settings" in the + menu, or "Phone settings" in "Settings". Allow location.
- "The phone's location is switched off": the same buttons. Turn location on.
- Answers ignore where you are: check that the switch is on, and "Show my position" in "Maps" > "Layers" is on.

If Cache can't get a position yet, chat still works. Go outdoors or near a window and try again.

## Models messages

On the Models screen (tap the model name in "Ask", then "Manage models"):
- "Not supported: Cache needs a model that can use tools": pick another. Your current model stays loaded.
- "Too big for this phone": choose a smaller one. "May be tight on this phone" may be slow or fail to load.
- "Can't read the models folder": restart Cache. Check free space.
- "Could not copy the file: [reason]": check free space and try again.

## Hugging Face messages

- "Could not search Hugging Face. Check the connection and try again."
- "Could not list the files. Check the connection and try again."
- "No GGUF models match.": try the model's family name.
- "This repository has no single-file GGUF models.": choose another.
- `This model needs a Hugging Face account to download. Get it in a browser, then use "Choose a file".`: do that.
- "The download stopped: [reason]": check the connection and download again. It continues.

## Search model messages

The search model (605 MB) lets Cache search by meaning.

- "Meaning search needs the search model." with "Get it": it's missing or stopped. Open the Models screen and tap "Get it" under "On this phone".
- "Next: Search model, 605 MB": it downloads after the current model.
- "Also downloads: Search model, 605 MB": it comes with the model you're downloading.
- "Search model: download stopped ([reason])": if it's about mobile data, connect to Wi-Fi, then tap "Get it".
- "Meaning search needs the model [name].": a library wants a different model. Cache can't download it and searches by keywords.
- "Matching words only: the meaning search is not available": places search by words only.

## Download pop-up messages

Every download asks first. See Downloads, Wi-Fi and mobile data in chapter 1.

- "Wait for Wi-Fi": you're on mobile data and "Mobile data downloads" is off. It starts on Wi-Fi.
- "Download now": goes ahead on mobile data this once.
- "Needs 28 GB more. Cache always leaves 20 GB for the phone." (numbers vary): it won't fit. Tap "Free up space".

Delete pop-ups say "Frees" and a size, and "You can download it again later." Tap "Delete" or "Cancel".

## Library messages

- "Nothing in your library yet. Add Wikipedia, medical guides, survival manuals or your own library, and read them with no signal.": tap "Add to Library".
- "Update ready": press and hold the item, then "Check for update".
- "That source is not on this phone any more.": download it again.
- "Indexing", "Waiting to index" or "Building index": see An index still building.
- "Nothing found. Try another word, language or category.": change the search or chips.

## Kiwix catalogue messages

When the catalogue in ["Library" > "Add to Library"](cache://library/add) can't load:
- "Cannot reach the Kiwix library. Check the connection.": connect and tap "Try again".
- "Cannot make a secure connection to the Kiwix library.": the network may block it, or the phone's date is wrong. Try another network.
- "The Kiwix library took too long to answer.": try later.
- "The library answered [code].", "The library redirected too many times.", "The library sent a redirect with no address.", "The library answered with something that is not a catalogue." or "The library could not be read: [reason]": try later or on another network.

## ZIM download messages

Seen while a Library item downloads. After most, tap "Try again". It continues where it stopped.

- "Not enough free space: [size] needed, [size] free." or "The device is out of space. Free some and try again.": free space in ["Settings" > "Storage"](cache://settings/storage), or pick a smaller version ("Mini" or "No pictures").
- "The download stopped early ([a] of [b]). Try again to continue."
- "The file did not match its published checksum, so it was thrown away. Try again.": it was damaged on the way.
- "The connection failed: [reason]": check the connection.
- "Could not make a secure connection to the download server.": try another network.
- "The download server took too long to answer.": try later.
- "That file is no longer on the download server.": search the catalogue again.
- "The download server answered [code].", "The download server did not say how big the file is.", "The download server redirected too many times.", "The download server sent a redirect with no address." or "The download server continued from the wrong place. Try again.": try later.
- "Could not write the file: [reason]": check free space.
- "Could not finish the download: [reason]" or "The download failed.": tap "Try again".

## Reader messages

- "This ZIM could not be opened.": it may be damaged. Delete it and add it again.
- "This ZIM is still being indexed. Text search works when that is done.": read now, search later.
- "That link is on the web. It is not available offline.": the link leaves the ZIM.

The assistant may say sources are still being indexed, or none are added. Wait, or tap "Add to Library".

## Your own library messages

On the "Your own library" screen (["Library" > "Add to Library" > "Your own library"](cache://library/add)):
- "Use a link that starts with https://": paste a full https link.
- "This file isn't a Cache library.": pick a .cache-library file or snapshot.
- "This is an empty library template. Fill it with your own entries first (see the README inside).": fill the template first.
- "Could not read or write the file." or "The file could not be found.": pick it again. Check it's complete.
- "Its settings file could not be read." or "That settings file could not be read: [reason]": cache-library.json is damaged. Get a fresh copy.
- "Not enough free space on this device for the library.": free space.
- "The search index could not be built": delete the library and add it again.
- "Could not write the library: [reason]" or "Could not remove the library: [reason]": check free space. Restart Cache.
- "The new copy could not be opened, so the library was kept as it was.": the old copy still works.

States are "Getting ready", "Waiting to index", "Building index" and "Not available". Steps while adding are "Checking…" and "Putting it in place…", with percentages. Adding the same link again continues a cut-off download.

## Map and layer messages

In "Maps":
- "No base map yet. Connect once to get the catalogue.": connect once.
- "[layer] needs a connection here" or "[layer] needs a connection or a download here": connect, or download the region.
- "Maps need network access": tap "Allow". If it still fails, tap "Open settings".

In the layer definition editor (["Settings" > "Maps" > "Advanced"](cache://settings/maps)):
- "A layer needs an id of lower-case letters, digits, - and _", "A layer needs a title" or "A layer definition is a JSON object": fix it and tap "Save".

## Map search messages

Under "Search places or coordinates":
- `Nothing found for "[words]"`: try other words, a nearby town or coordinates.
- "No places on this phone.": tap "Get a region".
- "No places downloaded here.": tap "Get this area".
- "Getting places for this area…": wait. Results appear by themselves.

## Directions messages

In the directions panel:
- "Your position is not known yet. Turn on location to get directions from where you are.": tap "Find me" and allow location. Go outdoors for a GPS fix.
- "No way found between these places": try another way of travel, or a point on a road.
- "These places are too far apart for one trip": plan it in parts.
- "One of these places is outside the downloaded maps": download the region, or connect.
- "Off-road needs off-road data for this area": download the region, or choose "Walk" or "Drive".
- "The off-road part of this trip is too long to work out": move the end nearer a road.
- "Working out the route took too long. Try again"
- "Could not get directions" or "Directions are not available in this build yet": try "Drive" or "Walk", or try later.
- "Ignores land rules: the route may cross private or closed land.": shown with "Emergency: any land". Use only in an emergency.

## Guidance messages

- "Getting your position": waiting for the first GPS fix. Go where the phone sees the sky.
- "Rerouting": you left the route. A new one is being worked out.
- "Arriving", then "You have arrived".

## Region list messages

On the "Regions" sheet (["Maps" > "Layers" > "Download a region"](cache://maps/regions)):
- "The list of regions needs a connection the first time. After that it works offline.": connect and tap "Try again".
- "This country's regions need a connection the first time." or "Search needs a connection the first time.": connect once.
- "This region could not be read. Connect and try again."
- `No region called "[name]".`: try another spelling, or browse "Countries".
- "Nothing downloaded yet": pick a region under "Downloads".
- "Downloading needs a connection.": connect first.
- "Could not work out the size" or "Needs a connection to work out the size.": connect and reopen the region.
- "This region has no outline yet.", "This region is too big to download the map in one go." or "No map layer that can be kept offline is switched on.": shown in place of the download button.
- "On this phone": already here.

## Region downloads paused or failed

A downloading region shows one line: "Map", "Directions", "Places" and "Off-road", each ready, a percentage, waiting, stopped or paused. A part that says ready already works.

- "Paused: no connection." or "Paused: no network it may use": connect, or use Wi-Fi. It carries on by itself.
- "Paused: mobile data is switched off for downloads. Connect to Wi-Fi to carry on.": connect to Wi-Fi, or turn on "Mobile data downloads" in ["Settings" > "Storage"](cache://settings/storage).
- "Paused: [region] needs [size], [size] is free and [size] is kept free": delete things you don't need. It carries on.
- "Paused: [reason]; trying again shortly": wait.
- "Paused: could not move to [build]: [reason]" or "Paused: could not move places to [build]: [reason]": check free space. Tap the region's update button.
- A part that says stopped: tap the region's update button. If Cache was closed, tap "Get your area" in the Set up card ("[region] · Stopped. Tap to carry on"). Cache says "Carrying on with [region]".
- "Places not downloaded": update the region.

## Region data messages

Texts you may see on a part:
- "the places server cannot be reached": try later.
- "update Cache to use this data: the places are in layout [n], this version reads [n]": the data is newer than Cache. Update Cache.
- "the index of [build] does not match its checksum": the download was damaged. Update the region again.

## Weather status messages

The top line of ["Settings" > "Weather and alerts"](cache://settings/weather) says how fresh data is, for example "Updated 1 hour ago". It warns when old, for example "Updated 3 days ago". The "Weather" box says the same and has "Update now".

- "Nothing is switched on yet." on "Weather", or "Nothing switched on yet" in settings: turn on a source.
- "Not updated yet": tap the refresh button, or "Update now".
- "Updated [when]": fresh. "No connection since [day]" means you've been offline.
- "Updates when you tap Update now, and when you ask the assistant": background updates couldn't be scheduled. Tap "Update now".

## Weather screen messages

- "Waiting for your position." with "The forecast and alerts for where you are show here once the phone knows where it is.": nothing is wrong. Wait.
- "Not downloaded yet. Update now to get it.": tap "Update now".
- "Expired · [age] · needs a connection for more": connect and update.
- "Every day of this forecast has passed." or "No forecast.": update when online.
- "That alert has ended or is no longer in the data.": the alert is over.

## Update messages

After "Update now" or the refresh button, a short message says how it went.

- "Updated" or "Already up to date": all good.
- "Already updating": wait.
- "Switch on a source to update it.": turn on a source.
- "Waiting for your position.": try again soon.
- "No place is being watched.": turn on "Weather and alerts" for a place in the Places notebook, or for "Where I am".
- "No connection. Update when you are online."
- "Updated, but [problem]": one source didn't update.

Weather and alerts update on any connection, even with "Mobile data downloads" off.

## Source failure messages

When a source fails the message reads "[provider] for [place] failed: [why]".

- "reached its limit for now": wait and try later.
- "needs a key": tap "Get key" on the source's row in "Settings" > "Weather and alerts".
- "sent something Cache could not read": the provider had a problem. Try later.
- "the service answered HTTP [code]": if it's 401 or 403, replace the key.
- "couldn't be reached": check your connection.
- "couldn't update": try later.

A source's page (tap its row) shows its "Last problem".

## Turn on weather messages

When you tap "Turn on weather":
- "Use your location?": tap "Continue", or "Not now" to choose a place.
- "Location is off. Choose a place instead." or "Cache could not use your location. Choose a place instead.": pick a place in the sheet.

In the "Choose a place" sheet:
- "No places match.": try another spelling or a nearby town.
- "Could not search for places.": check places or the connection, then try again.
- "Could not save the place.": try again.

## Data source messages

On a source's page (tap its row in ["Settings" > "Weather and alerts"](cache://settings/weather)):
- "Data" "Out of date": update when online.
- "Last update" "Nothing downloaded yet": tap "Update now" on "Weather".
- "This source is no longer in the catalogue.": its catalogue dropped it.
- "Needs your own key": tap "Get key".

In the source list:
- "Loading…": wait.
- "No sources downloaded yet. Connect to the internet and they load by themselves."
- "No source matches your search.": try other words.

## Data engine messages

Shown as a source's "Last problem" or in the status:
- "[source] has reached its limit of [n] downloads per [day]": Cache stops asking so you aren't blocked. It resumes later.
- HTTP 401 or HTTP 403, key or login refused: replace the key.
- HTTP 429, rate limited: wait and try later.
- The response has no [part]: the provider changed its data. Wait for an updated source.

## Web search key messages

In the "Web search" sheet (["Settings" > "Cache model and web search" > "Set up"](cache://settings/assistant)):
- "Paste your key first." (the field is empty) or "Kagi didn't accept this key. Check you copied all of it.": copy the whole key again.
- "Kagi says this account has no search credit left, or has reached its limit. Check your balance, then try again.": add credit.
- "Couldn't reach Kagi. Check your connection."
- "Kagi had a problem (HTTP [code]). Try again in a moment."
- "Kagi answered with an error (HTTP [code])." or "Kagi answered with something Cache couldn't read. Try again later."
- "The key was accepted but couldn't be saved on this phone.": try again. Restart Cache if it repeats.
- "Couldn't open the page. Go to [address]": open that address in your browser.
- "Web search is on": it worked.
- "Key removed": web search is off.

## Data source key messages

In the key sheet from "Get key" on a source's row (["Settings" > "Weather and alerts"](cache://settings/weather)). [Provider] is the company that gives the key.

- "Paste your key first.": the field is empty.
- "[Provider] didn't accept this key. Check you copied all of it.": copy it again.
- "[Provider] didn't accept this key, or answered with something Cache couldn't read. Check you copied all of it."
- "[Provider] says this key has reached its limit. Try again later."
- "Couldn't reach [provider]. Check your connection."
- "[Provider] had a problem (HTTP [code]). Try again in a moment."
- "[Provider] answered with an error (HTTP [code])." or "[Provider] answered with something Cache couldn't read. Try again later."
- "This source needs no key.": nothing to add.
- "That key wasn't accepted." or "Couldn't check the key. Try again."
- "The key was accepted but couldn't be saved on this phone.": try again.
- "[source] is on" or "Key replaced": it worked.
- "Key removed": its sources are off.

## Catalogue messages

In ["Settings" > "Weather and alerts" > "More sources" > "Add sources from a link"](cache://settings/weather):
- "Enter an address that starts with https://": paste the full link.
- "No connection. Connect to add a catalogue."
- "Couldn't check that link. Try again."
- "That address didn't give a connector catalogue.": ask whoever gave you the link.
- "That catalogue is already added." or `A catalogue called "[name]" is already added.`
- "None of the sources in this catalogue can be used by this version of Cache."
- "This catalogue is in a newer format than this version of Cache can read. Update Cache to use it."
- "This catalogue is in a format Cache does not know."
- "Couldn't reach [site]. Check your connection.", "Couldn't make a secure connection to [site].", "Couldn't read from [site].", "[site] answered with an error (HTTP [code]).", "The file is larger than expected.": a network or server problem. Try later.
- "Left out ([n])": some sources couldn't be used. The reason is under each. Tell the publisher.
- "[name] added", "Removed", "Sources are up to date": it worked.
- "Couldn't load the catalogue.": the last good copy is kept.

## Notification messages

- "No pop-ups at all?": you chose "None" under "Pop up for". Cache won't interrupt you, even for an evacuation. Tap "Keep pop-ups" or "Turn off". Alerts stay listed in "Weather".

If alerts don't pop up, check:
- "Pop up for" in ["Settings" > "Notifications"](cache://settings/notifications) is not "None";
- your phone allows notifications for Cache;
- you're not in quiet hours. Serious alerts still ring.

Location isn't set in Notifications. Use "Use my location" in "Settings" > "Cache model and web search".

## Video messages

In "Videos":
- "Can't reach the instance. Check the connection and try again."
- "That address doesn't look like a PeerTube instance.": check it, for example tube.example.org.
- "The instance asked us to slow down. Try again in a minute."
- "The instance needs you to log in again.": tap "Log in" in the account sheet.
- "This account needs its two-factor code." or "Enter the two-factor code.": type the code from your authenticator.
- "The user name or password is wrong."
- "That instance is not in the list." or "Not found on the instance.": the video or channel was removed.
- "No instances yet. Add the address of a PeerTube site to browse and watch its videos.": tap "Add an instance".

## Video download and play messages

- "Not enough free space on this phone.": free space.
- "The file did not arrive intact. Try again."
- "Download stopped." or "The download failed.": tap "Continue download" (on the video) or "Continue" (in "Saved videos").
- "Wait for Wi-Fi": you're on mobile data and "Mobile data downloads" is off.
- "This video has no file to download yet.": try later.
- "This file can't be played.": try another size, or play it online.
- "Can't play this video right now. Check the connection.": play the saved copy, or connect.
- "Nothing saved yet. Open a video and choose Download to watch it without a connection."

## Sharing and sync messages

In ["Settings" > "Sharing and sync"](cache://settings/sharing):
- "Paused: no network it may use": connect to Wi-Fi, or turn on "Mobile data downloads" in "Settings" > "Storage".
- "Local network only": only devices on the same Wi-Fi are reachable now.
- "Not reachable": the other device is off, asleep or offline. Open Cache on it.
- "Connected through a relay" or "Connected directly": working.
- "Works once, for 15 minutes": make a new code with "Show my link code" if it expired.

If a device's files are bigger than your space, Cache fetches what fits and pauses. Free space and it carries on.

## Link code messages

When linking fails, the sharing engine says why:
- "this is not a Cache link code" or "the link code is damaged": copy the whole code again.
- "that is this device's own code": enter it on the other device.
- "the other device did not answer" or "could not reach the other device: [reason]": open Cache on both, make sure both are online, and try a new code.
- "the other device refused the link": make a fresh code on the other device.
- "could not start networking: [reason]": restart Cache.

## Storage messages

In ["Settings" > "Storage"](cache://settings/storage):
- "free space unknown": the phone didn't say. Downloads still check first.
- "Wait for the downloads to finish, then clean up.": wait, then try again.
- "Nothing to clean up": nothing to remove.
- "Freed [size]": "Clean up" finished.

In ["Settings" > "Credits and licences"](cache://settings/credits):
- "Couldn't load the credits.": restart Cache.

## Notebook messages

In "Notebooks":
- "Notebooks could not open. Your entries are still on this phone.": tap "Try again". If it repeats, restart Cache.
- "Could not make it: [reason]": check free space and try again.
- "No notebooks yet. Make one with New notebook.": tap "New notebook".
- "Not saved. Your phone may be out of space.": free space and tap "Try again". Your text is kept.
- "This notebook is gone": remove its shortcut from "Home".
- "You already have a notebook with this name.": choose another.
- "Could not attach the file: [reason]": try again.

## Offline: what still works

With no connection, these work:
- "Ask", with your model, Library, libraries and downloaded places (not web search);
- "Maps" for downloaded regions, place search, and road directions (GPS works offline);
- "Library" and the reader;
- "Notebooks";
- saved "Videos" ("Play saved copy");
- "Weather", showing the last data with its age (old data is marked expired);
- your chats, saved places and settings.

These need a connection:
- weather, alerts and fire updates;
- downloads;
- map layers that "Streams when online" or "Needs a connection" outside downloaded areas;
- web search;
- the first look at the region list and Kiwix catalogue;
- linking devices over the internet.

## Mobile data: why a download did not start

One switch controls this: "Mobile data downloads" in ["Settings" > "Storage"](cache://settings/storage).

- Off (at first): big downloads wait for Wi-Fi. This covers models, regions, Library items, libraries, videos and sharing.
- On: they also use mobile data.

If a download waits because of it, the pop-up offered "Wait for Wi-Fi" and the row shows "Waiting for Wi-Fi".

To fix it:
1. Connect to Wi-Fi, or
2. tap "Download now" to use mobile data this once, or
3. turn "Mobile data downloads" on.

Weather and alerts always update. If weather is old, see Weather status messages.

## Storage full

When the phone is low on space, downloads refuse or stop. The pop-up says how much more is needed, for example "Needs 28 GB more. Cache always leaves 20 GB for the phone." Cache keeps 10% of storage free, at least 5 GB and at most 20 GB, and you can't change that.

![The Storage page](shot:settings-storage)

To free space:
1. Tap "Free up space" in the pop-up, or go to ["Settings" > "Storage"](cache://settings/storage).
2. Tap "Clean up" first. It never touches what you saved.
3. Open the row that uses the most: "Library", "Models", "Regions", "Notebooks" or "Videos and weather".
4. Remove items you don't need, and confirm.

Then continue the download.

## A download stopped

Most downloads continue where they stopped. Fix the cause first: the connection dropped, mobile data is off, the phone is full, or Cache was closed.

![A region that stopped](shot:region-row)

- Models: download the same file again on the Models screen.
- Regions: they continue by themselves, or tap the region's update button on the "Local" tab.
- Library items: tap "Try again" in "Add to Library", or "Resume" on its row.
- Libraries from a link: add the same link again.
- Videos: tap "Continue download" or "Continue".

## An index still building

After you add a ZIM or library, Cache builds a search index in the background. Large ones take a long time.

While it builds:
- the Library row says "Indexing" with a percentage, or "Waiting to index";
- a library's row says "Building the search index";
- a ZIM opens, but search inside it says "This ZIM is still being indexed. Text search works when that is done.";
- the assistant may say sources are still being indexed.

Leave Cache open and keep the phone charged for big ones.

- If indexing fails ("Indexing failed" or "The search index could not be built"), delete the item and add it again.
- An updated ZIM keeps the old copy working until the new one is indexed.
