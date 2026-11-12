import Foundation

/// The trip as Dart pushed it (lib/car/car_trip.dart): the phone's guidance, read only. Numbers are meters and seconds; the
/// turn is the phone's TurnIcon name. The Swift twin of the Android car's CarTrip.kt, field for field and default for default.
struct CarStep: Equatable {
  let turn: String
  let type: String
  let cue: String
  let road: String?
  let distanceM: Double
  /// The lanes the phone shows for this maneuver at this moment, left to right; empty when it shows none.
  var lanes: [CarLane] = []
  /// The phone's words for those lanes ("Lanes: use the 2 left lanes"); nil with no lanes.
  var lanesLabel: String?
}

/// One lane of the road at the next maneuver, as Dart worked it out from the phone's lane strip (lib/car/car_trip.dart,
/// carLanes): the car draws it and decides nothing.
struct CarLane: Equatable {
  /// The arrows the lane carries: the phone's LaneDirection names ("through", "left", "slightRight", "mergeToLeft", ...).
  let directions: [String]
  /// How the lane is drawn: "active" (the lane to be in), "valid" (another that works), "dim" (one that does not), or
  /// "plain" (the road did not say which lanes work: every lane alike).
  let role: String
  /// The arrow the route takes from a lane that works; nil on the others.
  let take: String?

  /// The lanes of a step's `lanes`; anything that is not a list of lanes is none, and a lane with no arrows is left out.
  static func list(_ v: Any?) -> [CarLane] {
    var lanes: [CarLane] = []
    for item in (v as? [Any]) ?? [] {
      guard let m = CarValue.map(item) else { continue }
      let directions: [String] = ((m["directions"] as? [Any]) ?? []).compactMap { $0 as? String }
      if directions.isEmpty { continue }
      lanes.append(CarLane(directions: directions, role: m["role"] as? String ?? "plain", take: CarValue.text(m["take"])))
    }
    return lanes
  }

  /// A lane arrow's turn in degrees clockwise from straight ahead, as the phone's strip turns it (lane_strip.dart): left is
  /// -90, right 90, the way back 180. The two merging arrows have no turn of their own on the phone (a lane sliding over):
  /// here they are the slight turn to their side. Nil for a name that is no direction.
  static func angle(_ direction: String) -> Double? {
    switch direction {
    case "through", "none": return 0
    case "sharpLeft": return -135
    case "left": return -90
    case "slightLeft", "mergeToLeft": return -45
    case "slightRight", "mergeToRight": return 45
    case "right": return 90
    case "sharpRight": return 135
    case "reverse": return 180
    default: return nil
    }
  }

  /// The arrows other than the one the route takes, as turns (CarPlay's lane data wants the taken one apart from the rest).
  var otherAngles: [Double] {
    var angles: [Double] = []
    let taken: Double? = take.flatMap { CarLane.angle($0) }
    for direction in directions {
      guard let angle = CarLane.angle(direction), angle != taken, !angles.contains(angle) else { continue }
      angles.append(angle)
    }
    return angles
  }

  /// The taken arrow's turn; nil on a lane that does not work.
  var takenAngle: Double? {
    guard role == "active" || role == "valid" else { return nil }
    return take.flatMap { CarLane.angle($0) }
  }
}

struct CarRoute: Equatable {
  let index: Int
  let distanceM: Double
  let durationS: Int64
  let via: String?
}

