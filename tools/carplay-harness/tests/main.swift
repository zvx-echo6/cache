// The car link's rules, checked on a Mac on recorded messages: the messages are the ones in tools/carplay-harness/recorded,
// whose shape app/test/car_test.dart holds to what the phone's Dart side really sends. Compiled with the product's own
// CarTrip.swift and CarLink.swift (app/ios/Runner/CarPlay), which need no Flutter for this.
//
//   swiftc CarTrip.swift CarLink.swift main.swift -o car-tests && ./car-tests <folder of recorded messages>
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
check(isNumber(browsing.heading, 90), "browsing: the heading")

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
link.onPrompt = { prompts.append($0) }
link.onPromptStop = { stops += 1 }
reply = []
let promptText: [String: Any] = ["text": "Turn left"]
let promptKnown = link.handle(method: "prompt", arguments: promptText, reply: { reply.append($0) })
check(promptKnown && reply.count == 1, "a prompt is answered")
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

print("car link tests: \(checks - failures) of \(checks) passed")
exit(failures == 0 ? 0 : 1)
