# What the host draws and what Cache controls (Android Auto, Car App Library 1.7.0)

Checked against the 1.7.0 sources (`androidx.car.app:app:1.7.0`). Cache draws the map surface (CarMapRenderer, the climb card and mini map on it). Everything below is a template the host draws.

## Guidance screen (NavigationTemplate, in NavigationScreen)

| Part | Who draws it | What Cache controls | API |
|---|---|---|---|
| Guidance card | Host | Its background color, as a light and a dark variant. The host may ignore or override it for contrast. | `NavigationTemplate.Builder.setBackgroundColor(CarColor)` with `CarColor.createCustom(int color, int colorDark)`, fed from the trip palette's `hostCard` (day = light, night = dark). Tactical's is a dark red. |
| Card text, fonts, sizes, layout | Host | Nothing. | fixed |
| Current step | Host | The cue, the road, the maneuver type and its icon, the distance to it (host formats it in the phone's units). | `RoutingInfo.Builder.setCurrentStep(Step, Distance)`, `Step.Builder(CharSequence).setManeuver(Maneuver).setRoad(CharSequence)` |
| Next step | Host | The step after (cue, road, maneuver). | `RoutingInfo.Builder.setNextStep(Step)` |
| Lanes, lanes image, junction image | Host | Not sent: the phone's guidance has no lane data. | `Step.Builder.addLane(Lane)`, `Step.Builder.setLanesImage(CarIcon)`, `RoutingInfo.Builder.setJunctionImage(CarIcon)` exist in 1.7.0 |
| Arrival time, remaining time, remaining distance | Host (its own labels and format) | The three values only: arrival as a time with the phone's time zone, remaining seconds, remaining distance. | `TravelEstimate.Builder(Distance, DateTimeWithZone)`, `DateTimeWithZone.create(long, TimeZone)`, `setRemainingTimeSeconds(long)`; set with `NavigationTemplate.Builder.setDestinationTravelEstimate(TravelEstimate)` |
| Color of the remaining time and distance text | Host | Cannot be themed: 1.7.0 accepts only standard colors (default, primary, secondary, red, green, blue, yellow), not custom ones. Left at the default. | `TravelEstimate.Builder.setRemainingTimeColor(CarColor)` and `setRemainingDistanceColor(CarColor)` (`CarColorConstraints.STANDARD_ONLY`) |
| Action strip look (button shape, size, placement) | Host | Which actions, their titles and icons, their order, and what each does. At most 4 actions. | `NavigationTemplate.Builder.setActionStrip(ActionStrip)`, `Action.Builder` |
| Map buttons look | Host | Which buttons: Pan, Recenter (after the map was moved), zoom in, zoom out. | `NavigationTemplate.Builder.setMapActionStrip(ActionStrip)`, `Action.PAN`, `setPanModeListener(PanModeListener)` |
| Arrival and rerouting messages | Host (as a card) | The words. | `MessageInfo.Builder(CharSequence).setText(CharSequence)` |
| Cluster and head-up display | Host | The trip: destination, steps, estimates, road. | `NavigationManager.updateTrip(Trip)` |
| Status bar, clock, the rail | Host / car | Nothing. | fixed |

## Other screens

| Screen | Template | Notes |
|---|---|---|
| Home | `NavigationTemplate` with no navigation info | The whole map. Cache sets two icon buttons (Search, Saved places) and the map buttons. |
| Saved places, route overview, route choice | `MapWithContentTemplate` + `ListTemplate` | The host draws the list and header; Cache sets rows, titles, the header action, and the map controller. |
| Search | `SearchTemplate` | Host keyboard and list. |
| Rows' times and distances | Host formats | `DurationSpan.create(long)`, `DistanceSpan.create(Distance)` in a row's text. |

## What Cache draws itself (on the map surface)

The map, the route, the driven path, the grade badge, the climb-ahead card and the route mini map. Colors for these come from the same trip palette (`day` and `night`), chosen by the car's `isDarkMode`.
