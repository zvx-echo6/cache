import Foundation

/// "Navigate to <place> with Cache", said to Siri: the part with no App Intents in it, so the rules are tested on a Mac
/// (tools/carplay-harness/tests). The intent itself, its place parameter and the App Shortcut phrases are in
/// CarVoiceIntents.swift.
///
/// Siri does the understanding: Cache gets the place as a parameter, never the sentence. The place is a name (said, or one of
/// the saved places Siri was given as the parameter's values), or a place Cache found, with its coordinates. It goes to Dart's
/// `navigateTo` (lib/car/car_bridge.dart), the one the Android car's navigation requests (NavIntent.kt) already use: so a name
/// is found exactly as the car's search box finds a typed one. A saved place's name, or coordinates, start guidance; any other
/// name comes back as the places found (or none). With a car connected the car then shows them, as Android's car does
/// (CacheCarAppService.handle): a list to pick from, or "No places found". With no car, Siri asks which one (CarVoiceIntents).
struct CarVoicePlace: Equatable, Sendable {
  let name: String
  let lat: Double?
  let lon: Double?
  /// The line under the name when Siri lists places to choose from: the address, as the car's rows have it.
  let detail: String?

  /// A name as Siri heard it.
  static func spoken(_ name: String) -> CarVoicePlace {
    CarVoicePlace(name: name.trimmingCharacters(in: .whitespacesAndNewlines), lat: nil, lon: nil, detail: nil)
  }

  /// A place Cache found for a name.
  static func found(_ place: CarPlace) -> CarVoicePlace {
    CarVoicePlace(name: place.name, lat: place.lat, lon: place.lon, detail: place.address)
  }

  var hasCoordinates: Bool { lat != nil && lon != nil }

  /// Its identifier for App Intents: the place itself, written out, so Siri can hand it back (EntityQuery.entities(for:)) with
  /// nothing kept on the phone.
  var id: String {
    var m: [String: Any] = ["name": name]
    if let lat = lat, let lon = lon {
      m["lat"] = lat
      m["lon"] = lon
    }
    if let detail = detail { m["detail"] = detail }
    guard let data = try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return name }
    return text
  }

  init(name: String, lat: Double?, lon: Double?, detail: String?) {
    self.name = name
    self.lat = lat
    self.lon = lon
    self.detail = detail
  }

  /// The place an identifier was made from; nil when it is not one.
  init?(id: String) {
    guard let data = id.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let name = m["name"] as? String, !name.isEmpty else { return nil }
    let lat = CarValue.double(m["lat"])
    let lon = CarValue.double(m["lon"])
    let both = lat != nil && lon != nil
    self.init(name: name, lat: both ? lat : nil, lon: both ? lon : nil, detail: m["detail"] as? String)
  }
}

/// What a navigation request came to (Dart's answer to `navigateTo`).
enum CarVoiceOutcome: Equatable {
  /// Guidance began, to the place of this name.
  case started(name: String)
  /// The routes to the place are open on the phone but guidance did not begin (no route could be found yet).
  case routes(CarPlace)
  /// The name is not a saved place: the places found for it, to pick from.
  case places(query: String, places: [CarPlace])
  /// Nothing was found for the name.
  case none(query: String)
  /// Dart did not answer (not up in time, or a build with no car side).
  case noAnswer

  /// For the log: the kind, never a name.
  var kind: String {
    switch self {
    case .started: return "started"
    case .routes: return "routes"
    case .places(_, let places): return "places (\(places.count))"
    case .none: return "none"
    case .noAnswer: return "no answer"
    }
  }
}

/// What "Add a stop at <place>" came to (Dart's answer to `navigateTo` with `stop`).
enum CarStopOutcome: Equatable {
  /// The place became a stop on the route that is running (or shown).
  case added(name: String)
  /// The stop was not added (the phone's notice says why).
  case notAdded
  /// The name is not a saved place: the places found for it, for Siri to ask which one (during guidance only).
  case places(query: String, places: [CarPlace])
  /// Nothing was found for the name.
  case none(query: String)
  /// No route was running or shown: the request was a plain "navigate to" (its outcome, shown on the car as navigate shows it).
  case navigate(CarVoiceOutcome)
  /// Dart did not answer.
  case noAnswer
}

/// What "End route" came to (Dart's answer to `stop`: whether a route was running).
enum CarEndOutcome: Equatable {
  case ended
  case notRunning
  case noAnswer
}

/// What "voice off" or "voice on" came to (Dart's answer to `voice`: whether the voice prompts are on now).
enum CarVoicePromptsOutcome: Equatable {
  case now(on: Bool)
  case noAnswer
}

enum CarVoice {
  // The words Siri says (design section 6, approved as written). Nothing else is said by Cache.
  /// Siri's question when no place was said.
  static let whereTo = "Where to?"
  static func starting(_ name: String) -> String { "Starting the route to \(name)." }
  static func showing(_ query: String) -> String { "Showing places for \(query)." }
  static func noneFound(_ query: String) -> String { "Cache found no places for \(query)." }

