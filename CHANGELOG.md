# Changes

What changed in Cache, newest first. Each change is one short bullet under Unreleased when it is merged. When a build goes
out, Unreleased becomes that build's section, and its bullets are the testers' notes (TestFlight "What to test", Google Play
release notes).

## Unreleased

### New
- Regions include places and addresses for map search
- Map search says when places for the area are missing or on their way, and offers the region
- The search model (605 MB) now comes with your first chat model and gives meaning search to maps, the library and the assistant
- Assistant: can save places, watch places for weather and start navigation after you confirm on a card
- Add a library from a file on the device or a download link, in Library > Libraries
- A newer copy of a library you have is offered as an update and swapped in safely
- Remove a library, and see its size, entries and whether it is ready
- Get a blank library template to build your own library
- Weather: turn it on in one tap from the Weather screen or Home
- A place you save is watched for weather and alerts
- Models starts with a short list of recommended models, each with its size and whether it fits your phone
- Maps: off-road directions on foot or by vehicle, with a land-access choice, where off-road data is installed

### Fixed
- iPhone: free space matches iPhone Storage in Settings, so downloads (libraries, Wikipedia, models, maps) are no longer refused when there is room
- Regions: the keyboard no longer pops up after the download sheet closes
- Unload the model in use from Models to free memory
- The keyboard closes when you tap outside a text box or scroll
- With no model, the Ask screen has a button to get or choose one
- Model names show the right quantisation in more cases
- iPhone: the Hugging Face file list shows whether each file fits your phone

## 1.0.0 (iOS build 22) - 2026-10-28

### Fixed
- iPhone: Cache no longer closes as soon as it opens

## 1.0.0 (iOS build 21, Android 3) - 2026-10-28

### New
- Find and download models from Hugging Face
- Weather module with forecast, alerts and wildfires for your places
- Weather and alerts update in the background
- Pop-up alerts for new warnings and fires near your places
- Sharing and sync between your devices
- Weather answers for today, tonight, tomorrow or any day
- Tonight's low from the hourly forecast
- Download regions for offline road routing and maps
- Regions at every size, from part of a state to a country
- Routes online without downloading anything first
- Modules screen shows app icons; tap and hold for options
- Small or large module icons in Settings > Appearance

### Fixed
- Interrupted downloads no longer leave broken files
- Unfinished model downloads stay hidden until done
- Restarting a cancelled library download no longer deletes it
- Search indexes of removed books are cleaned up
- Settings are always saved whole

## 1.0.0 (iOS build 18, Android 2) - 2026-10-28

### New
- New Cache look, icons and themes
- Settings rebuilt into groups with their own pages
- Report this answer in Ask
