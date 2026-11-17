import AppIntents
import Foundation
import os
import UIKit

// "Navigate to <place> with Cache" with Siri: an App Intent and its App Shortcut (Apple: App Intents, "App Shortcuts",
// AppShortcutsProvider, AppShortcutPhrase, EntityStringQuery, "Adding parameters to an app intent", AppIntent.supportedModes
// and openAppWhenRun). The rules, the words and the way to Dart are in CarVoice.swift.
//
// - "Navigate with Cache" names no place: Siri asks "Where to?" (the parameter's requestValueDialog) and the answer is the
//   place, as a name Siri heard.
// - Siri understands the sentence; the place reaches Cache as the intent's parameter (CarPlaceEntity). A place Siri knows
//   before anything is said is a saved place (the parameter's suggested values); any other name Siri heard comes as it is
//   (EntityStringQuery.entities(matching:)), and Cache's own car search finds it, as a typed name.
// - The intent runs in the background, with the phone locked and Cache not running: openAppWhenRun is left false (its
//   default) before iOS 26, and supportedModes is .background from iOS 26. iOS starts Cache in the background for it; the
//   intent starts the app's one Flutter engine itself (AppDelegate.obtainFlutterEngine, as the car scene does when CarPlay is
//   the one to start Cache) and waits for Dart's hello.
// - With a car connected the car shows what came of it (CarTemplates: the list, "No places found", the routes, guidance).
//   With none, guidance begins on the phone (the same navigateTo; the phone's drive screen shows it), and when a name found
//   several places Siri asks which one, in its own list on the phone (requestDisambiguation).

/// The place in "Navigate to <place> with Cache".
struct CarPlaceEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
  static let defaultQuery = CarPlaceQuery()

  let place: CarVoicePlace
  var id: String { place.id }

  var displayRepresentation: DisplayRepresentation {
    if let detail = place.detail {
      return DisplayRepresentation(title: "\(place.name)", subtitle: "\(detail)")
    }
    return DisplayRepresentation(title: "\(place.name)")
  }
}

struct CarPlaceQuery: EntityStringQuery {
  /// A place Siri hands back: its identifier is the place itself (CarVoicePlace.id).
  func entities(for identifiers: [String]) async throws -> [CarPlaceEntity] {
    identifiers.compactMap { id in CarVoicePlace(id: id).map { CarPlaceEntity(place: $0) } }
  }

  /// A name Siri heard: passed on as it is. Cache's car search does the finding when the intent runs.
  func entities(matching string: String) async throws -> [CarPlaceEntity] {
    let place = CarVoicePlace.spoken(string)
    return place.name.isEmpty ? [] : [CarPlaceEntity(place: place)]
  }

  /// The saved places' names, as the car last listed them (CarVoiceSaved).
  func suggestedEntities() async throws -> [CarPlaceEntity] {
    CarVoiceSaved.names().map { CarPlaceEntity(place: .spoken($0)) }
  }
}

/// A request Dart did not answer in time, or a route that could not begin: Siri says it failed, in its own words.
struct CarVoiceFailed: Error {}

struct CarNavigateIntent: AppIntent {
  static let title: LocalizedStringResource = "Navigate"

  /// In the background, from iOS 26 (before it, openAppWhenRun's default, false, does the same).
  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @Parameter(title: "Place", requestValueDialog: IntentDialog("Where to?"))
  var place: CarPlaceEntity

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    CarVoiceRun.log.info("car voice: navigate asked")
    CarVoiceRun.startEngine()
    var outcome = await CarVoiceRun.navigate(place.place, fromSiri: true)
    var connected = CarLink.shared.carConnected
    if case .places(_, let places) = outcome, !connected {
      // No car to show the list on: Siri asks which one, on the phone, and that one is navigated to.
      let choices = places.map { CarPlaceEntity(place: .found($0)) }
      let chosen = try await $place.requestDisambiguation(among: choices, dialog: IntentDialog("Where to?"))
      outcome = await CarVoiceRun.navigate(chosen.place, fromSiri: true)
      connected = CarLink.shared.carConnected
    }
    CarVoiceRun.log.info("car voice: navigate answered \(outcome.kind, privacy: .public), a car connected: \(connected)")
    guard let words = CarVoice.words(outcome, carConnected: connected) else { throw CarVoiceFailed() }
    CarVoiceRun.log.info("car voice: Siri says \(CarVoiceRun.template(outcome), privacy: .public)")
    return .result(dialog: "\(words)")
  }
}

/// Navigate starts guidance with spoken prompts, so from iOS 17 it is declared an audio-playing intent (the system then lets
/// the app's audio play, and the app is not suspended before it speaks). The app still runs on iOS 16.3, where there is no
/// such protocol: the conformance is available from iOS 17 only.
@available(iOS 17.0, *)
extension CarNavigateIntent: AudioPlaybackIntent {}

