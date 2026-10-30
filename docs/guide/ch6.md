# 6. When something doesn't work

## When part of Cache is not available

These messages mean a part of Cache could not start on this phone. The rest of Cache keeps working.

- "Search is not available on this device", or a "Not available" status in "Settings": the search part of Cache did not open. Library, libraries and place search will not work. Close Cache fully and open it again.
- "Search is not ready yet": Cache is still starting. Wait a few seconds and try again.
- "Layers are not available on this device": the map could not start. Close Cache and open it again.
- "Videos are not available on this device": the video part could not start. Close Cache and open it again.
- "Road routing downloads are not available: [reason]": regions cannot be downloaded right now. Close Cache and open it again; check your connection.
- "Sharing could not start: [reason]": tap "Try again" in "Settings" > "Sharing and sync". If it keeps failing, close Cache and open it again.
- "Sharing is not set up": go to "Settings" > "Sharing and sync" and tap "Set up sharing".

If one of these keeps coming back after a restart, note the exact words. They help whoever supports your copy of Cache.

## Home messages

On the "Weather and alerts" card:
- "Not set up yet": no weather source is on. Tap "Turn on weather".
- "forecast expired, needs a connection": the forecast is too old to show. Connect, open "Weather" and tap "Update now".
- "no forecast yet": open "Weather" and tap "Update now".
- "No alerts known, data expired": the alert data is too old to trust. Connect and update. Until then, Cache cannot tell you about new alerts.
- "No alerts nearby": no alerts for your places when last checked.
- "…": Cache is still working the line out. Wait a moment.

Search box:
- "Nothing found" under the "Ask Cache:" row: nothing on your phone matches. Tap the "Ask Cache:" row to ask the assistant instead.

Shortcuts:
- "That chat is gone": the chat was deleted. Tap and hold the shortcut and choose "Remove from Home".
- "That page is not on this phone any more": the ZIM was removed. Remove the shortcut, or download the ZIM again.
- "Finish or end the route first": you are being guided. Tap "End" in "Maps" first.
- "Added to Home" or "Already on Home": the shortcut was added, or was there already.

## Ask messages

- "Choose a model at the top to start.": no model is loaded. Tap "Choose a model" (or "Get a model"), then load one.
- "No model" in the title: the same. Tap the title to open the model menu, then "Manage models".
- "Thinking…" and "Searching your sources…": the assistant is working. Wait, or tap "Stop".
- "No answer was produced.": the model gave nothing back. Ask again in other words, or start a "New chat". If it keeps happening, try a different model.
- "The model stopped without an answer": the same; ask again.
- "Not from your sources": the answer did not come from your phone's sources or a search. Check it before relying on it.
- "Navigation unavailable: this route snapshot is no longer available.": the route under an old answer has gone. Ask for directions again.
- "Report saved on this phone. Find it in Settings > Assistant.": your report was saved. The page is now called "Cache model and web search".
- "Chat deleted": tap "Undo" to bring it back.
- "No chats yet" or "No chats match": nothing saved yet, or nothing matches your search words.
- "All conversations deleted": every chat was removed.

## Location messages in Ask

Cache uses your location in "Ask" whenever the phone allows it. It does not ask. The "Use my location" switch is in the + menu to the left of the box where you type, and in "Settings" > "Cache model and web search". It is the same switch.

- "Use my location" is greyed out with "Blocked in the phone's settings": location is blocked for Cache. Tap "Open the phone's settings" and allow it.
- It is greyed out with "The phone's location is switched off": tap "Open the phone's settings" and turn location on.
- It is on but answers about places ignore where you are: check that the switch is on, and that "Show my position" in "Maps" > "Layers" is on.

If Cache cannot get a position yet, chat still works. Go outdoors or near a window and try again.

## Models messages

On the Models screen (tap the model name at the top of "Ask" and choose "Manage models"):
- "Not supported: Cache needs a model that can use tools": pick another model. The one you had stays loaded.
- "Too big for this phone": choose a smaller model. "May be tight on this phone" may work but can be slow or fail to load.
- "Can't read the models folder": close Cache and open it again. Check free space.
- "Could not copy the file: [reason]": the copy from "Choose a file" failed. Check free space and try again.
- "Could not delete the file: [reason]": try again after closing and opening Cache.
- "Loading…": the model is being loaded. Large models take a while.