struct CarTrip: Equatable {
  let phase: String
  let available: Bool
  let imperial: Bool
  let routing: Bool
  let error: String?
  let destinationName: String?
  let destinationAddress: String?
  let destinationLat: Double?
  let destinationLon: Double?
  let routes: [CarRoute]
  let routeIndex: Int
  let routeId: String?
  let voiceOn: Bool
  let arrived: Bool
  let rerouting: Bool
  let lat: Double?
  let lon: Double?
  let heading: Double?
  let step: CarStep?
  let then: CarStep?
  let currentRoad: String?
  let remainingM: Double?
  let remainingS: Int64?
  let etaMs: Int64?
  /// The climb ahead, while guiding and one of at least the phone's least grade lies ahead; nil otherwise.
  let climb: CarClimb?
  /// The steepest point of that climb on the map, and its grade in percent.
  let steepLat: Double?
  let steepLon: Double?
  let steepGradePct: Double?
  /// The phone's drive screen is showing to a person (the phone unlocked, Cache in front, its Maps tab on the drive screen):
  /// the phone's own word for it, `overlay.phoneDrive`. Missing means no.
  let phoneDrive: Bool
  /// The whole route for the mini map, as [latitude, longitude] points, and how much of it is driven (0 to 1).
  let overviewPoints: [[Double]]
  let drivenFraction: Double
  /// The grade marker's colours for the car's day and night (the phone's palette), or nil before the palette has come.
  let badgeDay: CarBadgeColors?
  let badgeNight: CarBadgeColors?

  var guiding: Bool { phase == "guiding" }
  var previewing: Bool { phase == "previewing" }

  static let empty = CarTrip(
    phase: "browsing", available: false, imperial: false, routing: false, error: nil, destinationName: nil,
    destinationAddress: nil, destinationLat: nil, destinationLon: nil, routes: [], routeIndex: 0, routeId: nil, voiceOn: true,
    arrived: false, rerouting: false, lat: nil, lon: nil, heading: nil, step: nil, then: nil, currentRoad: nil,
    remainingM: nil, remainingS: nil, etaMs: nil, climb: nil, steepLat: nil, steepLon: nil, steepGradePct: nil,
    phoneDrive: false, overviewPoints: [], drivenFraction: 0, badgeDay: nil, badgeNight: nil
  )

  /// From the channel's plain map. What is missing or of another kind takes the same default as on Android.
  static func from(_ m: [String: Any]) -> CarTrip {
    let dest = CarValue.map(m["destination"])
    let pos = CarValue.map(m["position"])
    let overview = CarValue.map(m["overview"])
    let steep = CarValue.map(overview?["steep"])
    var points: [[Double]] = []
    for item in (overview?["points"] as? [Any]) ?? [] {
      guard let pair = item as? [Any], pair.count >= 2, let lat = CarValue.double(pair[0]), let lon = CarValue.double(pair[1]) else { continue }
      points.append([lat, lon])
    }
    if points.count < 2 { points = [] }
    let palette = CarValue.map(m["palette"])
    var routes: [CarRoute] = []
    for item in (m["routes"] as? [Any]) ?? [] {
      guard let x = CarValue.map(item) else { continue }
      routes.append(CarRoute(
        index: CarValue.number(x["index"])?.intValue ?? 0,
        distanceM: CarValue.double(x["distanceM"]) ?? 0,
        durationS: CarValue.number(x["durationS"])?.int64Value ?? 0,
        via: x["via"] as? String
      ))
    }
    return CarTrip(
      phase: m["phase"] as? String ?? "browsing",
      available: CarValue.isTrue(m["available"]),
      imperial: (m["units"] as? String) == "imperial",
      routing: CarValue.isTrue(m["routing"]),
      error: m["error"] as? String,
      destinationName: dest?["name"] as? String,
      destinationAddress: CarValue.text(dest?["address"]),
      destinationLat: CarValue.double(dest?["lat"]),
      destinationLon: CarValue.double(dest?["lon"]),
      routes: routes,
      routeIndex: CarValue.number(m["routeIndex"])?.intValue ?? 0,
      routeId: m["routeId"] as? String,
      voiceOn: !CarValue.isFalse(m["voiceOn"]),
      arrived: CarValue.isTrue(m["arrived"]),
      rerouting: CarValue.isTrue(m["rerouting"]),
      lat: CarValue.double(pos?["lat"]),
      lon: CarValue.double(pos?["lon"]),
      heading: CarValue.double(pos?["heading"]),
      step: step(m["step"]),
      then: step(m["then"]),
      currentRoad: m["currentRoad"] as? String,
      remainingM: CarValue.double(m["remainingM"]),
      remainingS: CarValue.number(m["remainingS"])?.int64Value,
      etaMs: CarValue.number(m["etaMs"])?.int64Value,
      climb: CarClimb.from(m["climb"]),
      steepLat: CarValue.double(steep?["lat"]),
      steepLon: CarValue.double(steep?["lon"]),
      steepGradePct: CarValue.double(steep?["gradePct"]),
      phoneDrive: CarValue.isTrue(CarValue.map(m["overlay"])?["phoneDrive"]),
      overviewPoints: points,
      drivenFraction: min(max(CarValue.double(overview?["drivenFraction"]) ?? 0, 0), 1),
      badgeDay: CarBadgeColors.from(palette?["day"]),
      badgeNight: CarBadgeColors.from(palette?["night"])
    )
  }

