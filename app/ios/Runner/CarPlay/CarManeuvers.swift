import CarPlay
import MapKit
import os
import UIKit

/// Turn by turn on the car screen: the phone's guidance, shown in CarPlay's own guidance panel. The twin of the Android car's
/// NavigationScreen and of what CarModels.kt makes for it; the words are Android's.
///
/// While the phone's trip says it is guiding, a CarPlay navigation session runs on the map template. Its panel shows the next
/// turn (the phone's picture name drawn by CarIcons, the phone's own words, and how far, rounded as the phone rounds), the
/// turn after it, and what is left of the trip (distance, time, arrival). Arriving and looking for a new route are told to
/// CarPlay as its own states for them, with Android's words; so is waiting for the first turn.
///
/// Lanes: while the phone shows lanes under its turn banner, the car shows them in CarPlay's one form for lanes, the panel's
/// second place as a picture with no words (the phone's lane strip, drawn by CarIcons); the turn after next waits meanwhile.
///
/// A climb ahead (the phone finds one of at least its least grade, and has a switch for showing it) is told in CarPlay's own
/// form for such news, a navigation alert that shows for a set time and goes: Android's words for it, and the shape of the
/// road ahead as its picture. The grade marker on the map is the map controller's. The bar's Overview button shows the whole
/// route north up, and the position again when pressed again.
///
/// The bar's buttons while guiding are End route and the voice switch (the car scene puts them there). End route is over on
/// the car at once, and the phone is asked to end its guidance. If the car's own navigation, or another app's, takes over,
/// CarPlay says so and the same happens.
final class CarGuidance: CarLinkListener {
  private static let log = Logger(subsystem: "co.cache.car", category: "guidance")

  // The words of the Android car screens.
  static let endRoute = "End route"
  static let arrived = "You have arrived"
  static let rerouting = "Finding a new route"
  /// The name CarPlay is given for a destination that has none.
  static let destination = "Destination"
  /// Whether the app gives CarPlay navigation metadata for the vehicle's own displays (an instrument cluster, a head-up
  /// display): off. The lanes are the only such data the app has ready; turning this on also needs every maneuver's kind
  /// and junction in CarPlay's own terms, and a car that shows them to check it in.
  static let vehicleMetadata = false
  static let climbAhead = "Climb ahead"
  /// The one button CarPlay's alert must have. Android's climb card has no button.
  static let alertButton = "OK"
  /// How long the climb alert shows before it goes by itself.
  static let climbAlertSeconds: TimeInterval = 10

  private weak var mapTemplate: CPMapTemplate?
  private var session: CPNavigationSession?
  private var trip: CPTrip?
  private var maneuvers: [CPManeuver] = []
  private var shownTurns: String?
  private var shownTurnDistance: String?
  private var shownLeft: String?
  private var shownState: String?
  /// The lane data last given to CarPlay for the vehicle (a CPLaneGuidance, iOS 17.4).
  private var vehicleLanes: AnyObject?
  private var wasArrived = false
  /// End route was pressed, or the car took guidance over: the phone's trip is not shown again until it has stopped guiding.
  private var stopping = false

  /// True while the phone guides and the car screen shows it.
  private(set) var guiding = false
  /// The phone's voice switch, as its trip says.
  private(set) var voiceOn = true
  /// The whole route is in view (the Overview button). The car scene tells the map.
  private(set) var overview = false
  var onOverview: ((Bool) -> Void)?
  /// The climb ahead now has had its alert.
  private var climbTold = false
  /// Called when guidance comes to or leaves the car screen, or the voice switch changes: the bar's buttons follow.
  var onChanged: (() -> Void)?

  init(mapTemplate: CPMapTemplate) {
    self.mapTemplate = mapTemplate
    CarLink.shared.addListener(self)
  }

  /// The car has gone. The phone keeps guiding.
  func close() {
    CarLink.shared.removeListener(self)
    onChanged = nil
    endSession()
    mapTemplate = nil
  }