Hugging Face:
- "Could not search Hugging Face. Check the connection and try again."
- "Could not list the files. Check the connection and try again."
- "No GGUF models match.": try other words, such as the model's family name.
- "This repository has no single-file GGUF models.": Cache cannot use it. Choose another.
- `This model needs a Hugging Face account to download. Get it in a browser, then use "Choose a file".`: download the file in a browser, then tap "Choose a file".
- "The download stopped: [reason]": check the connection and download again. It continues where it stopped.

## Search model messages

The search model (605 MB) lets Cache search by meaning. It comes with your first model download, as one line in the download pop-up.

- "Meaning search needs the search model." with "Get it": the search model is missing, or its download stopped. Open the Models screen. It shows this line under "On this phone". Tap "Get it" to download the search model.
- "Next: Search model, 605 MB": it will download after the current model.
- "Also downloads: Search model, 605 MB": it comes with the model you are about to download.
- "Search model: download stopped ([reason])": the line shows the reason. If it is about mobile data, connect to Wi-Fi first, then tap "Get it".
- "Meaning search needs the model [name].": a library uses a different search model that is not on this phone. Cache searches it by keywords. Cache cannot download that model for you.
- "Matching words only: the meaning search is not available": the places on this phone cannot be searched by meaning. Words still work.

## Download pop-up messages

Every download in Cache asks first in a pop-up with a storage bar. See the section Downloads, Wi-Fi and mobile data in chapter 1.

- "Wait for Wi-Fi": you are on mobile data and "Mobile data downloads" is off. This is the default. The download starts when you are on Wi-Fi.
- "Download now": goes ahead on mobile data this once.
- "Needs 28 GB more. Cache always leaves 20 GB for the phone." (the numbers change): the download will not fit. The button becomes "Free up space". Tap it to open "Storage" and remove things.
- "Waiting for Wi-Fi", "Paused" and "The download stopped" on a row: the download has not finished. See the section A download stopped.

Delete pop-ups say "Frees" and the size, and "You can download it again later." Tap "Delete" to confirm or "Cancel".

## Library messages

In "Library":
- "Nothing in your library yet. Add Wikipedia, medical guides, survival manuals or your own library, and read them with no signal.": tap "Add to Library".
- "Update ready": a newer version is available. Press and hold the item and choose "Check for update", or tap the "Update ready" badge.
- "[name] is up to date": no newer version.
- "That source is not on this phone any more.": the item was removed. Download it again.
- "Indexing", "Waiting to index" or "Building index": Cache is making the item searchable. See the section An index still building.

In "Add to Library":
- "Nothing found. Try another word, language or category.": change the search, the language chip, or the category.
- "Waiting for Wi-Fi", "Paused" or "The download stopped": see the sections Download pop-up messages and A download stopped.

## Kiwix catalogue messages

In "Library" > "Add to Library", when the catalogue cannot load:
- "Cannot reach the Kiwix library. Check the connection.": connect and tap "Try again".
- "Cannot make a secure connection to the Kiwix library.": the network may be blocking it, or the phone's date may be wrong. Try another network.
- "The Kiwix library took too long to answer.": try again later.
- "The library answered [code].", "The library redirected too many times.", "The library sent a redirect with no address.", "The library answered with something that is not a catalogue." or "The library could not be read: [reason]": a problem on Kiwix's side or the network's. Try again later or on another network.

## ZIM download messages

Seen while a Library item downloads. After most of these, tap "Try again"; a stopped download continues where it left off.

- "Not enough free space: [size] needed, [size] free.": free space in "Settings" > "Storage", or pick a smaller version ("Mini" or "No pictures").
- "The device is out of space. Free some and try again."
- "The download stopped early ([a] of [b]). Try again to continue."
- "The file did not match its published checksum, so it was thrown away. Try again.": the file was damaged on the way.
- "The connection failed: [reason]": check the connection.
- "Could not make a secure connection to the download server.": try another network.
- "The download server took too long to answer.": try again later.
- "That file is no longer on the download server.": a newer version may exist. Search the catalogue again.
- "The download server answered [code].", "The download server did not say how big the file is.", "The download server redirected too many times.", "The download server sent a redirect with no address." or "The download server continued from the wrong place. Try again.": a server problem. Try again later.
- "Could not write the file: [reason]": check free space.
- "Could not finish the download: [reason]" or "The download failed.": tap "Try again".

