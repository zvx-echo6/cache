import Foundation

/// The trip as Dart pushed it (lib/car/car_trip.dart): the phone's guidance, read only. Numbers are meters and seconds; the
/// turn is the phone's TurnIcon name. The Swift twin of the Android car's CarTrip.kt, field for field and default for default.
struct CarStep: Equatable {
  let turn: String
  let type: String
  let cue: String
  let road: String?
  let distanceM: Double
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

  var guiding: Bool { phase == "guiding" }
  var previewing: Bool { phase == "previewing" }

  static let empty = CarTrip(
    phase: "browsing", available: false, imperial: false, routing: false, error: nil, destinationName: nil,
    destinationAddress: nil, destinationLat: nil, destinationLon: nil, routes: [], routeIndex: 0, routeId: nil, voiceOn: true,
    arrived: false, rerouting: false, lat: nil, lon: nil, heading: nil, step: nil, then: nil, currentRoad: nil,
    remainingM: nil, remainingS: nil, etaMs: nil
  )

  /// From the channel's plain map. What is missing or of another kind takes the same default as on Android.
  static func from(_ m: [String: Any]) -> CarTrip {
    let dest = CarValue.map(m["destination"])
    let pos = CarValue.map(m["position"])
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
      etaMs: CarValue.number(m["etaMs"])?.int64Value
    )
  }

  private static func step(_ v: Any?) -> CarStep? {
    guard let s = CarValue.map(v) else { return nil }
    return CarStep(
      turn: s["turn"] as? String ?? "straight",
      type: s["type"] as? String ?? "",
      cue: s["cue"] as? String ?? "",
      road: CarValue.text(s["road"]),
      distanceM: CarValue.double(s["distanceM"]) ?? 0
    )
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