  private static func step(_ v: Any?) -> CarStep? {
    guard let s = CarValue.map(v) else { return nil }
    return CarStep(
      turn: s["turn"] as? String ?? "straight",
      type: s["type"] as? String ?? "",
      cue: s["cue"] as? String ?? "",
      road: CarValue.text(s["road"]),
      distanceM: CarValue.double(s["distanceM"]) ?? 0,
      lanes: CarLane.list(s["lanes"]),
      lanesLabel: CarValue.text(s["lanesLabel"])
    )
  }
}

/// A climb ahead, as Dart sends it with the trip (lib/car/car_overlay.dart, carClimb): how much is climbed, the steepest
/// grade and how far off it is, and the heights of the road ahead with the steep stretch's place among them. The twin of the
/// Android car's CarClimb.
struct CarClimb: Equatable {
  let climbAheadM: Double
  let gradePct: Double?
  let steepestInM: Double?
  let heightsM: [Double]
  let steepFrom: Int?
  let steepTo: Int?
  let windowM: Double

  /// Nil for anything that is not a climb with at least two heights.
  static func from(_ v: Any?) -> CarClimb? {
    guard let m = CarValue.map(v) else { return nil }
    let heights: [Double] = ((m["heightsM"] as? [Any]) ?? []).compactMap { CarValue.double($0) }
    if heights.count < 2 { return nil }
    return CarClimb(
      climbAheadM: CarValue.double(m["climbAheadM"]) ?? 0,
      gradePct: CarValue.double(m["gradePct"]),
      steepestInM: CarValue.double(m["steepestInM"]),
      heightsM: heights,
      steepFrom: CarValue.number(m["steepFrom"])?.intValue,
      steepTo: CarValue.number(m["steepTo"])?.intValue,
      windowM: CarValue.double(m["windowM"]) ?? 0
    )
  }
}

/// The grade marker's three colours, as Dart writes colours ("#rrggbb").
struct CarBadgeColors: Equatable {
  let badge: String
  let glyph: String
  let edge: String

  static func from(_ v: Any?) -> CarBadgeColors? {
    guard let m = CarValue.map(v), let badge = m["badge"] as? String, let glyph = m["badgeGlyph"] as? String,
          let edge = m["badgeEdge"] as? String else { return nil }
    return CarBadgeColors(badge: badge, glyph: glyph, edge: edge)
  }
}

/// A place the car can go to, as Dart lists them (saved places, search results).
struct CarPlace: Equatable {
  let id: String
  let name: String
  let address: String?
  let lat: Double
  let lon: Double
  let distanceM: Double?

  static func from(_ v: Any?) -> CarPlace? {
    guard let m = CarValue.map(v), let id = m["id"] as? String,
          let lat = CarValue.double(m["lat"]), let lon = CarValue.double(m["lon"]) else { return nil }
    return CarPlace(
      id: id, name: m["name"] as? String ?? "", address: CarValue.text(m["address"]), lat: lat, lon: lon,
      distanceM: CarValue.double(m["distanceM"])
    )
  }