Progress words: "Starting…", "Downloading [a] of [b]", "Checking the file…", "Adding to your sources…".

## Reader messages

In the reader:
- "This ZIM could not be opened.": the file may be damaged. Delete it from the Library and add it again.
- "This ZIM is still being indexed. Text search works when that is done.": you can read pages now; search later.
- "That link is on the web. It is not available offline.": the link points outside the ZIM.
- "Nothing found.": try other words.

The assistant may say the sources are still being indexed, or that no sources have been added. Wait for indexing, or add something with "Add to Library".

## Your own library messages

On the "Your own library" screen ("Library" > "Add to Library" > "Your own library"):
- "Use a link that starts with https://": paste a full https link.
- "This file isn't a Cache library.": pick a .cache-library file or a library snapshot.
- "This is an empty library template. Fill it with your own entries first (see the README inside).": you added the blank template. Fill it first.
- "Could not read or write the file." or "The file could not be found.": try picking it again; check it is complete.
- "Its settings file could not be read." or "That settings file could not be read: [reason]": the cache-library.json is damaged. Get a fresh copy from whoever made the library.
- "Not enough free space on this device for the library.": free space and try again.
- "Search is not ready yet. Try again in a moment."
- "The search index could not be built": delete the library and add it again.
- "Could not write the library: [reason]" or "Could not remove the library: [reason]": check free space; close and reopen Cache.
- "The new copy could not be opened, so the library was kept as it was.": the update failed; the old copy still works.
- "Could not make the template: [reason]": try again.

States: "Opening", "Waiting to index", "Building index", "Not available". Steps while adding: "Checking…", "Putting it in place…" and percentages for downloading, unpacking and indexing.

Adding the same link again continues a download that was cut off.

## Map and layer messages

In "Maps":
- "No base map yet. Connect once to get the catalogue.": the map has no base layer yet. Connect to the internet once.
- "[layer] needs a connection here" or "[layer] needs a connection or a download here": this area of that layer is not on the phone. Connect, or download the region.
- "Maps need network access": your phone has switched network access off for Cache. Tap "Allow". If it still fails, tap "Open settings" and allow network access for Cache.
- "Copied": the coordinates were copied.
- `Location is off. Switch on "Show my position" in Layers.`: open "Layers" and turn on "Show my position".
- "Cache was not allowed to read your location.": tap "Find me" again and allow it.
- "Location is blocked for Cache. Allow it in the phone's settings.": tap "Settings" and allow location.
- "Your phone's location is switched off.": tap "Settings" and turn it on.
- "Could not get a position yet. Try again outdoors."
- "No position yet.": wait a moment and try again.

In the layer definition editor ("Settings" > "Maps" > "Advanced"):
- "A layer needs an id of lower-case letters, digits, - and _", "A layer needs a title", "A layer definition is a JSON object": fix the definition and tap "Save".

## Map search messages

In "Maps", under "Search places or coordinates":
- `Nothing found for "[words]"`: try other words, a nearby town, or coordinates.
- "No places on this phone.": no places are downloaded. Tap "Get a region" and download a region.
- "No places downloaded here.": tap "Get this area" to download the region you are looking at.
- "Getting places for this area…": wait; results appear by themselves.
- "Search failed": try again. If it keeps failing, close and reopen Cache.

## Directions and guidance messages

In the directions panel in "Maps":
- "Your position is not known yet. Turn on location to get directions from where you are.": tap "Find me" and allow location; go outdoors for a GPS fix.
- "No way found between these places": try another way of travel, or a nearby point on a road.
- "These places are too far apart for one trip": plan it in parts.
- "One of these places is outside the downloaded maps": download the region, or connect.
- "Off-road needs off-road data for this area": that data is not on this phone. Download the region for this area, or choose "Walk" or "Drive".
- "The off-road part of this trip is too long to work out": move the end closer to a road.
- "Working out the route took too long. Try again"
- "Could not get directions" or "Directions are not available in this build yet": try "Drive" or "Walk", or try again later.
- "Ignores land rules: the route may cross private or closed land.": shown with "Emergency: any land". Use it only in an emergency.