  // ---- the bar's buttons -------------------------------------------------------------------------------------------------

  /// End route: over on the car at once, and the phone is asked to end its guidance.
  func endRoutePressed() {
    guard guiding else { return }
    Self.log.info("car guidance: End route pressed")
    stopGuidance()
  }

  /// CarPlay says the car's own navigation, or another app's, has taken guidance over.
  func takenOver() {
    guard guiding else { return }
    Self.log.info("car guidance: the car took guidance over")
    stopGuidance()
  }

  private func stopGuidance() {
    stopping = true
    endSession()
    CarLink.shared.call("stop")
  }

  /// A navigation alert (the climb ahead) has gone, by itself or by its button. CarPlay then shows the panel with only the
  /// next turn until it is given the turns again, so they are made and given again here.
  func alertGone() {
    guard guiding, session != nil else { return }
    shownTurns = nil
    carLinkTrip(CarLink.shared.trip)
    Self.log.info("car guidance: the alert has gone, the turns are given again")
  }

  /// The Overview button: the whole route, or the position again.
  func overviewPressed() {
    guard guiding else { return }
    overview.toggle()
    onOverview?(overview)
    onChanged?()
  }

  /// The voice switch: the phone turns its spoken prompts on or off, and its next trip says which.
  func voicePressed() {
    let on = !voiceOn
    Self.log.info("car guidance: voice asked \(on ? "on" : "off", privacy: .public)")
    CarLink.shared.call("voice", ["on": on])
  }

  // ---- the phone's trip --------------------------------------------------------------------------------------------------

  func carLinkTrip(_ t: CarTrip) {
    if !t.guiding {
      stopping = false
      if guiding {
        endSession()
        Self.log.info("car guidance: ended")
      }
      return
    }
    if stopping { return }
    guard let map = mapTemplate else { return }
    if session == nil {
      begin(t, on: map)
    }
    guard let session = session, let trip = trip else { return }
    if voiceOn != t.voiceOn {
      voiceOn = t.voiceOn
      onChanged?()
    }
    if t.arrived {
      wasArrived = true
      // Nothing is left: said to CarPlay too, or its line of what is left would keep the last numbers of the drive.
      showLeft(t, map, trip)
      say(session, .arrived, Self.arrived, state: "arrived")
      return
    }
    if t.rerouting {
      say(session, .rerouting, Self.rerouting, state: "rerouting")
      return
    }
    guard let step = t.step else {
      // The first position, or a new route, is still coming.
      say(session, .loading, nil, state: "loading")
      return
    }
    shownState = nil
    showTurns(t, step, session)
    showLeft(t, map, trip)
    tellClimb(t, map)
  }

  /// A climb ahead is told once, when it first lies ahead, unless the phone's switch for it is off.
  private func tellClimb(_ t: CarTrip, _ map: CPMapTemplate) {
    guard t.showClimb, let climb = t.climb else {
      climbTold = false
      return
    }
    if climbTold { return }
    climbTold = true
    // As the Android climb card: "Climb ahead", how much is climbed, and the steepest grade and how far off it is.
    let figure: String = CarText.climb(climb.climbAheadM, imperial: t.imperial)
    var under: [String] = []
    if let grade = climb.gradePct, let into = climb.steepestInM {
      under = ["\(CarText.grade(grade)) in \(CarText.ahead(into, imperial: t.imperial))"]
    }
    let button = CPAlertAction(title: Self.alertButton, style: .default) { [weak map] _ in
      map?.dismissNavigationAlert(animated: true) { _ in }
    }
    let alert = CPNavigationAlert(
      titleVariants: ["\(Self.climbAhead) \(figure)", Self.climbAhead], subtitleVariants: under, image: CarIcons.climbShape(climb),
      primaryAction: button, secondaryAction: nil, duration: Self.climbAlertSeconds)
    map.present(navigationAlert: alert, animated: true)
    Self.log.info("car guidance: climb alert shown")
  }