/// "Add a stop at <place> in Cache": the place becomes the next stop while guiding (the same `navigateTo` with `stop` the
/// Android car's add-a-stop request sends). With no route it is "navigate to", as on Android. A name that is no saved place
/// comes back as the places found, and Siri asks which one, in its own list.
struct CarAddStopIntent: AppIntent {
  static let title: LocalizedStringResource = "Add stop"

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @Parameter(title: "Place", requestValueDialog: IntentDialog("Where to?"))
  var place: CarPlaceEntity

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    CarVoiceRun.log.info("car voice: add stop asked")
    CarVoiceRun.startEngine()
    var outcome = await CarVoiceRun.addStop(place.place)
    if case .places(_, let places) = outcome {
      // Siri asks which one (a single place found is the one meant).
      let choices = places.map { CarPlaceEntity(place: .found($0)) }
      var chosen = choices.first
      if choices.count != 1 {
        chosen = try await $place.requestDisambiguation(among: choices, dialog: IntentDialog("Where to?"))
      }
      guard let picked = chosen else { throw CarVoiceFailed() }
      outcome = await CarVoiceRun.addStop(picked.place)
    }
    CarVoiceRun.log.info("car voice: add stop answered")
    switch outcome {
    case .added(let name):
      return .result(dialog: "\(CarVoice.stopAdded(name))")
    case .none(let query):
      return .result(dialog: "\(CarVoice.noneFound(query))")
    case .navigate(var plain):
      // No route: a plain navigate, with navigate's own words and its Siri question when no car shows the list.
      var connected = CarLink.shared.carConnected
      if case .places(_, let places) = plain, !connected {
        let choices = places.map { CarPlaceEntity(place: .found($0)) }
        let chosen = try await $place.requestDisambiguation(among: choices, dialog: IntentDialog("Where to?"))
        plain = await CarVoiceRun.navigate(chosen.place, fromSiri: true)
        connected = CarLink.shared.carConnected
      }
      guard let words = CarVoice.words(plain, carConnected: connected) else { throw CarVoiceFailed() }
      return .result(dialog: "\(words)")
    case .places, .notAdded, .noAnswer:
      throw CarVoiceFailed()
    }
  }
}

/// "End route in Cache": the same `stop` the car's End route button sends.
struct CarEndRouteIntent: AppIntent {
  static let title: LocalizedStringResource = "End route"

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    CarVoiceRun.log.info("car voice: end route asked")
    CarVoiceRun.startEngine()
    switch await CarVoiceRun.endRoute() {
    case .ended: return .result(dialog: "\(CarVoice.routeEnded)")
    case .notRunning: return .result(dialog: "\(CarVoice.noRoute)")
    case .noAnswer: throw CarVoiceFailed()
    }
  }
}

/// "Mute Cache" (and "Turn Cache's voice off"): the voice prompts off. Two intents, one for each way, so each has its own phrases.
struct CarVoiceOffIntent: AppIntent {
  static let title: LocalizedStringResource = "Voice off"

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let words = try await CarVoiceRun.setPromptsWords(on: false)
    return .result(dialog: "\(words)")
  }
}

/// "Unmute Cache" (and "Turn Cache's voice on"): the voice prompts on.
struct CarVoiceOnIntent: AppIntent {
  static let title: LocalizedStringResource = "Voice on"

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let words = try await CarVoiceRun.setPromptsWords(on: true)
    return .result(dialog: "\(words)")
  }
}

/// "When will I get there with Cache": Siri says the words, not Cache's speaker (Dart's `answer` with `say: false`).
struct CarArrivalIntent: AppIntent {
  static let title: LocalizedStringResource = "Arrival time"

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let words = try await CarVoiceRun.tripWords("arrival_ios")
    return .result(dialog: "\(words)")
  }
}

/// "What's my next turn in Cache": Siri says the words, not Cache's speaker.
struct CarNextTurnIntent: AppIntent {
  static let title: LocalizedStringResource = "Next turn"

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .background }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let words = try await CarVoiceRun.tripWords("turn_ios")
    return .result(dialog: "\(words)")
  }
}