  static func list(_ v: Any?) -> [CarPlace] {
    ((v as? [Any]) ?? []).compactMap { from($0) }
  }

  /// The line under the place's name in a list, as the Android car's rows have it: "16 mi · 1501 Example Ave", the distance
  /// alone, the address alone, or nothing.
  func detail(imperial: Bool) -> String? {
    let distance: String? = distanceM.map { CarText.distance($0, imperial: imperial) }
    if let distance = distance, let address = address { return "\(distance) · \(address)" }
    return distance ?? address
  }
}

/// Words the car side has to write itself. On Android the car's host writes a distance from a number; CarPlay's lists take
/// plain text, so the distance is written here, in the phone's own words and rounding (lib/nav/units.dart, Fmt.distance; the
/// Android car's CarModels.distance rounds the same way).
enum CarText {
  /// "300 ft", "0.5 mi", "12 mi", "350 m", "1.2 km".
  static func distance(_ meters: Double, imperial: Bool) -> String {
    let m = measure(meters, imperial: imperial)
    if m.tenths { return "\(String(format: "%.1f", m.value)) \(m.unit)" }
    return "\(Int(m.value)) \(m.unit)"
  }

  /// The same distance as a number and its unit ("ft", "mi", "m" or "km"), for where CarPlay writes the distance itself;
  /// `tenths` says the phone writes it with one decimal.
  static func measure(_ meters: Double, imperial: Bool) -> (value: Double, unit: String, tenths: Bool) {
    let m = max(0, meters)
    if imperial {
      let ft = m * 3.28084
      let mi = m / 1609.344
      if ft < 528 { return (step(ft, ft < 100 ? 10 : 50), "ft", false) }
      if mi < 10 { return ((mi * 10).rounded() / 10, "mi", true) }
      return (mi.rounded(), "mi", false)
    }
    if m < 1000 { return (step(m, m < 100 ? 10 : 50), "m", false) }
    let km = m / 1000
    if km < 10 { return ((km * 10).rounded() / 10, "km", true) }
    return (km.rounded(), "km", false)
  }

  private static func step(_ value: Double, _ by: Double) -> Double {
    (value / by).rounded() * by
  }

  /// The same again as a length CarPlay can be given: it then writes the number and the unit the phone would write.
  static func length(_ meters: Double, imperial: Bool) -> Measurement<UnitLength> {
    let m = measure(meters, imperial: imperial)
    switch m.unit {
    case "ft": return Measurement(value: m.value, unit: UnitLength.feet)
    case "mi": return Measurement(value: m.value, unit: UnitLength.miles)
    case "km": return Measurement(value: m.value, unit: UnitLength.kilometers)
    default: return Measurement(value: m.value, unit: UnitLength.meters)
    }
  }

  /// How much is climbed, as the Android car writes it: to the nearest ten, "1,230 ft" or "380 m".
  static func climb(_ meters: Double, imperial: Bool) -> String {
    let value = imperial ? meters * 3.28084 : meters
    let tens = Int((value / 10).rounded()) * 10
    var digits = String(abs(tens))
    var grouped = ""
    while digits.count > 3 {
      grouped = "," + String(digits.suffix(3)) + grouped
      digits = String(digits.dropLast(3))
    }
    return "\(tens < 0 ? "-" : "")\(digits)\(grouped) \(imperial ? "ft" : "m")"
  }

  /// How far off the steepest part is, as the Android car writes it: "2.3 mi" or "400 ft"; "3.5 km" or "800 m".
  static func ahead(_ meters: Double, imperial: Bool) -> String {
    if imperial {
      let mi = meters / 1609.344
      if mi >= 0.1 { return "\(String(format: "%.1f", mi)) mi" }
      return "\(Int((meters * 3.28084 / 50).rounded()) * 50) ft"
    }
    if meters >= 1000 { return "\(String(format: "%.1f", meters / 1000)) km" }
    return "\(Int((meters / 50).rounded()) * 50) m"
  }