During guidance:
- "Getting your position": waiting for the first GPS fix. Go where the phone can see the sky.
- "Rerouting": you left the route; a new one is being worked out.
- "Arriving", then "You have arrived".

## Region list and region sheet messages

On the "Regions" sheet ("Maps" > "Layers" > "Download a region", or "Settings" > "Maps" > "Regions"). It has the tabs "Downloads", "Local" and "Updates":
- "The list of regions needs a connection the first time. After that it works offline.": connect and tap "Try again".
- "This country's regions need a connection the first time." or "Search needs a connection the first time.": connect once.
- "This region could not be read. Connect and try again."
- `No region called "[name]".`: try another spelling, or browse "Countries".
- "Nothing downloaded yet": pick a region under "Downloads".
- "Downloading needs a connection.": connect first.
- "Could not work out the size" or "Needs a connection to work out the size.": connect and open the region again.
- "This region has no outline yet.", "This region is too big to download the map in one go." or "No map layer that can be kept offline is switched on.": a region that cannot be downloaded shows a short reason like this in place of its download button.
- "On this phone": the region is already here. Nothing more to get.

## Region downloads paused or failed

On the "Regions" sheet, "Local" tab, a region may show:
- "Paused: no connection." or "Paused: no network it may use": connect, or use Wi-Fi. It carries on by itself.
- "Paused: mobile data is switched off for downloads. Connect to Wi-Fi to carry on.": connect to Wi-Fi, or turn on "Mobile data downloads" in "Settings" > "Storage".
- "Paused: [region] needs [size], [size] is free and [size] is kept free": Cache keeps some space free for the phone. Delete things you do not need ("Settings" > "Storage"), and it carries on.
- "Paused: [reason]; trying again shortly": wait; it tries again by itself.
- "Paused: could not move to [build]: [reason]" or "Paused: could not move places to [build]: [reason]": an update could not be put in place. Check free space; tap the region's update button again.
- "Could not be downloaded": tap the region's update button to try again.
- "Places not downloaded": the region was downloaded before places were part of regions. Update it.

Other texts you may see on a part:
- "the places server cannot be reached": check your connection and try again later.
- "update Cache to use this data: the places are in layout [n], this version reads [n]": the data is newer than this version of Cache. Update Cache.
- "the index of [build] does not match its checksum": the download was damaged. Update the region again.

## Weather status messages

The line at the top of "Settings" > "Weather and alerts" says how fresh the data is, for example "Updated 1 hour ago". When the data is old it turns into a warning, for example "Updated 3 days ago". Tap the small refresh button next to it to fetch again.

The box at the top of "Weather" says the same, and has an "Update now" button.

- "Nothing is switched on yet." on "Weather", or "Nothing switched on yet" in settings: turn on a source, or tap "Turn on weather".
- "Not updated yet": tap the refresh button, or "Update now" in "Weather".
- "Updated [when]": the data is fresh. "No connection since [day]" after it means you have been offline; Cache shows the last data.
- "Updates when you tap Update now, and when you ask the assistant": Cache could not schedule background updates. Tap "Update now" when you need fresh data.

On the "Weather" screen:
- "Not downloaded yet. Update now to get it.": tap "Update now".
- "Expired · [age] · needs a connection for more": old data. Connect and update.
- "Every day of this forecast has passed." or "No forecast.": update when you are online.
- "That alert has ended or is no longer in the data.": the alert is over.

## Update messages

After you tap "Update now" in "Weather", or the refresh button in "Settings" > "Weather and alerts", a short message says how it went.

- "Updated" or "Already up to date": all good.
- "Already updating": an update is running. Wait for it.
- "Switch on a source to update it.": nothing is on. Turn on a source.
- "No place is being watched.": open the Places notebook and turn on "Weather and alerts" for a place, or for "Where I am".
- "No connection. Update when you are online."
- "Updated, but [problem]": most sources updated; one did not.

Weather and alerts update on any connection, even with "Mobile data downloads" off.