  private func begin(_ t: CarTrip, on map: CPMapTemplate) {
    let end = CLLocationCoordinate2D(latitude: t.destinationLat ?? t.lat ?? 0, longitude: t.destinationLon ?? t.lon ?? 0)
    let start = CLLocationCoordinate2D(latitude: t.lat ?? end.latitude, longitude: t.lon ?? end.longitude)
    let name = t.destinationName ?? Self.destination
    let destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
    destination.name = name
    let origin = MKMapItem(placemark: MKPlacemark(coordinate: start))
    let route = CPRouteChoice(summaryVariants: [name], additionalInformationVariants: [], selectionSummaryVariants: [name])
    let made = CPTrip(origin: origin, destination: destination, routeChoices: [route])
    trip = made
    let started = map.startNavigationSession(for: made)
    session = started
    maneuvers = []
    shownTurns = nil
    shownTurnDistance = nil
    shownLeft = nil
    shownState = nil
    wasArrived = false
    voiceOn = t.voiceOn
    guiding = true
    Self.log.info("car guidance: began")
    onChanged?()
  }

  private func endSession() {
    if let session = session {
      if wasArrived {
        session.finishTrip()
      } else {
        session.cancelTrip()
      }
    }
    session = nil
    trip = nil
    maneuvers = []
    shownTurns = nil
    shownTurnDistance = nil
    shownLeft = nil
    shownState = nil
    wasArrived = false
    climbTold = false
    vehicleLanes = nil
    if let map = mapTemplate, map.currentNavigationAlert != nil {
      map.dismissNavigationAlert(animated: false) { _ in }
    }
    if overview {
      overview = false
      onOverview?(false)
    }
    if guiding {
      guiding = false
      onChanged?()
    }
  }

  /// One of CarPlay's own states of a trip that is not showing turns, with its words. Said once, not at every position.
  private func say(_ session: CPNavigationSession, _ reason: CPNavigationSession.PauseReason, _ words: String?, state: String) {
    if shownState == state { return }
    shownState = state
    shownTurns = nil
    shownTurnDistance = nil
    climbTold = false
    session.pauseTrip(for: reason, description: words)
    Self.log.info("car guidance: \(state, privacy: .public)")
  }

  /// The next turn and the one after. The turn card is made again only when the turns change; in between only the distance
  /// to the next turn is told, and only when the number on the screen would change.
  private func showTurns(_ t: CarTrip, _ step: CarStep, _ session: CPNavigationSession) {
    var turns: String = "\(step.turn)|\(step.type)|\(step.cue)"
    if !step.lanes.isEmpty {
      // While the phone shows lanes for the turn, they have the panel's second place (CarPlay's form for lanes), and the
      // turn after it waits.
      let lanes: [String] = step.lanes.map { "\($0.role):\($0.directions.joined(separator: ",")):\($0.take ?? "")" }
      turns += "||lanes|" + lanes.joined(separator: ";")
    } else if let then = t.then {
      turns += "||\(then.turn)|\(then.type)|\(then.cue)"
    }
    let distance: String = CarText.distance(step.distanceM, imperial: t.imperial)
    let estimates = CPTravelEstimates(
      distanceRemaining: CarText.length(step.distanceM, imperial: t.imperial), timeRemaining: TimeInterval(t.turnSeconds(step)))
    if turns != shownTurns {
      shownTurns = turns
      shownTurnDistance = distance
      let first = Self.maneuver(step)
      first.initialTravelEstimates = estimates
      var list: [CPManeuver] = [first]
      if !step.lanes.isEmpty {
        list.append(Self.laneManeuver(step.lanes))
      } else if let then = t.then {
        list.append(Self.maneuver(then))
      }
      tellVehicleLanes(step, first, session)
      maneuvers = list
      session.upcomingManeuvers = list
      // No words of the turn in the log (roads, places).
      Self.log.info("car guidance: turn shown, \(list.count) maneuvers")
      if !step.lanes.isEmpty {
        Self.log.info("car guidance: lanes shown, \(step.lanes.count) lanes")
      }
    } else if distance != shownTurnDistance, let first = maneuvers.first {
      shownTurnDistance = distance
      session.updateEstimates(estimates, for: first)
    }
  }