  /// A grade as the Android car writes it: "6%".
  static func grade(_ percent: Double) -> String {
    "\(Int(percent.rounded()))%"
  }

  /// "5 min", "1 h 25 min", "2 d 3 h": a time in the phone's words (Fmt.duration).
  static func duration(_ seconds: Int64) -> String {
    let mins = Int((Double(seconds) / 60).rounded())
    if mins < 1 { return "1 min" }
    if mins < 60 { return "\(mins) min" }
    let hours = mins / 60
    let rest = mins % 60
    if hours < 24 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min" }
    let days = hours / 24
    return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h"
  }
}

extension CarTrip {
  /// The time left as CarPlay is given it: under a minute counts as one minute until the phone says arrived, so the last
  /// part of a drive never reads "0 min" (as the Android car's remainingSeconds).
  var leftSeconds: Int64? {
    guard let s = remainingS else { return nil }
    return arrived ? max(0, s) : max(60, s)
  }

  /// The time to a turn: its share of the time left, as far as it is of what is left (as the Android car's trip).
  func turnSeconds(_ step: CarStep) -> Int64 {
    let left = remainingM ?? step.distanceM
    if left <= 0 { return 0 }
    let share = Double(remainingS ?? 0) * (step.distanceM / left)
    return max(0, Int64(share.rounded()))
  }
}

extension CarRoute {
  /// "21 min · 16 mi": the route's time and distance, as the Android car's route rows have them.
  func title(imperial: Bool) -> String {
    "\(CarText.duration(durationS)) · \(CarText.distance(distanceM, imperial: imperial))"
  }
}

/// Reading the channel's plain values the way the Android side does: a boolean is not a number, a number is not a boolean,
/// null and a missing key are the same, and a text of only spaces counts as none.
enum CarValue {
  static func map(_ v: Any?) -> [String: Any]? {
    v as? [String: Any]
  }

  private static func isBoolean(_ n: NSNumber) -> Bool {
    CFGetTypeID(n) == CFBooleanGetTypeID()
  }

  static func number(_ v: Any?) -> NSNumber? {
    guard let n = v as? NSNumber, !isBoolean(n) else { return nil }
    return n
  }

  static func double(_ v: Any?) -> Double? {
    number(v)?.doubleValue
  }

  static func isTrue(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber, isBoolean(n) else { return false }
    return n.boolValue
  }

  static func isFalse(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber, isBoolean(n) else { return false }
    return !n.boolValue
  }

  static func text(_ v: Any?) -> String? {
    guard let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s
  }

  /// A colour as Dart writes it for the map (MapPalette.css): "#rrggbb", or "rgba(r,g,b,a)" with red, green and blue from 0
  /// to 255. Answers red, green, blue and alpha, each from 0 to 1; nil for anything else.
  static func rgba(_ css: String) -> [Double]? {
    let s = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.hasPrefix("#") {
      let hex = String(s.dropFirst())
      guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }), let n = UInt32(hex, radix: 16) else { return nil }
      return [Double((n >> 16) & 0xff) / 255, Double((n >> 8) & 0xff) / 255, Double(n & 0xff) / 255, 1]
    }
    guard s.hasPrefix("rgba("), s.hasSuffix(")") else { return nil }
    let inner = String(s.dropFirst(5).dropLast())
    let parts: [Double] = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, parts.allSatisfy({ $0.isFinite }) else { return nil }
    let limited: [Double] = parts.map { min(max($0, 0), 255) }
    return [limited[0] / 255, limited[1] / 255, limited[2] / 255, min(limited[3], 1)]
  }
}