When one source fails, the message reads "[provider] for [place] failed: [why]". What the reason means:
- "reached its limit for now": the source's request limit was reached. Wait and try later.
- "needs a key": tap "Get key" on the source's row in "Settings" > "Weather and alerts".
- "sent something Cache could not read": the provider changed or had a problem. Try later.
- "the service answered HTTP [code]": the provider refused or had a problem. If it is 401 or 403, replace the key.
- "couldn't be reached": check your connection.
- "couldn't update": try again later.

A source's own page (tap its row in "Settings" > "Weather and alerts") shows its "Last problem".

## Turn on weather messages

When you tap "Turn on weather" on "Weather" or "Home":
- "Use your location?": Cache explains why. Tap "Continue" to allow location, or "Not now" to choose a place instead.
- "Location is off. Choose a place instead.": pick a place in the sheet that opens.
- "Cache could not use your location. Choose a place instead.": the same.

In the "Choose a place" sheet:
- "No places match.": try another spelling or a nearby town.
- "Could not search for places.": check that places or a connection are available, then try again.
- "Could not save the place.": try again.

To keep a place for good, add it to the Places notebook.

## Data source messages

On a source's page (tap its row in "Settings" > "Weather and alerts"):
- "Data" "Out of date": the stored data is old. Update when online.
- "Last update" "Nothing downloaded yet": tap "Update now" on the "Weather" screen.
- "This source is no longer in the catalogue.": its catalogue dropped it.
- "Needs your own key": tap "Get key".

In "Settings" > "Weather and alerts":
- "Loading sources…": wait.
- "No sources downloaded yet. Connect to the internet and they load by themselves."
- "No source matches your search.": try other words, in the search box under "More sources".

Texts from the data engine, shown as a source's "Last problem" or in the status:
- "[source] has reached its limit of [n] downloads per [day]": Cache stops asking so the provider does not block you. It resumes after that time.
- An error that starts with HTTP 401 or HTTP 403 and ends with the words the key or login was refused: the provider refused the key. Replace the key.
- An error that starts with HTTP 429 and says rate limited: the provider asked Cache to slow down. Wait and try later.
- The response has no [part]: the provider changed its data. Wait for an updated source.

## Web search key messages

In the "Web search" sheet ("Settings" > "Cache model and web search" > "Set up" next to "Search service"):
- "Paste your key first.": the field is empty.
- "Kagi didn't accept this key. Check you copied all of it.": copy the whole key again.
- "Kagi says this account has no search credit left, or has reached its limit. Check your balance, then try again.": add credit in your Kagi account.
- "Couldn't reach Kagi. Check your connection."
- "Kagi had a problem (HTTP [code]). Try again in a moment."
- "Kagi answered with an error (HTTP [code])." or "Kagi answered with something Cache couldn't read. Try again later.": try later.
- "Couldn't check the key. Try again."
- "The key was accepted but couldn't be saved on this phone.": try again; restart Cache if it repeats.
- "Couldn't open the page. Go to [address]": open that address in your browser yourself.
- "Web search is on": it worked.
- "Key removed": the key was deleted and web search is off.

## Data source key messages

In the key sheet you open with "Get key" on a source's row ("Settings" > "Weather and alerts"). [Provider] is the company that gives the key.

- "Paste your key first.": the field is empty.
- "[Provider] didn't accept this key. Check you copied all of it.": copy the whole key again.
- "[Provider] didn't accept this key, or answered with something Cache couldn't read. Check you copied all of it."
- "[Provider] says this key has reached its limit. Try again later."
- "Couldn't reach [provider]. Check your connection."
- "[Provider] had a problem (HTTP [code]). Try again in a moment."
- "[Provider] answered with an error (HTTP [code])." or "[Provider] answered with something Cache couldn't read. Try again later."
- "This source needs no key.": nothing to add.
- "That key wasn't accepted." or "Couldn't check the key. Try again."
- "The key was accepted but couldn't be saved on this phone.": try again.
- "[source] is on" or "Key replaced": it worked.
- "Key removed": the key is gone and its sources are off.

## Catalogue messages

