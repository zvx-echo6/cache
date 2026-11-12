import CarPlay
import MapKit
import os
import UIKit

/// The car's lists and the routes to a place: Saved places, Search and the route preview. The twins of the Android car's
/// SavedPlacesScreen, SearchScreen and RoutePreviewScreen (CarScreens.kt), written against CarPlay's own templates. The words,
/// the order of the rows and their number are Android's.
///
/// Saved places is a list over the map with the phone's saved places, each with its distance and address, and a Search
/// button of its own. Search is CarPlay's search screen: while its box is empty it lists the saved places; typed text is
/// looked up by the phone (by name, address or kind of place; by meaning when the phone's search model is loaded) after a
/// short pause in the typing, or at once when the keyboard's search key is pressed.
///
/// Choosing a place goes back to the map and asks the phone for the routes to it. When they are there CarPlay's own route
/// panel shows them on the map template: each route with its time and distance and the road it takes, and Start. Choosing
/// another route makes the phone draw that one; Start begins the phone's guidance; the bar's Back leaves, and the phone
/// forgets the routes. A route that cannot be found is said in a system alert.
///
/// Where CarPlay's templates differ from Android's:
/// - The route panel is CarPlay's: its start button says Android's "Start", and its other two buttons keep CarPlay's own words.
/// - While the phone is still finding the routes CarPlay has nothing to show (Android: a spinner): the map stays as it is.
/// - A route that cannot be found is shown in an alert, which needs a button (Android: a message, left with Back).
/// - The search box has CarPlay's own hint; an app cannot set one (Android: "Search for a place").
/// - The search screen has no line for "nothing found": the words are shown as one row that cannot be chosen.
/// - A list shows its "nothing here" words as a title and a line under it: Android's one line is split at its full stop.
/// - A list that is still waiting for the phone shows a spinner from iOS 18.4, and is plain before that.
final class CarTemplates: NSObject, CPInterfaceControllerDelegate, CPSearchTemplateDelegate, CPSessionConfigurationDelegate, CarLinkListener {
  private static let log = Logger(subsystem: "co.cache.car", category: "lists")

  // The words of the Android car screens.
  static let savedTitle = "Saved places"
  static let noSavedTitle = "No saved places yet."
  static let noSavedDetail = "Search for a place to go."
  static let noPlacesFound = "No places found"
  static let start = "Start"
  /// The one button of the alert that says a route could not be found. Android has no such button (its Back key leaves).
  static let errorButton = "OK"
  /// The most routes shown for a place, as the phone gives them.
  static let maxRoutes = 3
  /// The most rows a list shows, as on Android.
  static let maxRows = 6
  /// How long the typing has to pause before the phone is asked, as on Android.
  static let typingPause: TimeInterval = 0.6

  private weak var interface: CPInterfaceController?
  private var session: CPSessionConfiguration?

  private var savedTemplate: CPListTemplate?
  private var saved: [CarPlace]?
  private var shownImperial: Bool?
  private var retry: DispatchWorkItem?

  private var searchTemplate: CPSearchTemplate?
  private var searchSeq = 0
  private var searchText = ""
  private var pendingSearch: DispatchWorkItem?
  private var waiting: (([CPListItem]) -> Void)?
  private var shownResults: [CPListItem] = []

  /// The map template, whose route panel shows the routes to a place.
  weak var mapTemplate: CPMapTemplate?
  /// True from the moment a place was chosen in the car until its routes are left or guidance began.
  private(set) var previewing = false
  /// Called when `previewing` changes, so the map's bar shows Back in place of Search and Saved places.
  var onPreviewChanged: (() -> Void)?
  private var previewPlace: CarPlace?
  private var previewStarted = false
  private var sawRoutes = false
  private var shownRoutes: String?
  private var previewTrip: CPTrip?
  private var shownError: String?
  private var places: [String: CarPlace] = [:]

  /// False while the car does not allow its keyboard (many do not while moving): Search is then greyed.
  private(set) var searchAllowed = true

  /// Called when `searchAllowed` changes, so the map's own Search button follows.
  var onSearchAllowedChanged: (() -> Void)?

