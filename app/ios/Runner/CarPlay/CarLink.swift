import Foundation

#if canImport(Flutter)
import Flutter
#endif

/// What the car scene hears from the link. Every method has an empty default.
protocol CarLinkListener: AnyObject {
  func carLinkTrip(_ trip: CarTrip)
  func carLinkRoute(geojson: String, bounds: [Double]?)
  func carLinkStyleChanged()
  func carLinkNotice(_ text: String)
  func carLinkDartReady()
  func carLinkSavedChanged()
  func carLinkPins()
}

extension CarLinkListener {
  func carLinkTrip(_ trip: CarTrip) {}
  func carLinkRoute(geojson: String, bounds: [Double]?) {}
  func carLinkStyleChanged() {}
  func carLinkNotice(_ text: String) {}
  func carLinkDartReady() {}
  func carLinkSavedChanged() {}
  func carLinkPins() {}
}

/// One picture of the pins, as the phone drew it: PNG bytes, and its pixels per point.
struct CarPinPicture: Equatable {
  let png: Data
  let ratio: Double
}

/// The phone map's pins (the `pins` message, lib/car/car_pins.dart): the style's source to fill, its points (GeoJSON, each
/// feature with only `pin`, its picture's name) and the pictures by name. The Swift twin of the Android car's CarPins.kt.
/// Coordinates and pictures only: nothing of a place's name comes across, and nothing of them is logged.
struct CarPinSet: Equatable {
  static let defaultSource = "cache-notebook"
  static let defaultRatio: Double = 3

  var source = CarPinSet.defaultSource
  var geojson = CarLink.emptyGeoJSON
  var pictures: [String: CarPinPicture] = [:]

  static let empty = CarPinSet()

  /// Dart's message: the pins, and the pictures not sent before in this connection (`reset`: drop the ones held first). The
  /// pictures come as Data (the channel's typed bytes are turned into Data where the channel is: CarLink.attach).
  mutating func receive(_ args: [String: Any]) {
    if (args["reset"] as? Bool) == true { pictures = [:] }
    if let s = args["source"] as? String, !s.isEmpty { source = s }
    let given = CarValue.double(args["ratio"]) ?? 0
    let ratio = given > 0 ? given : CarPinSet.defaultRatio
    if let images = args["images"] as? [String: Any] {
      for (name, value) in images {
        if let png = value as? Data { pictures[name] = CarPinPicture(png: png, ratio: ratio) }
      }
    }
    geojson = args["geojson"] as? String ?? CarLink.emptyGeoJSON
  }

  /// How many pins, for the log (no places, no names).
  var count: Int {
    guard let data = geojson.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let features = parsed["features"] as? [Any]
    else { return 0 }
    return features.count
  }
}

/// The car side of the `co.cache/car` channel (lib/car/car_bridge.dart is the other side). The Swift twin of the Android
/// car's CarLink.kt: the same messages, the same state, the same rules.
///
/// Dart pushes the trip (`trip`), the route line (`route`), that the map style changed (`styleChanged`), short notices
/// (`notice`), spoken prompts (`prompt`, `promptStop`) and the phone map's pins (`pins`). The car asks Dart for places,
/// directions, start and stop, through `call`. Main thread only, as CarPlay's templates and Flutter's channels both are.
///
/// Nothing here needs Flutter to compile, so the rules are tested on a Mac on recorded messages
/// (tools/carplay-harness/tests); the part that ties it to a real engine is at the end of the file.
final class CarLink {
  static let shared = CarLink()
  static let emptyGeoJSON = "{\"type\":\"FeatureCollection\",\"features\":[]}"

  /// Dart said hello: its handler is set and calls to it are answered.
  private(set) var dartReady = false
  /// A car scene is connected.
  private(set) var carConnected = false
  private(set) var trip = CarTrip.empty
  private(set) var routeGeoJson: String?
  private(set) var routeBounds: [Double]?
  /// The phone map's pins, held for the car's map (a style loaded again gets them at once); none while no car is connected.
  private(set) var pins = CarPinSet.empty

  /// A spoken prompt is about to play: the answer is how it may be given at this moment (CarPromptStyle's answers; nil with
  /// no hook, and the phone then speaks as it would with no car). And a prompt was stopped. Set by CarPrompts.
  var onPrompt: ((String) -> String?)?
  var onPromptStop: (() -> Void)?

  /// For the tests: answers in place of Dart (a car scene with no Flutter engine).
  var dartForTests: ((_ method: String, _ arguments: Any?, _ done: @escaping (Any?) -> Void) -> Void)?

  private var listeners: [CarLinkListener] = []
  private var send: ((_ method: String, _ arguments: Any?, _ done: ((Any?) -> Void)?) -> Void)?
  private var release: (() -> Void)?

