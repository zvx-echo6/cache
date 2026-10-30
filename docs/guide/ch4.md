# 4. Services and keys

## Web search with Kagi

Kagi is the web search service Cache uses when the phone is online. With it, the assistant can answer questions your libraries cannot, such as current news, prices or recent events. It is a paid service and you need your own key. Without a key, Cache still answers from your offline sources and says plainly when it cannot search the web.

Cost: Kagi charges $12 for every 1,000 searches (Kagi's API pricing page, checked 2026-10-29). You pay only for what you use.

Get a key:
1. Sign in to Kagi at kagi.com (create an account if you do not have one).
2. Open the API dashboard at https://kagi.com/api/keys, set up billing and add search credit.
3. Create a key there and copy all of it.

Add it to Cache:
1. Go to "Settings" > "Cache model and web search".
2. Under "Web search", tap "Set up" next to "Search service".
3. Paste the key into "Key" and tap "Check and save".

Cache checks the key with one real search, then turns web search on and says "Web search is on". The key stays on this phone and is not shown again. To replace or remove it, tap "Change" on the same row and choose "Replace the key" or "Remove the key".

If saving fails, Cache says why. "Kagi didn't accept this key. Check you copied all of it." means part of the key is missing or wrong. "Kagi says this account has no search credit left, or has reached its limit. Check your balance, then try again." means the account needs more credit. "Couldn't reach Kagi. Check your connection." means there is no connection right now.

To turn web search off and keep the key, use the switch "Search the web when online".

Kagi's API terms: https://kagi.com/privacy/api

## Satellite fire hotspots with NASA FIRMS

NASA FIRMS reports possible fires detected by the VIIRS satellites, often hours before they are reported on the ground. Cache's "Satellite fire hotspots" source shows detections from the last day near the place, with time, confidence and fire power.

Cost: free. You need a free FIRMS map key.

Get a key:
1. Go to https://firms.modaps.eosdis.nasa.gov/api/map_key/ and choose Get MAP_KEY.
2. Enter your email address. NASA emails the key to you. One email address can have only one key; to resend or change it, log in at the FIRMS download page.

Limits: 5,000 transactions in any 10 minutes; larger requests can count as several (NASA FIRMS, checked 2026-10-29). Cache's source stays far below that.

Add it to Cache:
1. Go to "Settings" > "Weather and alerts".
2. Find "Satellite fire hotspots" and tap "Get key" on its row.
3. Paste the key and tap "Check and save".

Saving checks the key with one real download and switches the source on.

Satellite detections are possible fires, not confirmed ones, and a cloud or a hot industrial site can show up too. Never wait for a detection before leaving if officials or what you see tell you to go.

## Idaho roads with Idaho 511

Idaho 511 gives road events (closures, crashes, incidents and roadwork) and winter road conditions (dry, wet, snow, ice, closed) for Idaho. Two Cache sources use it: "Idaho 511 traffic events near the place" and "Idaho 511 winter road conditions". One key serves both. The road work zones source (WZDx) needs no key.

Get a key:
1. Create an account at https://511.idaho.gov (sign up, or log in if you have one).
2. Open the developer page at https://511.idaho.gov/developers/doc and request a developer API key. The key is shown on that page.

Limits: ten calls every 60 seconds (Idaho 511 developer page, checked 2026-10-29). The page does not state a price.

Add it to Cache:
1. Go to "Settings" > "Weather and alerts" and open "More sources".
2. Find "Idaho 511 traffic events near the place" and tap "Get key" on its row.
3. Paste the key and tap "Check and save".

## Traffic at a place with TomTom

TomTom's traffic flow data gives the current speed on the road nearest a place, the normal speed, travel times and whether the road is closed. Cache's "Traffic flow at the place (TomTom)" source uses it.

Cost: free up to 20,000 traffic flow requests a month, with no credit card required; beyond that TomTom charges per use (TomTom pricing page, checked 2026-10-29).

Get a key:
1. Sign up at https://my.tomtom.com/.
2. Create an API key in your TomTom account and copy it.

Add it to Cache:
1. Go to "Settings" > "Weather and alerts" and open "More sources".
2. Find "Traffic flow at the place (TomTom)" and tap "Get key" on its row.
3. Paste the key and tap "Check and save".

## Weather forecasts with Open-Meteo

Open-Meteo provides Cache's weather forecast: current conditions, tonight, and a daily outlook up to 16 days for any place in the world. No account or key is needed.

Terms (Open-Meteo terms page, checked 2026-10-29): the free service is for non-commercial use only, such as personal apps and apps without subscriptions or ads, with fewer than 10,000 calls a day, 5,000 an hour, 600 a minute and 300,000 a month per device or application. The data is licensed CC BY 4.0, so Cache credits Open-Meteo. Cache stays far below those limits: it updates each watched place about every three hours.

Switch it on: go to "Settings" > "Weather and alerts" and turn on "Weather forecast". Choose the places to watch in the Places notebook (see chapter 5). Forecasts are downloaded while online and kept for offline use until they expire; Cache always says how old they are.

## Weather alerts with the National Weather Service

The National Weather Service (NWS) API gives the active watches, warnings and advisories for a place in the United States, including civil emergency and evacuation messages officials send through the Weather Service. It is free and needs no key (NWS API documentation, checked 2026-10-29); Cache identifies itself to the service as the NWS asks.

Switch it on: go to "Settings" > "Weather and alerts" and turn on "Weather alerts". An empty alert list means only that the Weather Service lists none for that place. It does not cover local evacuation orders posted elsewhere, fires or road closures.

## Emergency alerts from FEMA (IPAWS)

IPAWS is FEMA's public alert feed. The phone would read it directly. It is free and needs no key.

This is coming in a later update. It is not in this version of Cache yet, so there is nothing to switch on today.

## Wildfires with WFIGS

The Wildland Fire Interagency Geospatial Services (WFIGS) group publishes the current wildfire incidents and fire perimeters for the United States through the National Interagency Fire Center's open data site. Cache's "Wildfires" switch turns on both: incidents near the place, largest first, and the perimeters (the fire's mapped edge). No account or key is needed.

Switch it on: go to "Settings" > "Weather and alerts" and turn on "Wildfires".

Fire data lags the fire. A perimeter is the last mapped edge, not where the fire is now, and fast fires can move miles between updates. If officials order you out or you see fire or heavy smoke, leave; do not wait for the map.

## Earthquakes with the USGS

The U.S. Geological Survey's earthquake feeds list recent earthquakes worldwide. Cache has two sources: earthquakes of magnitude 2 or more near the place (300 km by default), and a past-day feed of magnitude 2.5 or more. No account or key is needed; the USGS asks automated apps to use its real-time feeds (USGS event service page, checked 2026-10-29).

Switch it on: go to "Settings" > "Weather and alerts" > "More sources" and turn on the earthquake source.

These are reports of earthquakes that already happened, not warnings. After strong shaking: drop, cover and hold on until it stops, then check for damage and gas leaks; near a coast, move to high ground if the shaking was long or strong.

## Space weather with NOAA SWPC

NOAA's Space Weather Prediction Center publishes alerts, watches and warnings for solar flares, radiation storms and geomagnetic storms, the current space weather scales (R, S and G), the planetary Kp index and the 10.7 cm solar flux, which sets HF radio conditions. Cache has four sources for these; they are not tied to a place. No account or key is needed (SWPC data service: services.swpc.noaa.gov, checked 2026-10-29).

Switch them on: go to "Settings" > "Weather and alerts" > "More sources", then turn on each SWPC source.

## River levels with NOAA NWPS and the USGS

NOAA's National Water Prediction Service (NWPS) gives river forecast gauges: the latest observed stage and flow, the next forecast and the flood category. Cache's "River levels" source shows gauges within 40 miles of the place, nearest first. A second source gives the full forecast for one gauge, chosen by its id (for example BIGI1). A third source, for Idaho only, gives the latest river flow and gage height from USGS stream gages within 60 miles. None needs a key.

Switch it on: go to "Settings" > "Weather and alerts" > "More sources" and turn on each river source.

Flow is in cubic feet per second (cfs; kcfs is thousands). Never judge a crossing safe from a gauge: six inches of moving water can knock a person down and a foot can carry a car away. Turn around.

## Road work zones in Idaho (WZDx)

Idaho publishes its road work zones and lane closures in the national Work Zone Data Exchange (WZDx) format. Cache's "Road work zones near the place, Idaho (WZDx)" source shows the most restrictive ones first, then the nearest. No key is needed.

Switch it on: go to "Settings" > "Weather and alerts" > "More sources" and turn on "Road work zones near the place, Idaho (WZDx)".

## Adding more sources: the catalogue

All of these sources come from the Cache connectors catalogue, which the app downloads when online. Nothing is switched on until you choose it. To see every source, go to "Settings" > "Weather and alerts": featured sources are listed first, and the rest are under "More sources". A source that needs a key has a "Get key" button on its row. Someone else can publish their own catalogue: at the bottom of the "More sources" list, tap "Add sources from a link" and paste its address. Cache checks every source in it and adds nothing until you say so. "Catalogues in use", in the same place, lists the catalogues on the phone, and "Check for updates" looks for new and changed sources.

## Libraries from Kiwix

Kiwix publishes free offline copies of Wikipedia, medical guides, how-to sites and more as ZIM files. In Cache, open "Library", tap "Add to Library", then search the catalogue or use the language and category chips (for example "Medicine" or "Preparedness"), and download from "Ready-made collections · free from Kiwix". Large files can be several gigabytes; every download asks first in a pop-up with its size, and on mobile data it waits for Wi-Fi unless you allow mobile data. Wikipedia comes in versions with pictures (maxi) and without (nopic); the versions without pictures are much smaller. Each new ZIM is indexed for search in the background, which can take a while.

## Models from Hugging Face

Cache's assistant runs a language model on the phone. Models are downloaded from Hugging Face: from the "Ask" screen, tap the model name at the top and choose "Manage models", then "Search Hugging Face", or "Choose a file" to add a .gguf file you already have. Cache shows each file's size and whether it fits this phone, and only lists single-file GGUF models. Cache needs a model that can use tools; others are marked "Not supported: Cache needs a model that can use tools". Some models need a Hugging Face account to download: get those in a browser, then use "Choose a file".

## Videos from PeerTube

Cache's Videos module plays videos from PeerTube sites, which anyone can run. Add a site with "Add an instance" and its address (for example tube.example.org). Logging in is optional and only needed for videos the site keeps for members. Videos can be saved on the phone for offline viewing; smaller sizes save space.