  private lazy var listSearchButton = CPBarButton(image: UIImage(systemName: "magnifyingglass") ?? UIImage()) { [weak self] _ in
    self?.openSearch()
  }

  init(interface: CPInterfaceController) {
    self.interface = interface
    super.init()
    interface.delegate = self
    let session = CPSessionConfiguration(delegate: self)
    self.session = session
    searchAllowed = !session.limitedUserInterfaces.contains(.keyboard)
    CarLink.shared.addListener(self)
  }

  /// The car has gone.
  func close() {
    CarLink.shared.removeListener(self)
    retry?.cancel()
    retry = nil
    pendingSearch?.cancel()
    pendingSearch = nil
    waiting = nil
    savedTemplate = nil
    searchTemplate = nil
    session = nil
    onSearchAllowedChanged = nil
    onPreviewChanged = nil
    previewing = false
    previewPlace = nil
    previewTrip = nil
    shownRoutes = nil
    shownError = nil
    mapTemplate = nil
    interface?.delegate = nil
    interface = nil
  }

  // ---- saved places ------------------------------------------------------------------------------------------------------

  func openSaved() {
    guard let interface = interface, !isShown(savedTemplate) else { return }
    let template = CPListTemplate(title: Self.savedTitle, sections: [])
    template.trailingNavigationBarButtons = [listSearchButton]
    listSearchButton.isEnabled = searchAllowed
    if #available(iOS 18.4, *) {
      template.showsSpinnerWhileEmpty = true
    }
    savedTemplate = template
    saved = nil
    shownImperial = nil
    interface.pushTemplate(template, animated: true) { _, error in
      if let error = error {
        Self.log.error("car lists: saved places could not be shown: \(error.localizedDescription, privacy: .public)")
      }
    }
    Self.log.info("car lists: saved places opened")
    loadSaved()
  }

  private func loadSaved() {
    retry?.cancel()
    retry = nil
    guard savedTemplate != nil else { return }
    CarLink.shared.call("saved") { [weak self] answer in
      guard let self = self, self.savedTemplate != nil else { return }
      if answer == nil && !CarLink.shared.dartReady {
        // The car started the app and Dart is not up yet: ask again shortly.
        let work = DispatchWorkItem { [weak self] in self?.loadSaved() }
        self.retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        return
      }
      self.saved = CarPlace.list(answer)
      self.showSaved()
    }
  }

  private func showSaved() {
    guard let template = savedTemplate, let places = saved else { return }
    let imperial = CarLink.shared.trip.imperial
    shownImperial = imperial
    let items = rows(places, imperial: imperial)
    if #available(iOS 18.4, *) {
      template.showsSpinnerWhileEmpty = false
    }
    if items.isEmpty {
      template.emptyViewTitleVariants = [Self.noSavedTitle]
      template.emptyViewSubtitleVariants = [Self.noSavedDetail]
      template.updateSections([])
    } else {
      template.updateSections([CPListSection(items: items)])
    }
    // No words of the places in the log: the count is enough to see them arrive.
    Self.log.info("car lists: saved places shown, \(items.count) rows")
  }

  // ---- search ------------------------------------------------------------------------------------------------------------

  func openSearch() {
    guard let interface = interface, searchAllowed, !isShown(searchTemplate) else { return }
    let template = CPSearchTemplate()
    template.delegate = self
    searchTemplate = template
    searchSeq += 1
    searchText = ""
    pendingSearch?.cancel()
    pendingSearch = nil
    waiting = nil
    shownResults = []
    interface.pushTemplate(template, animated: true) { _, error in
      if let error = error {
        Self.log.error("car lists: search could not be shown: \(error.localizedDescription, privacy: .public)")
      }
    }
    Self.log.info("car lists: search opened")
  }

  /// CarPlay asks for the rows under the box: when the search screen comes up (with an empty box) and at every change.
  func searchTemplate(
    _ searchTemplate: CPSearchTemplate,
    updatedSearchText searchText: String,
    completionHandler: @escaping ([CPListItem]) -> Void
  ) {
    pendingSearch?.cancel()
    pendingSearch = nil
    // CarPlay waits for an answer to every one of these calls: the one before gets what is on the screen.
    waiting?(shownResults)
    waiting = completionHandler
    searchSeq += 1
    let mine = searchSeq
    self.searchText = searchText
    // No typed words in the log.
    Self.log.info("car lists: search asked, \(searchText.count) characters")
    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      // The box is empty: the saved places (none, and the list is empty).
      CarLink.shared.call("saved") { [weak self] answer in
        guard let self = self, mine == self.searchSeq else { return }
        let items = self.rows(CarPlace.list(answer), imperial: CarLink.shared.trip.imperial, forSearch: true)
        self.answerSearch(items)
        Self.log.info("car lists: search shown, \(items.count) saved places under the empty box")
      }
      return
    }
    let work = DispatchWorkItem { [weak self] in self?.find(mine) }
    pendingSearch = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingPause, execute: work)
  }

  /// The keyboard's search key: no waiting for a pause in the typing.
  func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
    guard let work = pendingSearch else { return }
    work.cancel()
    find(searchSeq)
  }

  private func find(_ mine: Int) {
    pendingSearch = nil
    guard mine == searchSeq else { return }
    CarLink.shared.call("search", ["query": searchText]) { [weak self] answer in
      guard let self = self, mine == self.searchSeq else { return }
      let items = self.rows(CarPlace.list(answer), imperial: CarLink.shared.trip.imperial, forSearch: true)
      if items.isEmpty {
        let none = CPListItem(text: Self.noPlacesFound, detailText: nil)
        none.isEnabled = false
        self.answerSearch([none])
        Self.log.info("car lists: search shown, no places found")
      } else {
        self.answerSearch(items)
        Self.log.info("car lists: search shown, \(items.count) places")
      }
    }
  }

  private func answerSearch(_ items: [CPListItem]) {
    shownResults = items
    let answer = waiting
    waiting = nil
    answer?(items)
  }

  func searchTemplate(
    _ searchTemplate: CPSearchTemplate,
    selectedResult item: CPListItem,
    completionHandler: @escaping () -> Void
  ) {
    if let id = item.userInfo as? String, let place = places[id] {
      chosen(place)
    }
    completionHandler()
  }

  // ---- rows ----------------------------------------------------------------------------------------------------------------

  /// A row for each place, in the order Dart gave them: the name, and under it the distance and the address.
  private func rows(_ places: [CarPlace], imperial: Bool, forSearch: Bool = false) -> [CPListItem] {
    let limit = max(1, min(Self.maxRows, CPListTemplate.maximumItemCount))
    var items: [CPListItem] = []
    for place in places.prefix(limit) {
      let item = CPListItem(text: place.name, detailText: place.detail(imperial: imperial))
      item.userInfo = place.id
      self.places[place.id] = place
      // In a list the row's own handler says it was chosen; the search screen says so itself (selectedResult).
      if !forSearch {
        item.handler = { [weak self] _, done in
          self?.chosen(place)
          done()
        }
      }
      items.append(item)
    }
    return items
  }

  /// A place was chosen in a list or in Search: back to the map, and the routes to it.
  private func chosen(_ place: CarPlace) {
    guard let interface = interface else { return }
    // No name of the place in the log.
    Self.log.info("car lists: a place was chosen")
    interface.popToRootTemplate(animated: true) { _, _ in }
    openRoutes(to: place)
  }

  // ---- the routes to a place -----------------------------------------------------------------------------------------

  private func openRoutes(to place: CarPlace) {
    if previewTrip != nil {
      mapTemplate?.hideTripPreviews()
      previewTrip = nil
    }
    previewPlace = place
    previewStarted = false
    sawRoutes = false
    shownRoutes = nil
    if !previewing {
      previewing = true
      onPreviewChanged?()
    }
    Self.log.info("car routes: directions asked")
    CarLink.shared.call("directions", ["id": place.id]) { [weak self] answer in
      guard let self = self, self.previewing, self.previewPlace == place else { return }
      if !CarValue.isTrue(answer) {
        // The phone does not know the place any more, or Dart is not up: there is nothing to show.
        Self.log.info("car routes: the phone has no directions to give")
        self.endPreview(tellDart: false)
        return
      }
      self.showRoutes(CarLink.shared.trip)
    }
  }

  /// What the route panel shows follows the phone's trip, as the Android route screen does.
  private func showRoutes(_ t: CarTrip) {
    guard previewing, let place = previewPlace else { return }
    if t.previewing { sawRoutes = true }
    if t.guiding {
      // Guidance began (Start here, or on the phone) after the routes were up: the panel goes. A trip that was still
      // guiding an older route when the place was chosen is waited out.
      if previewStarted || sawRoutes { endPreview(tellDart: false) }
      return
    }
    if previewStarted { return }
    if !t.previewing {
      // The phone left the routes by itself.
      if sawRoutes { endPreview(tellDart: false) }
      return
    }
    if !t.routing, let error = t.error {
      showRouteError(error)
      return
    }
    hideRouteError()
    guard !t.routing, !t.routes.isEmpty, let map = mapTemplate else { return }
    // Shown again only when the routes themselves changed: CarPlay keeps which one is chosen, and showing the panel
    // again would put its choice back on the first.
    let routes = Array(t.routes.prefix(Self.maxRoutes))
    let name = t.destinationName ?? place.name
    var signature: String = "\(name)|\(t.imperial)"
    for route in routes {
      let via: String = route.via ?? ""
      signature += "|\(route.index):\(route.distanceM):\(route.durationS):\(via)"
    }
    if signature == shownRoutes { return }
    shownRoutes = signature

    let end = CLLocationCoordinate2D(latitude: t.destinationLat ?? place.lat, longitude: t.destinationLon ?? place.lon)
    let begin = CLLocationCoordinate2D(latitude: t.lat ?? end.latitude, longitude: t.lon ?? end.longitude)
    let destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
    destination.name = name
    let origin = MKMapItem(placemark: MKPlacemark(coordinate: begin))
    var choices: [CPRouteChoice] = []
    for route in routes {
      // As the Android rows: the time and the distance, and under them the road the route takes. CarPlay shows the first and
      // the third of these texts as the two lines of a row in its list of routes, and the second on the panel's first view,
      // under the place's name (where it writes the time and distance itself, from numbers).
      let title = route.title(imperial: t.imperial)
      let via: [String] = route.via.map { [$0] } ?? []
      let choice = CPRouteChoice(summaryVariants: [title], additionalInformationVariants: via, selectionSummaryVariants: via)
      choice.userInfo = route.index
      choices.append(choice)
    }
    let trip = CPTrip(origin: origin, destination: destination, routeChoices: choices)
    previewTrip = trip
    // Android's word on the start button; CarPlay's own words on its other two.
    let words = CPTripPreviewTextConfiguration(startButtonTitle: Self.start, additionalRoutesButtonTitle: nil, overviewButtonTitle: nil)
    map.showTripPreviews([trip], textConfiguration: words)
    // The panel's first view names the place and the chosen route's road; its time and distance are CarPlay's to write,
    // from numbers.
    let selected = routes.first { $0.index == t.routeIndex } ?? routes[0]
    tellEstimates(selected, imperial: t.imperial)
    Self.log.info("car routes: preview shown, \(choices.count) routes")
  }

  /// The time and the distance of a route, for CarPlay to write on the route panel.
  private func tellEstimates(_ route: CarRoute, imperial: Bool) {
    guard let map = mapTemplate, let trip = previewTrip else { return }
    let estimates = CPTravelEstimates(
      distanceRemaining: CarText.length(route.distanceM, imperial: imperial), timeRemaining: TimeInterval(route.durationS))
    map.updateEstimates(estimates, for: trip)
  }

  /// CarPlay says which route of the panel is chosen: the phone draws that one.
  func routeChosen(_ choice: CPRouteChoice) {
    guard previewing, !previewStarted, let index = choice.userInfo as? Int else { return }
    Self.log.info("car routes: route \(index + 1) chosen")
    let t = CarLink.shared.trip
    if let route = t.routes.first(where: { $0.index == index }) {
      tellEstimates(route, imperial: t.imperial)
    }
    if index != t.routeIndex {
      CarLink.shared.call("selectRoute", ["index": index])
    }
  }

  /// Start, on the route panel.
  func startPressed(_ choice: CPRouteChoice) {
    guard previewing, !previewStarted else { return }
    previewStarted = true
    Self.log.info("car routes: Start pressed")
    if let index = choice.userInfo as? Int, index != CarLink.shared.trip.routeIndex {
      CarLink.shared.call("selectRoute", ["index": index])
    }
    mapTemplate?.hideTripPreviews()
    previewTrip = nil
    CarLink.shared.call("start") { [weak self] answer in
      guard let self = self, self.previewing, self.previewStarted, !CarValue.isTrue(answer) else { return }
      // The phone did not begin guidance: the routes are shown again.
      Self.log.info("car routes: guidance did not begin")
      self.previewStarted = false
      self.shownRoutes = nil
      self.showRoutes(CarLink.shared.trip)
    }
  }

  /// The bar's Back while the routes are up.
  func leaveRoutes() {
    guard previewing else { return }
    Self.log.info("car routes: preview left")
    endPreview(tellDart: !previewStarted)
  }

  private func endPreview(tellDart: Bool) {
    let was = previewing
    previewing = false
    previewPlace = nil
    previewStarted = false
    sawRoutes = false
    shownRoutes = nil
    if previewTrip != nil {
      mapTemplate?.hideTripPreviews()
      previewTrip = nil
    }
    hideRouteError()
    if tellDart {
      CarLink.shared.call("cancel")
    }
    if was {
      onPreviewChanged?()
    }
  }

  private func showRouteError(_ text: String) {
    guard shownError != text, let interface = interface else { return }
    hideRouteError()
    if previewTrip != nil {
      mapTemplate?.hideTripPreviews()
      previewTrip = nil
      shownRoutes = nil
    }
    shownError = text
    let button = CPAlertAction(title: Self.errorButton, style: .cancel) { [weak self] _ in
      self?.leaveRoutes()
    }
    let alert = CPAlertTemplate(titleVariants: [text], actions: [button])
    interface.presentTemplate(alert, animated: true) { _, error in
      if let error = error {
        Self.log.error("car routes: the alert could not be shown: \(error.localizedDescription, privacy: .public)")
      }
    }
    // The words are the phone's; the log only says that they are up.
    Self.log.info("car routes: an alert says the route could not be found, \(text.count) characters")
  }

  private func hideRouteError() {
    guard shownError != nil else { return }
    shownError = nil
    interface?.dismissTemplate(animated: true) { _, _ in }
  }

  // ---- what is on the screen -------------------------------------------------------------------------------------------

  private func isShown(_ template: CPTemplate?) -> Bool {
    guard let template = template, let interface = interface else { return false }
    return interface.templates.contains { $0 === template }
  }

  /// A list or the search screen was left (CarPlay's own Back or close button): it is let go.
  func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
    if let template = searchTemplate, aTemplate === template, !isShown(template) {
      searchTemplate = nil
      searchSeq += 1
      pendingSearch?.cancel()
      pendingSearch = nil
      waiting = nil
      shownResults = []
      Self.log.info("car lists: search closed")
    }
    if let template = savedTemplate, aTemplate === template, !isShown(template) {
      savedTemplate = nil
      saved = nil
      retry?.cancel()
      retry = nil
      Self.log.info("car lists: saved places closed")
    }
  }

  // ---- what Dart pushes, and what the car allows -----------------------------------------------------------------------

  /// The phone's saved places changed, or the core opened after the first ask (the car started the app): ask again.
  func carLinkSavedChanged() {
    loadSaved()
  }

  /// The list does not change with every position; only the units its distances are in can (the first trip says which).
  /// The route panel follows the trip.
  func carLinkTrip(_ trip: CarTrip) {
    if savedTemplate != nil, saved != nil, shownImperial != trip.imperial {
      showSaved()
    }
    if previewing {
      showRoutes(trip)
    }
  }

  func sessionConfiguration(
    _ sessionConfiguration: CPSessionConfiguration,
    limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
  ) {
    let allowed = !limitedUserInterfaces.contains(.keyboard)
    if allowed == searchAllowed { return }
    searchAllowed = allowed
    listSearchButton.isEnabled = allowed
    Self.log.info("car lists: the car allows its keyboard: \(allowed)")
    onSearchAllowedChanged?()
  }
}