  static func stopAdded(_ name: String) -> String { "Added \(name) as the next stop." }
  static let routeEnded = "Route ended."
  static let noRoute = "No route is running."
  static let promptsOff = "Voice prompts off."
  static let promptsOn = "Voice prompts on."

  /// How long a request waits for Dart to say hello when Siri started Cache (the engine starts first).
  static let dartWait: TimeInterval = 20

  /// The arguments of Dart's `navigateTo` for a place: as the Android car's navigation request sends them
  /// (CacheCarAppService.handle), always to start.
  static func arguments(for place: CarVoicePlace, fromSiri: Bool = false) -> [String: Any] {
    var a: [String: Any] = ["query": place.name, "start": true]
    // Siri's "Starting the route" covers the phone's opening line: only the Navigate intent says so.
    if fromSiri { a["fromSiri"] = true }
    if let lat = place.lat, let lon = place.lon {
      a["lat"] = lat
      a["lon"] = lon
    }
    return a
  }

  /// Dart's answer to `navigateTo` (car_bridge.dart): `places` (found for a name that is no saved place), or `started` with the
  /// place's `id`, `name`, `lat` and `lon`.
  static func outcome(_ answer: Any?, for place: CarVoicePlace) -> CarVoiceOutcome {
    guard let m = CarValue.map(answer) else { return .noAnswer }
    if let found = m["places"] {
      let places = CarPlace.list(found)
      return places.isEmpty ? .none(query: place.name) : .places(query: place.name, places: places)
    }
    let name = CarValue.text(m["name"]) ?? place.name
    if CarValue.isTrue(m["started"]) { return .started(name: name) }
    guard let id = m["id"] as? String else { return .noAnswer }
    let lat = CarValue.double(m["lat"]) ?? place.lat ?? 0
    let lon = CarValue.double(m["lon"]) ?? place.lon ?? 0
    return .routes(CarPlace(id: id, name: name, address: nil, lat: lat, lon: lon, distanceM: nil))
  }

  /// What Siri says for an outcome; nil where Cache has no words of its own (Siri asks which place itself, or the request
  /// failed and Siri says so in its own words).
  static func words(_ outcome: CarVoiceOutcome, carConnected: Bool) -> String? {
    switch outcome {
    case .started(let name): return starting(name)
    case .places(let query, _): return carConnected ? showing(query) : nil
    case .none(let query): return noneFound(query)
    case .routes, .noAnswer: return nil
    }
  }

  /// Asks Dart to navigate to the place, once it is up (at most `wait` seconds), and has the car show what came of it while a
  /// car is connected. `done` gets the outcome, on the main thread. Main thread only.
  static func navigate(
    _ place: CarVoicePlace, fromSiri: Bool = false, link: CarLink = .shared, wait: TimeInterval = dartWait,
    done: @escaping (CarVoiceOutcome) -> Void
  ) {
    whenReady(link: link, until: Date().addingTimeInterval(wait)) { ready in
      guard ready else {
        done(.noAnswer)
        return
      }
      link.call("navigateTo", arguments(for: place, fromSiri: fromSiri)) { answer in
        let result = outcome(answer, for: place)
        if link.carConnected { tell(result, link) }
        done(result)
      }
    }
  }

  /// The arguments of `navigateTo` for "Add a stop at <place>": as navigate's, with `stop` (the same request the Android car's
  /// `intent=add_a_stop` sends).
  static func stopArguments(for place: CarVoicePlace) -> [String: Any] {
    // `fromSiri`: with no route this becomes a plain navigation and Siri says "Starting the route" itself, so the phone's opening
    // line is left out; Dart ignores the flag when the place is added as a stop to a route.
    var a = arguments(for: place, fromSiri: true)
    a["stop"] = true
    return a
  }

  /// Dart's answer to `navigateTo` with `stop`: `added` (guiding or a route shown), the places found for a name that is no saved
  /// place (`forStop`), or, with no route, the answer a plain navigation request gets.
  static func stopOutcome(_ answer: Any?, for place: CarVoicePlace) -> CarStopOutcome {
    guard let m = CarValue.map(answer) else { return .noAnswer }
    if m["added"] != nil {
      return CarValue.isTrue(m["added"]) ? .added(name: place.name) : .notAdded
    }
    let plain = outcome(answer, for: place)
    guard CarValue.isTrue(m["forStop"]) else { return .navigate(plain) }
    switch plain {
    case .places(let query, let places): return .places(query: query, places: places)
    case .none(let query): return .none(query: query)
    default: return .noAnswer
    }
  }