In "Settings" > "Weather and alerts" > "More sources" > "Add sources from a link" (at the bottom of the list):
- "Enter an address that starts with https://": paste the full link.
- "No connection. Connect to add a catalogue."
- "Couldn't check that link. Try again."
- "That address didn't give a connector catalogue.": the link is not a catalogue. Ask whoever gave it to you.
- "That catalogue is already added." or `A catalogue called "[name]" is already added.`
- "None of the sources in this catalogue can be used by this version of Cache."
- "This catalogue is in a newer format than this version of Cache can read. Update Cache to use it."
- "This catalogue is in a format Cache does not know."
- "Couldn't reach [site]. Check your connection.", "Couldn't make a secure connection to [site].", "Couldn't read from [site].", "[site] answered with an error (HTTP [code]).", "The file is larger than expected.": a network or server problem. Try later.
- "Left out ([n])": some sources could not be used. The reason is listed under each, for example "The file is not the one the catalogue lists (its checksum differs).". Tell the catalogue's publisher.
- "[name] added", "Removed", "Sources are up to date": it worked.
- "Couldn't load the catalogue.": the last good copy is kept.

## Notification messages

In "Settings" > "Notifications":
- "No pop-ups at all?": you chose "None" under "Pop up for". Cache will not interrupt you for anything, not even an evacuation order. Tap "Keep pop-ups" to go back, or "Turn off" to confirm. Alerts are still listed in "Weather".
- Location is not set here. The "Use my location" row is in "Settings" > "Cache model and web search". When the phone blocks location for Cache, that row says so and links to the phone's settings.

If alerts do not pop up, check three things: "Pop up for" is not "None", your phone allows notifications for Cache, and it is not inside your quiet hours. Serious alerts still ring in quiet hours.

## Video messages

In "Videos":
- "Can't reach the instance. Check the connection and try again."
- "That address doesn't look like a PeerTube instance.": check the address, for example tube.example.org.
- "The instance asked us to slow down. Try again in a minute."
- "The instance needs you to log in again.": open the instance's account button and tap "Log in".
- "This account needs its two-factor code." or "Enter the two-factor code.": type the code from your authenticator.
- "The user name or password is wrong."
- "That instance is not in the list." or "Not found on the instance.": the video or channel was removed.
- "No instances yet. Add the address of a PeerTube site to browse and watch its videos.": tap "Add an instance".
- "No channels", "No videos", "This channel has no videos": nothing to show there.

Downloading and playing:
- "Not enough free space on this phone.": free space.
- "The file did not arrive intact. Try again."
- "Download stopped." or "The download failed.": tap "Continue download" (on the video) or "Continue" (in "Saved videos").
- "Wait for Wi-Fi": you are on mobile data and "Mobile data downloads" is off.
- "This video has no file to download yet.": try later.
- "This file can't be played.": try another size, or play it online.
- "Can't play this video right now. Check the connection.": play the saved copy, or connect.
- "Nothing saved yet. Open a video and choose Download to watch it without a connection."

## Sharing and sync messages

In "Settings" > "Sharing and sync":
- "Paused: no network it may use": connect to Wi-Fi, or turn on "Mobile data downloads" in "Settings" > "Storage".
- "Local network only": Cache can reach devices on the same Wi-Fi only right now.
- "Not reachable": the other device is off, asleep, closed or offline. Open Cache on it.
- "Connected through a relay" or "Connected directly": linked and working.
- "Works once, for 15 minutes": make a new code with "Show my link code" if it has expired.

When linking fails, the message comes from the sharing engine:
- "this is not a Cache link code" or "the link code is damaged": copy the whole code again, with nothing missing.
- "that is this device's own code": enter it on the other device.
- "the other device did not answer" or "could not reach the other device: [reason]": make sure Cache is open on both devices and both are online; then try a new code.
- "the other device refused the link": make a fresh code on the other device.
- "could not start networking: [reason]": close Cache and open it again.

If a kind says the other device's files are bigger than the space you have, Cache fetches what fits and pauses. Free space and it carries on.

## Storage messages

In "Settings" > "Storage":
- "Measuring…": Cache is adding up the space. Wait a moment.
- "free space unknown": the phone did not say. Downloads still check before they start.
- "Wait for the downloads to finish, then clean up.": "Clean up" does not run while a download is going. Wait, then try again.
- "Nothing to clean up": no unfinished downloads, damaged files or temporary files.
- "Freed [size]": "Clean up" finished.

In "Settings" > "Credits and licences" > "Credits":
- "Couldn't load the credits.": close and reopen Cache.

## Notebook messages

