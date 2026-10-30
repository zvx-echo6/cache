# 4. Services and keys

## Web search with Kagi

Kagi lets the assistant search the web when you're online. Without it, Cache answers from your offline sources and says when it can't search the web.

Kagi is paid. You need your own key. It costs $12 for every 1,000 searches (Kagi's API pricing page, checked 2026-10-29).

To get a key:
1. Sign in at kagi.com, or create an account.
2. Open https://kagi.com/api/keys, set up billing and add search credit.
3. Create a key and copy all of it.

To add it to Cache:
1. Go to ["Settings" > "Cache model and web search"](cache://settings/assistant).
2. Under "Web search", tap "Set up" next to "Search service".
3. Paste the key into "Key" and tap "Check and save".

Cache checks the key with one real search, turns web search on and says "Web search is on". The key stays on this phone and is never shown again.

- If saving fails, Cache says why. For example, "Kagi didn't accept this key. Check you copied all of it." or "Couldn't reach Kagi. Check your connection."
- If it says "Kagi says this account has no search credit left, or has reached its limit. Check your balance, then try again.", add credit.

Kagi's API terms: https://kagi.com/privacy/api

## Change or turn off web search

1. Go to ["Settings" > "Cache model and web search"](cache://settings/assistant).
2. To keep the key but stop searching, turn off "Search the web when online".
3. To replace or remove the key, tap "Change" on "Search service" and choose "Replace the key" or "Remove the key".

## Satellite fire hotspots with NASA FIRMS

NASA FIRMS reports possible fires seen by satellites, often hours before ground reports. Cache's "Satellite fire hotspots" source shows detections from the last day near your place, with time, confidence and fire power.

It's free. You need a free FIRMS map key.

To get a key:
1. Go to https://firms.modaps.eosdis.nasa.gov/api/map_key/ and choose Get MAP_KEY.
2. Enter your email address. NASA emails you the key.

One email address gets one key. To resend or change it, log in at the FIRMS download page.

To add it to Cache:
1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather).
2. Tap "Get key" on "Satellite fire hotspots".
3. Paste the key and tap "Check and save".

Limits: 5,000 transactions in any 10 minutes (NASA FIRMS, checked 2026-10-29). Cache stays far below that.

Detections are possible fires, not confirmed ones. Never wait for one before leaving if officials or what you see tell you to go.

## Idaho roads with Idaho 511

Idaho 511 gives road events and winter road conditions for Idaho. Two Cache sources use it: "Idaho 511 traffic events near the place" and "Idaho 511 winter road conditions". One key serves both.

Events are closures, crashes, incidents and roadwork. Conditions are dry, wet, snow, ice or closed. The road work zones source (WZDx) needs no key.

To get a key:
1. Create an account at https://511.idaho.gov.
2. Open https://511.idaho.gov/developers/doc and request a developer API key. It shows on that page.

Limit: ten calls every 60 seconds (Idaho 511 developer page, checked 2026-10-29). The page states no price.

To add it to Cache:
1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather) and open "More sources".
2. Tap "Get key" on "Idaho 511 traffic events near the place".
3. Paste the key and tap "Check and save".

## Traffic at a place with TomTom

TomTom's traffic data gives the current and normal speed on the road nearest a place, travel times, and whether the road is closed. Cache's "Traffic flow at the place (TomTom)" source uses it.

It's free up to 20,000 traffic flow requests a month, with no credit card. Beyond that TomTom charges per use (TomTom pricing page, checked 2026-10-29).

To get a key:
1. Sign up at https://my.tomtom.com/.
2. Create an API key and copy it.

To add it to Cache:
1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather) and open "More sources".
2. Tap "Get key" on "Traffic flow at the place (TomTom)".
3. Paste the key and tap "Check and save".

## Weather forecasts with Open-Meteo

Open-Meteo provides Cache's forecast: current conditions, tonight, and up to 16 days for any place in the world. No account or key is needed.

To switch it on:
1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather).
2. Turn on "Weather forecast".
3. Choose the places to watch in the Places notebook (chapter 5).

Forecasts download while online and stay for offline use until they expire. Cache says how old they are.

Terms (Open-Meteo terms page, checked 2026-10-29): the free service is for non-commercial use, such as personal apps without subscriptions or ads. Limits are under 10,000 calls a day, 5,000 an hour, 600 a minute and 300,000 a month per device or application. The data is CC BY 4.0, so Cache credits Open-Meteo. Cache updates each place about every three hours, far below those limits.

## Weather alerts with the National Weather Service

The National Weather Service (NWS) gives active watches, warnings and advisories for a place in the United States. That includes civil emergency and evacuation messages it sends. It's free with no key (NWS API documentation, checked 2026-10-29). Cache identifies itself to the service as the NWS asks.

To switch it on:
1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather).
2. Turn on "Weather alerts".

An empty list means only that the Weather Service lists none for that place. It doesn't cover local evacuation orders posted elsewhere, fires or road closures.

## Emergency alerts from FEMA (IPAWS)

IPAWS is FEMA's public alert feed. The phone would read it directly. It is free and needs no key.