  /// Dart's answer to `stop`: true when a route was running, false when none was.
  static func endOutcome(_ answer: Any?) -> CarEndOutcome {
    if CarValue.isTrue(answer) { return .ended }
    return CarValue.isFalse(answer) ? .notRunning : .noAnswer
  }

  /// Dart's answer to `voice`: whether the voice prompts are on now.
  static func promptsOutcome(_ answer: Any?) -> CarVoicePromptsOutcome {
    if CarValue.isTrue(answer) { return .now(on: true) }
    return CarValue.isFalse(answer) ? .now(on: false) : .noAnswer
  }

  /// The arguments of Dart's `answer` for Siri: the words come back and the phone says nothing (`say: false`); Siri says them.
  /// `kind` is `arrival_ios` or `turn_ios` (lib/car/car_answer.dart).
  static func answerArguments(_ kind: String) -> [String: Any] {
    ["kind": kind, "say": false]
  }

  /// Dart's answer to `answer`: the words, or nil.
  static func answerWords(_ answer: Any?) -> String? {
    CarValue.text(answer)
  }

  /// Asks Dart something, once it is up (at most `wait` seconds). `done` gets Dart's answer on the main thread, nil when Dart was
  /// not there in time. Main thread only.
  static func ask(
    _ method: String, _ arguments: Any? = nil, link: CarLink = .shared, wait: TimeInterval = dartWait,
    done: @escaping (Any?) -> Void
  ) {
    whenReady(link: link, until: Date().addingTimeInterval(wait)) { ready in
      guard ready else {
        done(nil)
        return
      }
      link.call(method, arguments, done: done)
    }
  }

  /// "Add a stop at <place>": navigateTo with `stop`. During guidance (or with a route shown) the place joins the route and the
  /// car is told nothing; with no route it is a navigation request and the car shows what came of it, as for navigate.
  static func addStop(
    _ place: CarVoicePlace, link: CarLink = .shared, wait: TimeInterval = dartWait,
    done: @escaping (CarStopOutcome) -> Void
  ) {
    ask("navigateTo", stopArguments(for: place), link: link, wait: wait) { answer in
      let result = stopOutcome(answer, for: place)
      if case .navigate(let plain) = result, link.carConnected { tell(plain, link) }
      done(result)
    }
  }

  /// "End route": the same `stop` the car's End route button sends.
  static func endRoute(link: CarLink = .shared, wait: TimeInterval = dartWait, done: @escaping (CarEndOutcome) -> Void) {
    ask("stop", link: link, wait: wait) { done(endOutcome($0)) }
  }

  /// "Voice off" and "voice on": Dart's `voice`, as the car's mute does.
  static func setPrompts(
    on: Bool, link: CarLink = .shared, wait: TimeInterval = dartWait, done: @escaping (CarVoicePromptsOutcome) -> Void
  ) {
    ask("voice", ["on": on], link: link, wait: wait) { done(promptsOutcome($0)) }
  }

  /// "When will I get there" and "What's my next turn": Dart's `answer` with the iOS words, not spoken by the phone.
  static func tripWords(
    _ kind: String, link: CarLink = .shared, wait: TimeInterval = dartWait, done: @escaping (String?) -> Void
  ) {
    ask("answer", answerArguments(kind), link: link, wait: wait) { done(answerWords($0)) }
  }

  /// What the car is told for a navigation outcome while a car is connected.
  private static func tell(_ result: CarVoiceOutcome, _ link: CarLink) {
    switch result {
    case .places(let query, let places): link.tellVoicePlaces(query: query, places: places)
    case .none(let query): link.tellVoicePlaces(query: query, places: [])
    case .routes(let shown): link.tellVoiceRoutes(shown)
    case .started: link.tellVoiceStarted()
    case .noAnswer: break
    }
  }

  private static func whenReady(link: CarLink, until: Date, _ then: @escaping (Bool) -> Void) {
    if link.dartReady || link.dartForTests != nil {
      then(true)
      return
    }
    if Date() >= until {
      then(false)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { whenReady(link: link, until: until, then) }
  }
}

/// The names of the saved places, kept for Siri: the values of the place in "Navigate to <place> with Cache" that Siri knows
/// before anything is said. Taken from the saved places the car lists (CarTemplates); names only, no coordinates.
enum CarVoiceSaved {
  static let key = "co.cache.car.voice.savedNames"
  static let most = 100

  static func names(_ defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: key) ?? []
  }

  /// Keeps the names of these places; true when they differ from the ones kept (Siri is then given them again).
  @discardableResult
  static func remember(_ places: [CarPlace], _ defaults: UserDefaults = .standard) -> Bool {
    var seen = Set<String>()
    var kept: [String] = []
    for place in places {
      let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty || !seen.insert(name.lowercased()).inserted { continue }
      kept.append(name)
      if kept.count == most { break }
    }
    if kept == names(defaults) { return false }
    defaults.set(kept, forKey: key)
    return true
  }
}