  /// What is left of the trip, told to CarPlay when the numbers on the screen would change. Under a minute is told as one
  /// minute until the phone says arrived, as on Android.
  private func showLeft(_ t: CarTrip, _ map: CPMapTemplate, _ trip: CPTrip) {
    guard let meters = t.remainingM, let seconds = t.leftSeconds else { return }
    let left: String = "\(CarText.distance(meters, imperial: t.imperial))|\(seconds / 60)"
    if left == shownLeft { return }
    shownLeft = left
    map.updateEstimates(CPTravelEstimates(distanceRemaining: CarText.length(meters, imperial: t.imperial), timeRemaining: TimeInterval(seconds)), for: trip)
  }

  /// The lanes in CarPlay's form for them: a maneuver in the panel's second place that is a picture and no words.
  private static func laneManeuver(_ lanes: [CarLane]) -> CPManeuver {
    let maneuver = CPManeuver()
    maneuver.instructionVariants = []
    maneuver.symbolImage = CarIcons.laneStrip(lanes)
    return maneuver
  }

  /// The lanes as CarPlay's lane data (iOS 17.4), which is for the vehicle's own displays and goes nowhere unless the app
  /// provides navigation metadata (`vehicleMetadata`). CarPlay does not keep the lane guidance a maneuver is linked to, so it
  /// is kept here for as long as it is the current one.
  private func tellVehicleLanes(_ step: CarStep, _ first: CPManeuver, _ session: CPNavigationSession) {
    guard Self.vehicleMetadata, #available(iOS 17.4, *) else { return }
    guard let guidance = Self.laneGuidance(step) else {
      if vehicleLanes != nil {
        session.currentLaneGuidance = nil
        vehicleLanes = nil
      }
      return
    }
    vehicleLanes = guidance
    session.add([guidance])
    first.linkedLaneGuidance = guidance
    session.currentLaneGuidance = guidance
  }

  /// A step's lanes as CarPlay's lane data: each lane's arrows as turns (CarLane.angle), the one the route takes apart from
  /// the rest, the lane to be in as preferred and another that works as good. Nil with no lanes, without the phone's words
  /// for them (CarPlay wants words), or when the road did not say which lanes work: there is then nothing to tell.
  @available(iOS 17.4, *)
  private static func laneGuidance(_ step: CarStep) -> CPLaneGuidance? {
    guard !step.lanes.isEmpty, let words = step.lanesLabel, step.lanes.contains(where: { $0.takenAngle != nil }) else { return nil }
    func degrees(_ value: Double) -> Measurement<UnitAngle> { Measurement(value: value, unit: UnitAngle.degrees) }
    var lanes: [CPLane] = []
    for lane in step.lanes {
      let others: [Measurement<UnitAngle>] = lane.otherAngles.map(degrees)
      if #available(iOS 18.0, *) {
        if let taken = lane.takenAngle {
          lanes.append(CPLane(angles: others, highlightedAngle: degrees(taken), isPreferred: lane.role == "active"))
        } else {
          lanes.append(CPLane(angles: others))
        }
      } else {
        let made = CPLane()
        if let taken = lane.takenAngle {
          made.status = lane.role == "active" ? .preferred : .good
          made.primaryAngle = degrees(taken)
        } else {
          made.status = .notGood
        }
        made.secondaryAngles = others
        lanes.append(made)
      }
    }
    let guidance = CPLaneGuidance()
    guidance.lanes = lanes
    guidance.instructionVariants = [words]
    return guidance
  }

  private static func maneuver(_ step: CarStep) -> CPManeuver {
    let maneuver = CPManeuver()
    let blank = step.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    maneuver.instructionVariants = [blank ? " " : step.cue]
    maneuver.symbolImage = CarIcons.maneuver(step.turn)
    return maneuver
  }
}
