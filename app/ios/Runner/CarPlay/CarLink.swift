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
}

extension CarLinkListener {
  func carLinkTrip(_ trip: CarTrip) {}
  func carLinkRoute(geojson: String, bounds: [Double]?) {}
  func carLinkStyleChanged() {}
  func carLinkNotice(_ text: String) {}
  func carLinkDartReady() {}
  func carLinkSavedChanged() {}
}

/// The car side of the `co.cache/car` channel (lib/car/car_bridge.dart is the other side). The Swift twin of the Android
/// car's CarLink.kt: the same messages, the same state, the same rules.
///
/// Dart pushes the trip (`trip`), the route line (`route`), that the map style changed (`styleChanged`), short notices
/// (`notice`) and spoken prompts (`prompt`, `promptStop`). The car asks Dart for places, directions, start and stop, through
/// `call`. Main thread only, as CarPlay's templates and Flutter's channels both are.
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

  /// A spoken prompt is about to play, or has ended. Set by the car scene when it handles the audio session.
  var onPrompt: ((String) -> Void)?
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
      onPrompt?(args?["text"] as? String ?? "")
      reply(nil)
    case "promptStop":
      onPromptStop?()
      reply(nil)
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
      let known = self?.handle(method: call.method, arguments: call.arguments, reply: { result($0) }) ?? false
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