In "Notebooks":
- "Notebooks could not open. Your entries are still on this phone.": tap "Try again". If it keeps happening, close Cache fully and open it again.
- "Could not make it: [reason]": the notebook was not made. Check free space and try again.
- "No notebooks yet. Make one with New notebook.": tap "New notebook".
- "Not saved. Your phone may be out of space.": free space and tap "Try again". Your text is kept until then.
- "This notebook is gone": it was deleted. Remove its shortcut from "Home".
- "You already have a notebook with this name.": choose another name.
- "Could not attach the file: [reason]": try again.
- "Entry deleted": tap "Undo" to bring it back.

## Offline: what still works

With no connection, these keep working:
- "Ask", with your model, Library, libraries and downloaded places. Web search does not.
- "Maps" for downloaded regions, place search with downloaded places, and road directions where the region is downloaded. GPS works without a connection.
- "Library" and the reader for items on the phone.
- "Notebooks".
- "Videos" saved on the phone ("Play saved copy").
- "Weather" shows the last data with its age. Old forecasts and alerts are marked as expired.
- Your chats, saved places and settings.

These need a connection:
- weather, alerts and fire updates;
- downloads of models, regions, Library items, libraries and videos;
- map layers that "Streams when online" or "Needs a connection" outside downloaded areas;
- web search;
- the first look at the list of regions and the Kiwix catalogue;
- linking devices over the internet.

If something says it needs a connection, it will work again once you are online.

## Mobile data: why a download did not start

Cache has one mobile data switch. It is "Mobile data downloads" in "Settings" > "Storage".

- Off (at first): big downloads wait for Wi-Fi. This covers models, regions, Library items, libraries, videos and sharing between your devices.
- On: big downloads also use mobile data.

Weather and alerts always update, on any connection. If weather is old, the cause is not this switch. See the section Weather status messages.

If a download is waiting because of the switch, the pop-up said so and offered "Wait for Wi-Fi". On the row it shows "Waiting for Wi-Fi".

What to do:
1. Connect to Wi-Fi, and it goes ahead; or
2. Tap "Download now" to use mobile data this once; or
3. Turn "Mobile data downloads" on to always allow it.

Changes apply at once, even to a download already running.

## Storage full

When the phone is low on space, downloads stop or refuse to start. The pop-up says how much more is needed, for example "Needs 28 GB more. Cache always leaves 20 GB for the phone." Its button is "Free up space". Cache keeps 10% of storage free for the phone, at least 5 GB and at most 20 GB. This is on purpose, and you cannot change it.

To free space:
1. Tap "Free up space" in the pop-up, or go to "Settings" > "Storage".
2. Tap "Clean up" first. It removes unfinished downloads, damaged files and temporary files. It never touches what you saved.
3. Open the row that uses the most: "Library", "Models", "Regions", "Notebooks" or "Videos and weather".
4. Remove items you do not need. Each removal asks you to confirm and shows what it frees.

Then go back and continue the download. Most downloads continue where they stopped.

## A download stopped

Most downloads in Cache continue where they stopped, so you do not lose what already arrived.

- Models: open the Models screen and download the same file again. A partly downloaded file shows how much is done and that it continues.
- Regions: they continue by themselves when the connection or space is back. Or open "Regions", tab "Local", and tap the region's update button.
- Library items: tap "Try again" on the item in "Add to Library", or "Resume" on its row.
- Libraries from a link: add the same link again.
- Videos: tap "Continue download" or "Continue".

Common reasons a download stops: the connection dropped, you are on mobile data with "Mobile data downloads" off, the phone ran out of space, or Cache was closed. Fix the reason, then continue.

## An index still building

After you add a ZIM or a library, Cache builds a search index for it in the background. Large ones can take a long time.

While it builds:
- the item's row in "Library" says "Indexing" or shows a percentage, and "Waiting to index" if it has not started;
- you can open and read a ZIM, but searching inside it says "This ZIM is still being indexed. Text search works when that is done.";
- a library's row says "Building the search index" with a percentage;
- the assistant may say the sources are still being indexed.

What to do: leave Cache open and wait. Keep the phone charged for big ones. If indexing fails ("Indexing failed" or "The search index could not be built"), delete the item and add it again.

An updated ZIM keeps the old copy working until the new one is indexed.