  /// The way to Dart: `send` invokes a method on the channel, `release` lets the channel go. A new one replaces the old.
  func link(send: @escaping (_ method: String, _ arguments: Any?, _ done: ((Any?) -> Void)?) -> Void, release: @escaping () -> Void) {
    self.release?()
    dartReady = false
    self.send = send
    self.release = release
  }

  func detach() {
    release?()
    release = nil
    send = nil
    dartReady = false
  }

  func addListener(_ listener: CarLinkListener) {
    if !listeners.contains(where: { $0 === listener }) {
      listeners.append(listener)
    }
  }

  func removeListener(_ listener: CarLinkListener) {
    listeners.removeAll { $0 === listener }
  }

  func setCarConnected(_ on: Bool) {
    carConnected = on
    if !on {
      trip = CarTrip.empty
      routeGeoJson = nil
      routeBounds = nil
      pins = CarPinSet.empty
    }
    if dartReady {
      send?("connected", ["on": on], nil)
    }
  }

  /// Asks Dart; `done` gets the answer, or nil when Dart is not there yet or failed.
  func call(_ method: String, _ arguments: Any? = nil, done: @escaping (Any?) -> Void = { _ in }) {
    if let fake = dartForTests {
      DispatchQueue.main.async { fake(method, arguments, done) }
      return
    }
    guard let send = send, dartReady else {
      DispatchQueue.main.async { done(nil) }
      return
    }
    send(method, arguments, done)
  }

  /// What Dart pushes. False when the method is not one of the channel's; otherwise `reply` has been called once, before the
  /// listeners hear.
  @discardableResult
  func handle(method: String, arguments: Any?, reply: (Any?) -> Void) -> Bool {
    let args = arguments as? [String: Any]
    switch method {
    case "hello":
      dartReady = true
      reply(["connected": carConnected])
      each { $0.carLinkDartReady() }
    case "trip":
      let pushed = CarTrip.from(args ?? [:])
      trip = pushed
      reply(nil)
      each { $0.carLinkTrip(pushed) }
    case "route":
      let geojson = args?["geojson"] as? String ?? CarLink.emptyGeoJSON
      let bounds = (args?["bounds"] as? [Any])?.compactMap { CarValue.double($0) }
      routeGeoJson = geojson
      routeBounds = bounds
      reply(nil)
      each { $0.carLinkRoute(geojson: geojson, bounds: bounds) }
    case "savedChanged":
      reply(nil)
      each { $0.carLinkSavedChanged() }
    case "styleChanged":
      reply(nil)
      each { $0.carLinkStyleChanged() }
    case "notice":
      reply(nil)
      if let text = CarValue.text(args?["text"]) {
        each { $0.carLinkNotice(text) }
      }
    case "prompt":
      reply(onPrompt?(args?["text"] as? String ?? ""))
    case "promptStop":
      onPromptStop?()
      reply(nil)
    case "pins":
      pins.receive(args ?? [:])
      reply(nil)
      each { $0.carLinkPins() }
    default:
      return false
    }
    return true
  }

  private func each(_ tell: (CarLinkListener) -> Void) {
    for listener in listeners {
      tell(listener)
    }
  }

  /// For the tests.
  func reset() {
    listeners = []
    trip = CarTrip.empty
    routeGeoJson = nil
    routeBounds = nil
    pins = CarPinSet.empty
    carConnected = false
    dartReady = false
    send = nil
    release = nil
    onPrompt = nil
    onPromptStop = nil
    dartForTests = nil
  }
}

#if canImport(Flutter)
extension CarLink {
  /// Sets the car side of the channel on the app's engine. Called where the engine is made (AppDelegate), in a build with the
  /// car screen: whichever scene started the engine, Dart's hello finds an answer.
  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "co.cache/car", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      var arguments = call.arguments
      // The pins' pictures come as the channel's typed bytes: Data for CarLink, which does not know Flutter.
      if call.method == "pins", var m = arguments as? [String: Any], let images = m["images"] as? [String: Any] {
        m["images"] = images.compactMapValues { ($0 as? FlutterStandardTypedData)?.data ?? ($0 as? Data) }
        arguments = m
      }
      let known = self?.handle(method: call.method, arguments: arguments, reply: { result($0) }) ?? false
      if !known {
        result(FlutterMethodNotImplemented)
      }
    }
    link(
      send: { method, arguments, done in
        channel.invokeMethod(method, arguments: arguments) { answer in
          // An error, or no such method on the Dart side, is no answer.
          if answer is FlutterError || (answer as AnyObject?) === FlutterMethodNotImplemented {
            done?(nil)
          } else {
            done?(answer)
          }
        }
      },
      release: { channel.setMethodCallHandler(nil) }
    )
  }
}
#endif