struct CacheShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CarNavigateIntent(),
      phrases: [
        "Navigate to \(\.$place) with \(.applicationName)",
        "Take me to \(\.$place) with \(.applicationName)",
        // No place said: Siri asks "Where to?" (the parameter's question) and the answer comes the same way.
        "Navigate with \(.applicationName)",
      ]
    )
    // Seven App Shortcuts in all (Apple allows ten).
    AppShortcut(
      intent: CarAddStopIntent(),
      phrases: ["Add a stop at \(\.$place) in \(.applicationName)"],
      shortTitle: "Add stop",
      systemImageName: "mappin.and.ellipse"
    )
    AppShortcut(
      intent: CarEndRouteIntent(),
      phrases: ["End route in \(.applicationName)", "Stop navigating in \(.applicationName)"],
      shortTitle: "End route",
      systemImageName: "xmark.circle"
    )
    AppShortcut(
      intent: CarVoiceOffIntent(),
      phrases: ["Mute \(.applicationName)", "Turn \(.applicationName)'s voice off"],
      shortTitle: "Voice off",
      systemImageName: "speaker.slash"
    )
    AppShortcut(
      intent: CarVoiceOnIntent(),
      phrases: ["Unmute \(.applicationName)", "Turn \(.applicationName)'s voice on"],
      shortTitle: "Voice on",
      systemImageName: "speaker.wave.2"
    )
    AppShortcut(
      intent: CarArrivalIntent(),
      phrases: ["When will I get there with \(.applicationName)"],
      shortTitle: "Arrival time",
      systemImageName: "clock"
    )
    AppShortcut(
      intent: CarNextTurnIntent(),
      phrases: ["What's my next turn in \(.applicationName)"],
      shortTitle: "Next turn",
      systemImageName: "arrow.turn.up.right"
    )
  }
}

/// The intent's way in: the engine, then CarVoice.navigate.
enum CarVoiceRun {
  static let log = Logger(subsystem: "co.cache.car", category: "voice")

  /// The app's one Flutter engine, started if Siri was the one to start Cache. Only a build with the car screen has the car
  /// side of the channel that navigateTo goes through.
  @MainActor
  static func startEngine() {
    guard CarPlayBuild.isOn, let app = UIApplication.shared.delegate as? AppDelegate else { return }
    _ = app.obtainFlutterEngine()
  }

  @MainActor
  static func navigate(_ place: CarVoicePlace, fromSiri: Bool = false) async -> CarVoiceOutcome {
    await withCheckedContinuation { (done: CheckedContinuation<CarVoiceOutcome, Never>) in
      CarVoice.navigate(place, fromSiri: fromSiri) { done.resume(returning: $0) }
    }
  }

  @MainActor
  static func addStop(_ place: CarVoicePlace) async -> CarStopOutcome {
    await withCheckedContinuation { (done: CheckedContinuation<CarStopOutcome, Never>) in
      CarVoice.addStop(place) { done.resume(returning: $0) }
    }
  }

  @MainActor
  static func endRoute() async -> CarEndOutcome {
    await withCheckedContinuation { (done: CheckedContinuation<CarEndOutcome, Never>) in
      CarVoice.endRoute { done.resume(returning: $0) }
    }
  }

  /// Starts the engine, sets the voice prompts and returns Siri's words; throws when Dart did not answer.
  @MainActor
  static func setPromptsWords(on: Bool) async throws -> String {
    log.info("car voice: voice prompts asked")
    startEngine()
    let outcome: CarVoicePromptsOutcome = await withCheckedContinuation { done in
      CarVoice.setPrompts(on: on) { done.resume(returning: $0) }
    }
    guard case .now(let isOn) = outcome else { throw CarVoiceFailed() }
    return isOn ? CarVoice.promptsOn : CarVoice.promptsOff
  }

  /// Starts the engine and returns the words Dart composed for Siri (`arrival_ios` or `turn_ios`); throws when Dart did not answer.
  @MainActor
  static func tripWords(_ kind: String) async throws -> String {
    log.info("car voice: a trip question asked")
    startEngine()
    let words: String? = await withCheckedContinuation { done in
      CarVoice.tripWords(kind) { done.resume(returning: $0) }
    }
    guard let said = words else { throw CarVoiceFailed() }
    return said
  }

  /// Which of the approved sentences Siri says, for the log (no place names in the log).
  static func template(_ outcome: CarVoiceOutcome) -> String {
    switch outcome {
    case .started: return "'Starting the route to <name>.'"
    case .places: return "'Showing places for <query>.'"
    case .none: return "'Cache found no places for <query>.'"
    case .routes, .noAnswer: return "nothing of Cache's"
    }
  }

  /// The saved places the car just listed: their names are kept for Siri, and Siri is given them again when they changed.
  static func savedPlacesListed(_ places: [CarPlace]) {
    guard CarVoiceSaved.remember(places) else { return }
    CacheShortcuts.updateAppShortcutParameters()
    log.info("car voice: Siri was given \(CarVoiceSaved.names().count) saved place names")
  }
}

/// For the CarPlay harness only (its steps plugin reaches it by this Objective-C name): runs the intent's perform() as Siri
/// would, with a name said, so the harness sees the intent's own path start guidance or show places on the car.
@objc(CarVoiceNavigation)
final class CarVoiceNavigation: NSObject {
  @objc static func runForHarness(_ name: NSString) {
    let said = name as String
    Task { @MainActor in
      var intent = CarNavigateIntent()
      intent.place = CarPlaceEntity(place: .spoken(said))
      do {
        _ = try await intent.perform()
        CarVoiceRun.log.info("car voice: the harness's request was performed")
      } catch {
        CarVoiceRun.log.info("car voice: the harness's request failed")
      }
    }
  }
}
