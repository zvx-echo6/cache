// The car link's rules, checked on a Mac on recorded messages: the messages are the ones in tools/carplay-harness/recorded,
// whose shape app/test/car_test.dart holds to what the phone's Dart side really sends. Compiled with the product's own
// CarTrip.swift and CarLink.swift (app/ios/Runner/CarPlay), which need no Flutter for this.
//
//   swiftc CarTrip.swift CarLink.swift main.swift -o car-tests && ./car-tests <folder of recorded messages>
import CoreGraphics
import Foundation

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String) {
  checks += 1
  if !ok {
    failures += 1
    print("FAILED: \(what)")
  }
}

func recorded(_ name: String) -> Any {
  let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
  let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
  guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) else {
    print("FAILED: could not read \(url.path)")
    exit(1)
  }
  return value
}

func map(_ name: String) -> [String: Any] {
  recorded(name) as? [String: Any] ?? [:]
}

func isNumber(_ a: Double?, _ b: Double) -> Bool {
  a == b
}

func isWhole(_ a: Int64?, _ b: Int64) -> Bool {
  a == b
}

func near(_ a: Double?, _ b: Double, _ within: Double = 1e-9) -> Bool {
  guard let a = a else { return false }
  return abs(a - b) <= within
}

/// Lets what was put on the main queue run (the link answers there when Dart is not ready).
func turn() {
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

final class Heard: CarLinkListener {
  var trips: [CarTrip] = []
  var routes: [(String, [Double]?)] = []
  var notices: [String] = []
  var ready = 0
  var saved = 0
  var styles = 0
  func carLinkTrip(_ trip: CarTrip) { trips.append(trip) }
  func carLinkRoute(geojson: String, bounds: [Double]?) { routes.append((geojson, bounds)) }
  func carLinkNotice(_ text: String) { notices.append(text) }
  func carLinkDartReady() { ready += 1 }
  func carLinkSavedChanged() { saved += 1 }
  func carLinkStyleChanged() { styles += 1 }
}

// ---- the trip model -------------------------------------------------------------------------------------------------

let nothing = CarTrip.from([:])
check(nothing == CarTrip.empty, "an empty message is the empty trip")
check(nothing.phase == "browsing" && nothing.voiceOn && !nothing.available, "the empty trip browses, with the voice on")

let browsing = CarTrip.from(map("trip_browsing.json"))
check(browsing.phase == "browsing" && !browsing.guiding && !browsing.previewing, "browsing: the phase")
check(browsing.available && browsing.imperial, "browsing: available, in miles")
check(browsing.destinationName == nil && browsing.routes.isEmpty && browsing.step == nil, "browsing: no destination, no routes, no step")
check(isNumber(browsing.lat, 10.5) && isNumber(browsing.lon, 20.2), "browsing: the position")
check(browsing.heading == nil, "browsing: parked, so no heading")

let previewing = CarTrip.from(map("trip_previewing.json"))
check(previewing.previewing && !previewing.guiding, "previewing: the phase")
check(previewing.destinationName == "Regional Hospital" && previewing.destinationAddress == "1501 Example Ave", "previewing: the destination")
check(isNumber(previewing.destinationLat, 10.56) && isNumber(previewing.destinationLon, 20.28), "previewing: where the destination is")
check(previewing.routes.count == 2, "previewing: two routes")
check(previewing.routes.first == CarRoute(index: 0, distanceM: 25400.5, durationS: 1260, via: "Via Road 0"), "previewing: the first route")
let second = previewing.routes.last
check(second?.via == nil, "previewing: a route with no main road")
check(second?.index == 1, "previewing: the second route's number")
check(previewing.routeId == "route-0", "previewing: the chosen route's name")
check(previewing.routeIndex == 0, "previewing: which route is chosen")
check(previewing.step == nil && previewing.remainingM == nil && previewing.etaMs == nil, "previewing: no guidance fields")

let guiding = CarTrip.from(map("trip_guiding.json"))
check(guiding.guiding, "guiding: the phase")
check(guiding.step == CarStep(turn: "left", type: "left", cue: "Turn left onto Road 1.", road: "Road 1", distanceM: 320.4), "guiding: the next maneuver")
let after = guiding.then
check(after?.turn == "right", "guiding: the one after")
check(after?.road == "Road 2", "guiding: the road of the one after")
check(guiding.currentRoad == "Road 0", "guiding: the road now")
check(isNumber(guiding.remainingM, 22860.45) && isWhole(guiding.remainingS, 1134), "guiding: what is left")
check(isWhole(guiding.etaMs, 1_794_168_000_000), "guiding: the arrival time")
check(!guiding.arrived && !guiding.rerouting && guiding.voiceOn, "guiding: not arrived, not rerouting, the voice on")

// The Android rules for values of the wrong kind.
check(!CarTrip.from(["available": 1]).available, "a number is not a yes")
check(CarTrip.from(["available": true]).available, "true is a yes")
check(CarTrip.from(["voiceOn": NSNull()]).voiceOn, "the voice is on unless the message says false")
check(!CarTrip.from(["voiceOn": false]).voiceOn, "the voice is off when the message says false")
check(CarTrip.from(["units": "metric"]).imperial == false, "kilometers")
check(CarTrip.from(["routeIndex": true]).routeIndex == 0, "a yes is not a number")
let blankAddress: [String: Any] = ["name": "A", "address": "   "]
check(CarTrip.from(["destination": blankAddress]).destinationAddress == nil, "an address of spaces is no address")
let bareStep: [String: Any] = ["cue": "Go", "road": ""]
check(CarTrip.from(["step": bareStep]).step == CarStep(turn: "straight", type: "", cue: "Go", road: nil, distanceM: 0), "a step's defaults")
let mixedRoutes: [Any] = [["index": 2], "not a route", NSNull()]
check(CarTrip.from(["routes": mixedRoutes]).routes == [CarRoute(index: 2, distanceM: 0, durationS: 0, via: nil)], "a route's defaults; what is not a route is left out")

let places = CarPlace.list(recorded("saved.json"))
check(places.count == 3, "three saved places")
check(places.first == CarPlace(id: "place:10.500000,20.500000", name: "Regional Hospital", address: "1501 Example Ave", lat: 10.5, lon: 20.5, distanceM: 25400.5), "the first saved place")
check(places[1].distanceM == nil && places[2].address == nil, "no distance; an address of spaces is none")
let noLongitude: [String: Any] = ["id": "x", "lat": 1.0]
let noId: [String: Any] = ["name": "no id", "lat": 1.0, "lon": 2.0]
let notPlaces: [Any] = [noLongitude, noId, "text"]
check(CarPlace.list(notPlaces).isEmpty, "a place needs an id, a latitude and a longitude")
check(CarPlace.list(NSNull()).isEmpty && CarPlace.list(nil).isEmpty, "no list is an empty list")

// ---- the words of a list row: the distance as the phone writes it, and the line under a place's name ---------------

let distanceRows: [Any] = recorded("distances.json") as? [Any] ?? []
check(distanceRows.count > 10, "the table of distances is there")
for entry in distanceRows {
  let row: [String: Any] = entry as? [String: Any] ?? [:]
  let meters: Double = CarValue.double(row["meters"]) ?? -1
  let imperial: Bool = CarValue.isTrue(row["imperial"])
  let want: String = row["text"] as? String ?? "?"
  let got: String = CarText.distance(meters, imperial: imperial)
  check(got == want, "the distance \(meters) m, imperial \(imperial): '\(got)', wanted '\(want)'")
}
check(CarText.distance(-5, imperial: false) == "0 m", "a distance below nothing is nothing")
if places.count == 3 {
  let both: String? = places[0].detail(imperial: true)
  let bothMetric: String? = places[0].detail(imperial: false)
  let addressOnly: String? = places[1].detail(imperial: true)
  let distanceOnly: String? = places[2].detail(imperial: true)
  check(both == "16 mi · 1501 Example Ave", "a place's line: the distance and the address")
  check(bothMetric == "25 km · 1501 Example Ave", "a place's line in kilometres")
  check(addressOnly == "Saved place", "a place's line: the address alone")
  check(distanceOnly == "38 mi", "a place's line: the distance alone")
}
let bare = CarPlace(id: "x", name: "Somewhere", address: nil, lat: 1, lon: 2, distanceM: nil)
check(bare.detail(imperial: true) == nil, "a place with no distance and no address has no line")
let durationRows: [Any] = recorded("durations.json") as? [Any] ?? []
check(durationRows.count > 10, "the table of times is there")
for entry in durationRows {
  let row: [String: Any] = entry as? [String: Any] ?? [:]
  let seconds: Int64 = CarValue.number(row["seconds"])?.int64Value ?? -1
  let want: String = row["text"] as? String ?? "?"
  let got: String = CarText.duration(seconds)
  check(got == want, "the time \(seconds) s: '\(got)', wanted '\(want)'")
}
if previewing.routes.count == 2 {
  let firstLine: String = previewing.routes[0].title(imperial: true)
  let secondLine: String = previewing.routes[1].title(imperial: false)
  check(firstLine == "21 min · 16 mi", "a route's line: its time and distance")
  check(secondLine == "23 min · 27 km", "a route's line in kilometres")
}
// ---- what CarPlay is given while guiding: a distance as a number and a unit, and the times -----------------------------

let nearTurn = CarText.measure(320.4, imperial: true)
check(nearTurn.value == 0.2 && nearTurn.unit == "mi" && nearTurn.tenths, "a distance for CarPlay: tenths of a mile")
let veryNear = CarText.measure(100, imperial: true)
check(veryNear.value == 350 && veryNear.unit == "ft" && !veryNear.tenths, "a distance for CarPlay: feet")
let farMetric = CarText.measure(25400.5, imperial: false)
check(farMetric.value == 25 && farMetric.unit == "km" && !farMetric.tenths, "a distance for CarPlay: whole kilometres")
let nearMetric = CarText.measure(349, imperial: false)
check(nearMetric.value == 350 && nearMetric.unit == "m", "a distance for CarPlay: metres")
let nearLength = CarText.length(320.4, imperial: true)
check(nearLength.value == 0.2 && nearLength.unit == UnitLength.miles, "a length for CarPlay: the phone's number, in miles")
let farLength = CarText.length(25400.5, imperial: false)
check(farLength.value == 25 && farLength.unit == UnitLength.kilometers, "a length for CarPlay: in kilometres")
check(guiding.leftSeconds == 1134, "the time left is the phone's")
if let nextTurn = guiding.step {
  // 320.4 m of 22860.45 m left, of 1134 s: 16 s.
  check(guiding.turnSeconds(nextTurn) == 16, "the time to the turn is its share of the time left")
}
let lastStretch: [String: Any] = ["phase": "guiding", "remainingS": 20, "remainingM": 150.0]
let arrivedMessage: [String: Any] = ["phase": "guiding", "remainingS": 0, "remainingM": 0.0, "arrived": true]
check(CarTrip.from(lastStretch).leftSeconds == 60, "under a minute left reads as one minute")
check(CarTrip.from(arrivedMessage).leftSeconds == 0, "arrived: no time left")
check(CarTrip.from([:]).leftSeconds == nil, "no time left known")
// ---- the panel's second row, from the room CarPlay reports ----------------------------------------------------------

// What CarPlay took from the leading edge at the four screens the harness runs, with no panel and with one, and their heights.
check(CarPanel.width(withPanel: 225, plain: 49, dockAtBottom: false) == 176, "the panel's width where the turn card is stacked: 176")
check(CarPanel.width(withPanel: 273, plain: 49, dockAtBottom: false) == 224, "and where it is one line: 224")
check(CarPanel.width(withPanel: 176, plain: 0, dockAtBottom: true) == 176, "the panel's width on the upright screen, where the dock is at the bottom")
check(CarPanel.width(withPanel: nil, plain: 49, dockAtBottom: false) == nil && CarPanel.width(withPanel: 49, plain: 49, dockAtBottom: false) == nil, "no panel measured yet: no width")
check(CarPanel.width(withPanel: 225, plain: nil, dockAtBottom: false) == 176, "the car connecting during guidance, the plain map never seen: the dock as it was seen elsewhere")
check(CarPanel.width(withPanel: 176, plain: nil, dockAtBottom: true) == 176, "the same on the upright screen: no dock at the leading edge")
check(!CarPanel.secondRowFits(panelWidth: 176, screenHeight: 228), "374 x 228: a stacked card on a low screen, the second row is left out")
check(!CarPanel.secondRowFits(panelWidth: 176, screenHeight: 240), "400 x 240: the same")
check(CarPanel.secondRowFits(panelWidth: 224, screenHeight: 240), "640 x 240: the one-line card leaves room for the second row")
check(CarPanel.secondRowFits(panelWidth: 176, screenHeight: 400), "300 x 400: a stacked card on a high screen has the room")
check(CarPanel.secondRowFits(panelWidth: nil, screenHeight: 228), "not measured yet: handed over, and decided again when it is")
let wideRoom = CarRoom(width: 640, height: 240, top: 44, left: 273, bottom: 0, right: 40)
check(wideRoom.freeWidth == 327 && wideRoom.freeHeight == 196, "the free map is what CarPlay's parts leave")

// ---- how a prompt may be given --------------------------------------------------------------------------------------

for item in (recorded("prompt_styles.json") as? [Any]) ?? [] {
  guard let row = item as? [String: Any], let code = (row["code"] as? NSNumber)?.uintValue, let state = row["state"] as? String else {
    check(false, "a recorded prompt state reads")
    continue
  }
  let style = CarPromptStyle(code: code)
  check(style.answer == row["answer"] as? String, "prompts while \(state): the answer to Dart")
  check((style == .tone) == (row["tone"] as? Bool ?? false), "prompts while \(state): the tone only when a short prompt is asked for")
  check((style == .spoken) == (row["phoneSpeaks"] as? Bool ?? false), "prompts while \(state): the phone speaks only when a spoken prompt is fine")
  if let letters = row["fourCC"] as? String, letters.count == 4 {
    var number: UInt = 0
    for byte in Array(letters.utf8) { number = number << 8 | UInt(byte) }
    check(number == code, "prompts while \(state): the code is the four letters \(letters)")
  }
}
check(((recorded("prompt_styles.json") as? [Any]) ?? []).count >= 4, "the recorded prompt states are there")
let tone: [Int16] = CarPromptTone.samples()
check(tone.count == Int(44100 * 0.28), "the tone is 0.28 s long")
check(tone.first == 0 && abs(Int(tone.last ?? 99)) < 40, "the tone starts and ends without a click")
let loudest: Int = tone.map { abs(Int($0)) }.max() ?? 0
check(loudest > 8000 && loudest < 15000, "the tone is soft: well under half of full scale")
let wav = CarPromptTone.wav()
check(wav.count == 44 + tone.count * 2 && Array(wav.prefix(4)) == Array("RIFF".utf8), "the tone as a WAV file: a header and the samples")

// ---- lanes ----------------------------------------------------------------------------------------------------------

let laned = CarTrip.from(map("trip_guiding_near.json"))
let lanes: [CarLane] = laned.step?.lanes ?? []
check(lanes.count == 4, "lanes: four lanes at the turn")
check(lanes.first == CarLane(directions: ["left"], role: "active", take: "left"), "lanes: the lane to be in")
check(lanes.count == 4 && lanes[1] == CarLane(directions: ["through", "left"], role: "valid", take: "left"), "lanes: another lane that works")
check(lanes.count == 4 && lanes[3] == CarLane(directions: ["through", "right"], role: "dim", take: nil), "lanes: a lane that does not work")
check(laned.step?.lanesLabel == "Lanes: use the 2 left lanes", "lanes: the phone's words for them")
check(laned.then?.lanes.isEmpty == true && laned.then?.lanesLabel == nil, "lanes: never on the turn after next")
check(guiding.step?.lanes.isEmpty == true && guiding.step?.lanesLabel == nil, "no lanes shown by the phone: none")
let noArrows: [String: Any] = ["directions": [String](), "role": "dim"]
let noDirections: [String: Any] = ["role": "dim"]
let notLanes: [Any] = ["x", noArrows, noDirections]
check(CarLane.list(notLanes).isEmpty && CarLane.list("x").isEmpty && CarLane.list(nil).isEmpty, "what is not a lane with arrows is left out")
let bareLane: [Any] = [["directions": ["right"]]]
check(CarLane.list(bareLane) == [CarLane(directions: ["right"], role: "plain", take: nil)], "a lane's defaults")
check(CarLane.angle("through") == 0 && CarLane.angle("left") == -90 && CarLane.angle("right") == 90, "lane arrows as turns: straight, left, right")
check(CarLane.angle("slightLeft") == -45 && CarLane.angle("sharpRight") == 135 && CarLane.angle("reverse") == 180, "slight, sharp and the way back")
check(CarLane.angle("mergeToLeft") == -45 && CarLane.angle("mergeToRight") == 45 && CarLane.angle("sideways") == nil, "merging lanes, and a name that is no direction")
if lanes.count == 4 {
  check(lanes[0].takenAngle == -90 && lanes[0].otherAngles.isEmpty, "the lane to be in: the taken arrow apart, nothing else")
  check(lanes[1].takenAngle == -90 && lanes[1].otherAngles == [0], "a lane that works: the taken arrow apart from the rest")
  check(lanes[2].takenAngle == nil && lanes[2].otherAngles == [0], "a lane that does not work: no taken arrow")
  check(lanes[3].otherAngles == [0, 90], "its arrows in the phone's order")
}
let plainLane = CarLane(directions: ["through"], role: "plain", take: "through")
check(plainLane.takenAngle == nil && plainLane.otherAngles.isEmpty, "no lane marked: no taken arrow is claimed")

// ---- a climb ahead ------------------------------------------------------------------------------------------------

let uphill = CarTrip.from(map("trip_guiding_climb.json"))
check(uphill.climb?.climbAheadM == 148 && uphill.climb?.heightsM.count == 40, "a climb ahead: how much, and the heights of the road")
check(uphill.climb?.steepFrom == 20 && uphill.climb?.steepTo == 32, "a climb ahead: where the steep stretch is among the heights")
check(near(uphill.steepLat, 10.52) && near(uphill.steepLon, 20.26) && near(uphill.steepGradePct, 6.2), "the steepest point and its grade")
// The palette is one theme, the phone's chosen one (the recorded trips are in Dark), for day and night alike.
check(uphill.palette?.theme == "dark" && uphill.palette?.card == "#2a3036" && uphill.palette?.miniBg == "#1a1d1f", "the palette: the phone's theme")
check(uphill.badge?.badge == "#f4f6f8" && uphill.badge?.glyph == "#161b20" && uphill.badge?.edge == "#1a1d1f", "the grade marker's colours, from the theme")
var oneMissing = map("trip_guiding_climb.json")
if var pal = oneMissing["palette"] as? [String: Any] {
  pal["miniBg"] = "nope"
  oneMissing["palette"] = pal
}
check(CarTrip.from(oneMissing).palette == nil, "a palette with a colour that does not read: none")
let oldShape: [String: Any] = ["phase": "guiding", "palette": ["day": ["route": "#1f6fa8"], "night": ["route": "#6bb4de"]]]
check(CarTrip.from(oldShape).palette == nil, "the old day and night blocks are not a palette")
check(guiding.climb == nil && guiding.steepGradePct == nil, "no climb ahead: none")

// ---- the two extras on the map: the phone's word, the screen's class, the fade --------------------------------------

// The phone's one word: its drive screen is showing. Missing means no; the old switches are not read.
let oldSwitches: [String: Any] = ["climb": false, "miniMap": false]
let phoneShows: [String: Any] = ["phoneDrive": true]
let phoneHides: [String: Any] = ["phoneDrive": false]
let notABool: [String: Any] = ["phoneDrive": 1]
let withOld: [String: Any] = ["phase": "guiding", "overlay": oldSwitches]
let withShows: [String: Any] = ["phase": "guiding", "overlay": phoneShows]
let withHides: [String: Any] = ["phase": "guiding", "overlay": phoneHides]
let withNumber: [String: Any] = ["phase": "guiding", "overlay": notABool]
check(!CarTrip.from(withOld).phoneDrive && !guiding.phoneDrive, "the phone's drive screen: not said means not showing")
check(CarTrip.from(withShows).phoneDrive && !CarTrip.from(withHides).phoneDrive && !CarTrip.from(withNumber).phoneDrive, "the phone's drive screen: only a plain yes is yes")
check(guiding.overviewPoints.count >= 2 && guiding.overviewPoints.allSatisfy { $0.count == 2 }, "the whole route for the mini map, as points")
check(guiding.drivenFraction >= 0 && guiding.drivenFraction <= 1, "how much of the route is driven")
let onePoint: [String: Any] = ["points": [[10.5, 20.2]], "drivenFraction": 7.0]
let shortRoute: [String: Any] = ["phase": "guiding", "overview": onePoint]
check(CarTrip.from(shortRoute).overviewPoints.isEmpty && CarTrip.from(shortRoute).drivenFraction == 1, "one point is no route, and a share is kept between 0 and 1")

// The measure at the five screens the harness runs: the room CarPlay reported while guiding (what its parts take from each
// edge), the free map that leaves, the layout and the class. The same layouts, measure and number as the Android car's.
func freeMap(_ width: Double, _ height: Double, top: Double, left: Double, bottom: Double, right: Double) -> CGRect {
  CGRect(x: left, y: top, width: width - left - right, height: height - top - bottom)
}
let small374 = CarExtras.layout(free: freeMap(374, 228, top: 44, left: 225, bottom: 0, right: 40))
let small400 = CarExtras.layout(free: freeMap(400, 240, top: 44, left: 225, bottom: 0, right: 40))
let wide640 = CarExtras.layout(free: freeMap(640, 240, top: 44, left: 273, bottom: 0, right: 40))
let upright = CarExtras.layout(free: freeMap(300, 400, top: 44, left: 176, bottom: 49, right: 40))
let high640 = CarExtras.layout(free: freeMap(640, 360, top: 44, left: 273, bottom: 0, right: 40))
let short640 = CarExtras.layout(free: freeMap(640, 200, top: 44, left: 273, bottom: 0, right: 40))
check(small374.screenClass == .small && !small374.fits && small374.mini == nil && small374.climb == nil, "374 x 228: the two do not fit beside the vehicle: small")
check(small374.words == "SMALL (they do not fit; 0 pt of 20056 pt free map, 0 %; split)", "374 x 228: the measure in words")
check(small400.screenClass == .small && small400.freeArea == 26460 && small400.mode == .split, "400 x 240: small, of a free map 135 x 196")
check(upright.screenClass == .small && upright.freeArea == 25788, "300 x 400: small, the free map CarPlay reports is 84 wide")
check(wide640.mode == .oneBox && wide640.screenClass == .between && wide640.fits, "640 x 240: the one box fits beside the vehicle and takes more than 15 %: in-between")
check(wide640.mini == CGRect(x: 281, y: 104, width: 130, height: 70), "640 x 240: the mini map, the box's upper part, at the free map's bottom leading corner")
check(wide640.climb == CGRect(x: 281, y: 174, width: 130, height: 58), "640 x 240: the climb, the box's lower part, its bottom 8 above the free map's")
check(wide640.words == "IN_BETWEEN (they fit; 16640 pt of 64092 pt free map, 26 %; one box)", "640 x 240: the measure in words")
check(high640.mode == .oneBox && high640.words == "IN_BETWEEN (they fit; 16640 pt of 103332 pt free map, 16 %; one box)", "640 x 360: the one box, in-between")
check(short640.mode == .split && short640.fits, "640 x 200 (not run by the harness): too low for the box with its cushions: split")
check(short640.mini == CGRect(x: 490, y: 122, width: 110, height: 70), "split: the tile in the bottom trailing corner, on the free map's trailing edge")
check(short640.climb == CGRect(x: 281, y: 160, width: 140, height: 32), "split: the one-line card from the leading edge to the vehicle's column")
check(short640.words == "IN_BETWEEN (they fit; 12180 pt of 51012 pt free map, 24 %; split)", "split: the measure in words")
check(CarExtras.bigMaxShare == 0.15, "the one number: 15 % of the free map")
if let tile = wide640.mini, let card = wide640.climb {
  let keep = CarExtras.keepClear(freeMap(640, 240, top: 44, left: 273, bottom: 0, right: 40))
  check(!tile.intersects(keep) && !card.intersects(keep), "neither piece is over the vehicle or the road ahead")
  check(keep.minX == 421 && keep.maxX == 452 && keep.minY == 44, "the vehicle's column: the marker and free map each side, up to the top")
}
let vehicle = CarExtras.vehiclePoint(freeMap(640, 240, top: 44, left: 273, bottom: 0, right: 40))
check(vehicle.x == 436.5 && near(Double(vehicle.y), 44 + 196 * 0.675, 1e-9), "the vehicle is where the guidance camera draws it")
check(CarExtras.layout(free: CGRect.zero).screenClass == .small, "no free map: small")
check(!CarExtras.carries(.small, phoneDrive: false) && !CarExtras.carries(.small, phoneDrive: true), "a small screen never carries the two")
check(CarExtras.carries(.big, phoneDrive: false) && CarExtras.carries(.big, phoneDrive: true), "a big screen always does")
check(CarExtras.carries(.between, phoneDrive: false) && !CarExtras.carries(.between, phoneDrive: true), "an in-between screen does, except while the phone's drive screen shows")
check(CarExtras.carriesWord(.small) == "never" && CarExtras.carriesWord(.between) == "unlessPhone" && CarExtras.carriesWord(.big) == "always", "the three words the phone is told")
check(CarExtras.onMap, "the one place that takes the two off CarPlay's map is on")

// The pause and the fade.
var fade = CarExtrasFade(shown: true)
check(fade.due == nil && fade.start(at: 100) == nil, "nothing to do while the car shows what it should")
fade.want(false, at: 10)
check(fade.due == 12 && fade.shown, "the phone's screen shows: one pause of two seconds first")
check(fade.start(at: 11.9) == nil && fade.shown, "nothing starts inside the pause")
fade.want(true, at: 11)
check(fade.due == nil && fade.start(at: 20) == nil && fade.shown, "a flip back inside the pause changes nothing")
fade.want(false, at: 30)
fade.want(false, at: 31)
check(fade.due == 32, "told the same again: the pause runs from the first time")
check(fade.start(at: 32) == false && !fade.shown && fade.due == nil, "the pause has run out: the fade out starts")
fade.want(true, at: 40)
check(fade.due == 42 && fade.start(at: 42.5) == true && fade.shown, "and the same way back in")
fade.want(false, at: 50)
fade.set(true)
check(fade.due == nil && fade.shown, "a new drive or a new screen: what it carries, at once")
check(CarExtras.pauseSeconds == 2 && CarExtras.fadeSeconds == 0.5, "two seconds, then half a second")

// The mini map's sums (the Android painter's).
let square: [[Double]] = [[0, 0], [0, 1], [1, 1]]
let placed = CarExtras.project(square, in: CGRect(x: 0, y: 0, width: 120, height: 120), pad: 10)
check(placed.count == 3 && near(Double(placed[0].x), 10, 0.01) && near(Double(placed[0].y), 110, 0.01), "the route's first point in the tile: south-west is bottom left")
check(near(Double(placed[2].x), 110, 0.01) && near(Double(placed[2].y), 10, 0.01), "north-east is top right, with the padding around")
let half = CarExtras.cut(placed, fraction: 0.5)
check(near(half.last.map { Double($0.x) }, 110, 0.01) && near(half.last.map { Double($0.y) }, 110, 0.01), "half of the line by length ends at the corner")
let third = CarExtras.cut(placed, fraction: 0.25)
check(third.count == 2 && near(Double(third[1].x), 60, 0.01), "a quarter of the line ends halfway along its first leg")
check(CarExtras.cut(placed, fraction: 0).count == 1 && CarExtras.cut(placed, fraction: 1).count == 3, "none of the line, and all of it")
check(CarExtras.project([], in: CGRect.zero, pad: 0).isEmpty && CarExtras.cut([], fraction: 0.5).isEmpty, "no route: nothing")
check(near(CarExtras.shapeY(1050, lo: 1000, hi: 1100, top: 0, bottom: 40), 20) && near(CarExtras.shapeY(1100, lo: 1000, hi: 1100, top: 0, bottom: 40), 0), "the shape: the middle height in the middle, the top at the top")
check(near(CarExtras.shapeY(1010, lo: 1000, hi: 1010, top: 0, bottom: 40), 18), "a small rise is drawn low: the whole height stands for at least 100 m")
check(CarExtras.lineForm(avail: 116, figureW: 40, gradeDistanceW: 60, gradeW: 20) == .figureGradeDistance, "the one-line card: the shape is the first to go")
check(CarExtras.lineForm(avail: 150, figureW: 40, gradeDistanceW: 60, gradeW: 20) == .shapeFigureGradeDistance, "with room: the shape, the figure, the grade and how far")
check(CarExtras.lineForm(avail: 70, figureW: 40, gradeDistanceW: 60, gradeW: 20) == .figureGrade && CarExtras.lineForm(avail: 50, figureW: 40, gradeDistanceW: 60, gradeW: 20) == .figure, "then the distance goes, then the grade")
check(CarExtras.lineForm(avail: 500, figureW: 40, gradeDistanceW: nil, gradeW: nil) == .figure, "no grade known: the figure alone")
let oneHeight: [String: Any] = ["climbAheadM": 10.0, "heightsM": [1000.0]]
check(CarClimb.from(oneHeight) == nil && CarClimb.from(nil) == nil, "a climb needs at least two heights")
check(CarText.climb(148, imperial: true) == "490 ft" && CarText.climb(375, imperial: true) == "1,230 ft", "how much is climbed, in feet to the nearest ten")
check(CarText.climb(148, imperial: false) == "150 m" && CarText.climb(1234.4, imperial: false) == "1,230 m", "and in metres")
check(CarText.ahead(3250, imperial: true) == "2.0 mi" && CarText.ahead(100, imperial: true) == "350 ft", "how far off the steepest part is")
check(CarText.ahead(3400, imperial: false) == "3.4 km" && CarText.ahead(810, imperial: false) == "800 m", "and in metric")
check(CarText.grade(6.2) == "6%" && CarText.grade(6.5) == "7%", "a grade in whole percent")

// the recorded drive
let nearer = CarTrip.from(map("trip_guiding_near.json"))
check(nearer.step?.distanceM == 90, "nearer the turn: closer")
check(nearer.step?.cue == guiding.step?.cue, "nearer the turn: the same turn")
let past = CarTrip.from(map("trip_guiding_next.json"))
check(past.step?.turn == "right", "past the turn: the next one")
check(past.then?.turn == "arrive", "past the turn: arriving after it")
let offRoute = CarTrip.from(map("trip_rerouting.json"))
check(offRoute.guiding && offRoute.rerouting, "looking for a new route: still guiding")
check(offRoute.step == nil && offRoute.remainingM == nil, "looking for a new route: no turn, and what is left is not known")
let there = CarTrip.from(map("trip_arrived.json"))
check(there.guiding && there.arrived && there.step == nil, "arrived: no turn")
check(there.leftSeconds == 0, "arrived: no time left")
let noRoute = CarTrip.from(map("trip_error.json"))
check(noRoute.previewing && !noRoute.routing && noRoute.routes.isEmpty, "the trip with no route: choosing, not routing, no routes")
check(noRoute.error == "Waiting for your position", "the trip with no route says why")
let found: [CarPlace] = CarPlace.list(recorded("search.json"))
check(found.count == 3, "three places found")
check(found.first?.name == "Coffee House", "the places found keep their order")

// ---- colours as Dart writes them for the map -----------------------------------------------------------------------

let blue: [Double] = CarValue.rgba("#1f6fa8") ?? []
check(blue.count == 4, "a colour is four numbers")
if blue.count == 4 {
  let red: Bool = abs(blue[0] - 31.0 / 255.0) < 1e-9
  let green: Bool = abs(blue[1] - 111.0 / 255.0) < 1e-9
  let blueOk: Bool = abs(blue[2] - 168.0 / 255.0) < 1e-9
  check(red && green && blueOk, "a colour: red, green and blue")
  check(blue[3] == 1, "a colour with no alpha is opaque")
}
let faint: [Double] = CarValue.rgba("rgba(31,111,168,0.16)") ?? []
check(faint.count == 4, "a colour with alpha is four numbers")
if faint.count == 4 {
  check(abs(faint[0] - 31.0 / 255.0) < 1e-9 && abs(faint[3] - 0.16) < 1e-9, "a colour with alpha: its red and its alpha")
}
let white: [Double] = [1, 1, 1, 1]
let whiteRead: [Double]? = CarValue.rgba(" #FFFFFF ")
check(whiteRead == white, "capitals and spaces around a colour")
let notColours: [String] = ["blue", "#12345", "#12345g", "#+12345", "rgba(1,2,3)", "rgba(1,2,x,1)", ""]
for text in notColours {
  check(CarValue.rgba(text) == nil, "not a colour: '\(text)'")
}

// ---- the marker's motion (the Android car's CarMarkerMotion tests) -------------------------------------------------

typealias Motion = CarMarkerMotion
check(near(Motion.heading(reported: 45, last: 90), 45) && near(Motion.heading(reported: 45, last: nil), 45), "a reported heading is shown")
check(near(Motion.heading(reported: nil, last: 90), 90), "with none reported, the last one known")
check(Motion.heading(reported: nil, last: nil) == nil, "no heading ever known: none")
check(near(Motion.heading(reported: Double.nan, last: 90), 90), "a heading that is not a number counts as none")
check(Motion.heading(reported: Double.infinity, last: nil) == nil, "an endless heading counts as none")
check(near(Motion.heading(reported: -10, last: nil), 350) && near(Motion.heading(reported: 360, last: nil), 0), "headings are kept from 0 up to 360")
check(near(Motion.heading(reported: 725, last: nil), 5), "a heading of more than one turn")
for i in 0...30 {
  let turned: Double = Motion.lerpHeading(350, 80, Double(i) / 30)
  check(Motion.arrowTurn(heading: turned, cameraBearing: turned) == 0, "the camera turned to the heading: the arrow points up, step \(i)")
}
check(Motion.arrowTurn(heading: 90, cameraBearing: 0) == 90 && Motion.arrowTurn(heading: 270, cameraBearing: 0) == 270, "north up: the arrow's turn is the heading")
check(near(Motion.arrowTurn(heading: 100, cameraBearing: 10), 90), "the arrow's turn is the heading less the camera's")
check(near(Motion.arrowTurn(heading: 10, cameraBearing: 30), 340) && near(Motion.arrowTurn(heading: 10, cameraBearing: 350), 20), "the arrow's turn across north")
check(near(Motion.angleBetween(359, 1), 2) && near(Motion.angleBetween(1, 359), 2), "359 and 1 are 2 apart")
check(near(Motion.angleBetween(0, 360), 0) && near(Motion.angleBetween(90, 270), 180) && near(Motion.angleBetween(10, 10.5), 0.5), "angles apart")
check(Motion.arrowIsUp(heading: 90, cameraBearing: 90) && Motion.arrowIsUp(heading: 359.5, cameraBearing: 359.5) && Motion.arrowIsUp(heading: 0, cameraBearing: 0), "the arrow is up when the camera is turned to the heading")
check(!Motion.arrowIsUp(heading: 90, cameraBearing: 0) && !Motion.arrowIsUp(heading: 100, cameraBearing: 90), "the arrow is not up otherwise")
check(near(Motion.heading(reported: nil, last: 90, guiding: true), 90) && near(Motion.heading(reported: 45, last: 90, guiding: true), 45), "guiding: the last heading is kept")
check(Motion.heading(reported: nil, last: nil, guiding: true) == nil, "guiding with none ever known: none")
check(Motion.heading(reported: nil, last: 90, guiding: false) == nil && Motion.heading(reported: Double.nan, last: 90, guiding: false) == nil, "not guiding: no heading reported is none")
check(near(Motion.heading(reported: 200, last: 90, guiding: false), 200) && near(Motion.heading(reported: 200, last: nil, guiding: false), 200), "not guiding: a reported heading is shown")
check(Motion.lerp(42.5, 42.6, 0) == 42.5 && Motion.lerp(42.5, 42.6, 1) == 42.6, "a glide begins and ends exactly on its positions")
check(near(Motion.lerp(42.5, 42.6, 0.5), 42.55, 1e-12) && near(Motion.lerp(-113.8, -113.7, 0.25), -113.775, 1e-12), "part of the way")
check(Motion.lerp(42.5, 42.6, -0.2) == 42.5 && Motion.lerp(42.5, 42.6, 1.2) == 42.6, "never before the start or past the end")
check(near(Motion.lerpHeading(359, 1, 0.5), 0) && near(Motion.lerpHeading(359, 1, 0.25), 359.5) && near(Motion.lerpHeading(359, 1, 0.75), 0.5), "a turn across north goes the short way")
check(Motion.lerpHeading(359, 1, 1) == 1 && Motion.lerpHeading(359, 1, 0) == 359, "a turn begins and ends exactly")
check(near(Motion.lerpHeading(1, 359, 0.5), 0) && near(Motion.lerpHeading(1, 359, 0.75), 359.5), "and the other way across north")
check(near(Motion.lerpHeading(0, 90, 0.5), 45) && near(Motion.lerpHeading(270, 180, 0.5), 225) && near(Motion.lerpHeading(10, 330, 0.5), 350), "plain turns")
check(Motion.maxGlideMs == 1200 && Motion.snapGapMs == 3000 && Motion.snapJumpM == 150 && Motion.minFrameMs == 30, "the numbers are Android's")
check(Motion.durationMs(gapMs: 1000) == 1000 && Motion.durationMs(gapMs: 400) == 400 && Motion.durationMs(gapMs: 1200) == 1200, "a glide lasts as long as the time since the position before")
check(Motion.durationMs(gapMs: 2500) == 1200 && Motion.durationMs(gapMs: -5) == 0, "but never longer than the longest, and never less than nothing")
check(!Motion.snaps(first: false, gapMs: 1000, jumpM: 15, phaseChanged: false, force: false), "a second later and a few metres on: a glide")
check(Motion.snaps(first: true, gapMs: 1000, jumpM: 0, phaseChanged: false, force: false), "the first position is a jump")
check(Motion.snaps(first: false, gapMs: 3001, jumpM: 15, phaseChanged: false, force: false) && Motion.snaps(first: false, gapMs: 0, jumpM: 15, phaseChanged: false, force: false), "too long since, or no time since: a jump")
check(Motion.snaps(first: false, gapMs: 1000, jumpM: 151, phaseChanged: false, force: false), "too far: a jump")
check(Motion.snaps(first: false, gapMs: 1000, jumpM: 15, phaseChanged: true, force: false) && Motion.snaps(first: false, gapMs: 1000, jumpM: 15, phaseChanged: false, force: true), "a new phase, or being told to: a jump")
check(!Motion.appliesFrame(fraction: 0.5, nowMs: 1016, lastAppliedMs: 1000) && Motion.appliesFrame(fraction: 0.5, nowMs: 1030, lastAppliedMs: 1000), "frames go to the map about 30 times a second")
check(Motion.appliesFrame(fraction: 1, nowMs: 1001, lastAppliedMs: 1000), "the last frame always goes")
check(near(Motion.distanceM(lat1: 10.5, lon1: 20.2, lat2: 10.5, lon2: 20.201), 109.3, 0.5), "metres between two positions")

// ---- the link -------------------------------------------------------------------------------------------------------

let link = CarLink()
let heard = Heard()
link.addListener(heard)
link.addListener(heard)

var sent: [(String, Any?)] = []
var released = 0
link.link(send: { method, arguments, done in
  sent.append((method, arguments))
  let answer: Any? = method == "saved" ? recorded("saved.json") : nil
  done?(answer)
}, release: { released += 1 })

// Before Dart says hello nothing is sent to it, and a call is answered with nothing.
link.setCarConnected(true)
check(sent.isEmpty && link.carConnected, "connected is not sent before Dart is ready")
var early: [Any?] = []
link.call("saved") { early.append($0) }
check(early.isEmpty, "a call before Dart is ready is not answered at once")
turn()
check(early.count == 1, "a call before Dart is ready is answered on the next turn")
let earlyAnswer: Any? = early.first ?? nil
check(earlyAnswer == nil && sent.isEmpty, "a call before Dart is ready is answered with nothing, and not sent")

// hello: the answer says a car is here; the listeners hear once each.
var reply: [Any?] = []
let helloKnown = link.handle(method: "hello", arguments: nil, reply: { reply.append($0) })
check(helloKnown, "hello is one of the channel's methods")
let helloAnswer: [String: Any] = (reply.first ?? nil) as? [String: Any] ?? [:]
let helloConnected: Bool = helloAnswer["connected"] as? Bool ?? false
check(helloConnected, "hello is answered with the car being connected")
check(link.dartReady && heard.ready == 1, "Dart is ready, and the listener (added twice) heard once")

// the trip
reply = []
let tripKnown = link.handle(method: "trip", arguments: map("trip_guiding.json"), reply: { reply.append($0) })
check(tripKnown, "trip is known")
let tripAnswer: Any? = reply.first ?? nil
check(reply.count == 1 && tripAnswer == nil, "a trip is answered with nothing")
check(link.trip == guiding, "the pushed trip is kept")
check(heard.trips == [guiding], "the listener hears the pushed trip")

// the route line
link.handle(method: "route", arguments: map("route_previewing.json"), reply: { _ in })
let wantBounds: [Double] = [10.5, 20.2, 10.56, 20.28]
let line: String = link.routeGeoJson ?? ""
check(line.contains("LineString"), "the route line")
check(line.contains("\"alt\":true") && line.contains("\"kind\":\"offroad\""), "the route line keeps what marks its stretches")
check(link.routeBounds == wantBounds, "the route line's bounds: south, west, north, east")
check(heard.routes.count == 1, "the listener hears the route")
let heardBounds: [Double] = (heard.routes.first?.1 ?? nil) ?? []
check(heardBounds.count == 4, "the listener hears the route's bounds")
link.handle(method: "route", arguments: map("route_none.json"), reply: { _ in })
let noneLine: String = link.routeGeoJson ?? ""
check(noneLine == CarLink.emptyGeoJSON && link.routeBounds == nil, "the message of no route: an empty line and no bounds")
link.handle(method: "route", arguments: map("route_guiding.json"), reply: { _ in })
check(link.routeBounds == wantBounds, "the route while guiding has its bounds")
link.handle(method: "route", arguments: nil, reply: { _ in })
let emptyLine: String = link.routeGeoJson ?? ""
check(emptyLine == CarLink.emptyGeoJSON && link.routeBounds == nil, "no route: an empty line and no bounds")

// notices, saved places, the map style, prompts
let blankNotice: [String: Any] = ["text": "  "]
let notice: [String: Any] = ["text": "Rerouting"]
link.handle(method: "notice", arguments: blankNotice, reply: { _ in })
link.handle(method: "notice", arguments: notice, reply: { _ in })
check(heard.notices == ["Rerouting"], "a notice with words is heard, one of spaces is not")
link.handle(method: "savedChanged", arguments: nil, reply: { _ in })
link.handle(method: "styleChanged", arguments: nil, reply: { _ in })
check(heard.saved == 1 && heard.styles == 1, "saved places changed, the map style changed")
var prompts: [String] = []
var stops = 0
link.onPrompt = {
  prompts.append($0)
  return "short"
}
link.onPromptStop = { stops += 1 }
reply = []
let promptText: [String: Any] = ["text": "Turn left"]
let promptKnown = link.handle(method: "prompt", arguments: promptText, reply: { reply.append($0) })
check(promptKnown && reply.count == 1, "a prompt is answered")
let promptAnswer: String? = (reply.first ?? nil) as? String
check(promptAnswer == "short", "a prompt is answered with what the hook says about prompts at this moment")
let stopKnown = link.handle(method: "promptStop", arguments: nil, reply: { reply.append($0) })
check(stopKnown && reply.count == 2, "the end of a prompt is answered")
check(prompts == ["Turn left"] && stops == 1, "the prompt and its end reach the audio hook")

// what is not the channel's
reply = []
let nonsenseKnown = link.handle(method: "nonsense", arguments: nil, reply: { reply.append($0) })
check(!nonsenseKnown && reply.isEmpty, "an unknown method is not answered here")

// asking Dart, now that it is ready
var answer: [Any?] = []
link.call("saved") { answer.append($0) }
let savedAnswer: Any? = answer.first ?? nil
check(sent.count == 1 && sent.first?.0 == "saved", "a call reaches Dart")
check(CarPlace.list(savedAnswer).count == 3, "a call brings Dart's answer")

// the car goes: the trip and the route are forgotten, and Dart is told
link.setCarConnected(false)
check(!link.carConnected && link.trip == CarTrip.empty, "the car gone: no trip")
check(link.routeGeoJson == nil && link.routeBounds == nil, "the car gone: no route")
let goneArguments: [String: Any] = (sent.last?.1 ?? nil) as? [String: Any] ?? [:]
let goneOn: Bool = goneArguments["on"] as? Bool ?? true
check(sent.count == 2 && sent.last?.0 == "connected", "Dart is told when the car goes")
check(!goneOn, "Dart is told the car has gone")

// a stand-in for Dart, as the Android tests have
link.dartForTests = { method, _, done in done(method == "start" ? true : nil) }
var stood: [Any?] = []
link.call("start") { stood.append($0) }
check(stood.isEmpty, "the stand-in answers on the next turn of the main queue")
turn()
let stoodAnswer: Bool = (stood.first ?? nil) as? Bool ?? false
check(stood.count == 1 && stoodAnswer, "the stand-in answered")
check(sent.count == 2, "nothing went to the channel while the stand-in answered")

// a new way to Dart replaces the old: Dart has to say hello again
link.dartForTests = nil
link.link(send: { _, _, done in done?(nil) }, release: {})
check(released == 1 && !link.dartReady, "a new channel lets the old one go, and Dart is not ready until it says hello")
link.removeListener(heard)
link.handle(method: "hello", arguments: nil, reply: { _ in })
check(heard.ready == 1, "a listener that was removed hears nothing more")
link.detach()
check(!link.dartReady, "detached: Dart is not ready")
link.reset()
check(link.trip == CarTrip.empty && !link.carConnected, "reset")

// The phone map's pins (the pins message, lib/car/car_pins.dart carPinsMessage): held until the car goes.
let twoPins = "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[20.2,10.5]},\"properties\":{\"pin\":\"a\"}},{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[20.3,10.6]},\"properties\":{\"pin\":\"b\"}}]}"
var pinSet = CarPinSet.empty
pinSet.receive(["source": "cache-notebook", "geojson": twoPins, "images": ["a": Data([1, 2]), "b": Data([3])], "ratio": 3.0, "reset": true])
check(pinSet.count == 2 && pinSet.pictures.count == 2 && pinSet.pictures["a"]?.ratio == 3 && pinSet.source == "cache-notebook", "the pins and their pictures")
pinSet.receive(["geojson": twoPins, "images": ["c": Data([4])], "reset": false])
check(pinSet.pictures.count == 3 && pinSet.pictures["c"]?.ratio == 3, "a later message adds the pictures not sent before; no ratio means 3")
pinSet.receive(["geojson": CarLink.emptyGeoJSON, "images": [String: Any](), "reset": true])
check(pinSet.pictures.isEmpty && pinSet.count == 0, "reset drops the pictures held")
link.setCarConnected(true)
link.handle(method: "pins", arguments: ["geojson": twoPins, "images": ["a": Data([1])], "reset": true], reply: { _ in })
check(link.pins.count == 2 && link.pins.pictures.count == 1, "the link holds the pins it was sent")
link.setCarConnected(false)
check(link.pins == CarPinSet.empty, "the car went: no pins and no pictures")
link.reset()

print("car link tests: \(checks - failures) of \(checks) passed")
exit(failures == 0 ? 0 : 1)