This is coming in a later update. It is not in this version of Cache yet, so there is nothing to switch on today.

## Wildfires with WFIGS

The Wildland Fire Interagency Geospatial Services (WFIGS) group publishes current US wildfire incidents and perimeters through the National Interagency Fire Center's open data site. No account or key is needed.

The "Wildfires" switch turns on both:
- incidents near your place, largest first;
- perimeters, the fire's mapped edge.

To switch it on:
1. Go to ["Settings" > "Weather and alerts"](cache://settings/weather).
2. Turn on "Wildfires".

Fire data lags the fire. A perimeter is the last mapped edge, and fast fires can move miles between updates. If officials order you out or you see fire or heavy smoke, leave. Don't wait for the map.

## Earthquakes with the USGS

The U.S. Geological Survey's feeds list recent earthquakes worldwide. Cache has two sources: magnitude 2 or more near your place (300 km by default), and a past-day feed of magnitude 2.5 or more. No account or key is needed. The USGS asks automated apps to use its real-time feeds (USGS event service page, checked 2026-10-29).

To switch it on:
1. Go to ["Settings" > "Weather and alerts" > "More sources"](cache://settings/weather).
2. Turn on the earthquake source.

These report earthquakes that already happened. They are not warnings. After strong shaking, drop, cover and hold on until it stops. Then check for damage and gas leaks. Near a coast, move to high ground if the shaking was long or strong.

## Space weather with NOAA SWPC

NOAA's Space Weather Prediction Center publishes alerts, watches and warnings for solar flares, radiation storms and geomagnetic storms. It also gives the R, S and G scales, the planetary Kp index and the 10.7 cm solar flux, which sets HF radio conditions.

Cache has four sources for these. They aren't tied to a place. No account or key is needed (SWPC data service: services.swpc.noaa.gov, checked 2026-10-29).

To switch them on:
1. Go to ["Settings" > "Weather and alerts" > "More sources"](cache://settings/weather).
2. Turn on each SWPC source.

## River levels with NOAA NWPS and the USGS

NOAA's National Water Prediction Service (NWPS) gives river forecast gauges: the latest stage and flow, the next forecast and the flood category. None of these sources needs a key.

Cache has three sources:
- "River levels": gauges within 40 miles of your place, nearest first;
- a full forecast for one gauge, chosen by its id (for example BIGI1);
- for Idaho only, the latest flow and gage height from USGS stream gages within 60 miles.

To switch them on:
1. Go to ["Settings" > "Weather and alerts" > "More sources"](cache://settings/weather).
2. Turn on each river source.

Flow is in cubic feet per second (cfs; kcfs is thousands). Never judge a crossing safe from a gauge. Six inches of moving water can knock a person down and a foot can carry a car away. Turn around.

## Road work zones in Idaho (WZDx)

Idaho publishes road work zones and lane closures in the Work Zone Data Exchange (WZDx) format. Cache's "Road work zones near the place, Idaho (WZDx)" source shows the most restrictive first, then the nearest. No key is needed.

To switch it on:
1. Go to ["Settings" > "Weather and alerts" > "More sources"](cache://settings/weather).
2. Turn on "Road work zones near the place, Idaho (WZDx)".

## Adding more sources: the catalogue

Every source comes from the Cache connectors catalogue, which the app downloads when online. Nothing is on until you choose it.

- Featured sources are first in ["Settings" > "Weather and alerts"](cache://settings/weather). The rest are under "More sources".
- A source that needs a key has a "Get key" button.
- To add someone else's catalogue, tap "Add sources from a link" at the bottom of "More sources" and paste its address. Cache checks every source and adds nothing until you say so.
- "Catalogues in use" lists the catalogues. "Check for updates" looks for new and changed sources.

## Libraries from Kiwix

Kiwix publishes free offline copies of Wikipedia, medical guides and how-to sites as ZIM files.

1. [Open "Library" and tap "Add to Library"](cache://library/add).
2. Search the catalogue, or use the language and category chips such as "Medicine" or "Preparedness".
3. Download from "Ready-made collections · free from Kiwix".

Every download asks first, with its size. Large files can be several gigabytes. Wikipedia comes with pictures (maxi) or without (nopic). The versions without pictures are much smaller.

Each new ZIM is indexed in the background, which can take a while.

- If you're on mobile data, it waits for Wi-Fi unless you allow mobile data.

## Models from Hugging Face

Cache's assistant runs a model on your phone. Models download from Hugging Face.

1. Tap the model name at the top of "Ask" and choose "Manage models".
2. Tap "Search Hugging Face", or "Choose a file" for a .gguf file you already have.

Cache shows each file's size and whether it fits this phone. It lists single-file GGUF models only.

- If a model is marked "Not supported: Cache needs a model that can use tools", pick another.
- If a model needs a Hugging Face account, get it in a browser, then use "Choose a file".

## Videos from PeerTube

Cache's Videos module plays videos from PeerTube sites, which anyone can run.

1. Open "Videos" and tap "Add an instance".
2. Type the site's address, for example tube.example.org.

Logging in is optional. You only need it for videos the site keeps for members. You can save videos for offline viewing. Smaller sizes save space.
