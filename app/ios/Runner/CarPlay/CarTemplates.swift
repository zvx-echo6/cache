import CarPlay
import os
import UIKit

/// The car's lists: Saved places and Search. The twins of the Android car's SavedPlacesScreen and SearchScreen
/// (CarScreens.kt), written against CarPlay's own templates. The words, the order of the rows and their number are Android's.
///
/// Saved places is a list over the map with the phone's saved places, each with its distance and address, and a Search
/// button of its own. Search is CarPlay's search screen: while its box is empty it lists the saved places; typed text is
/// looked up by the phone (by name, address or kind of place; by meaning when the phone's search model is loaded) after a
/// short pause in the typing, or at once when the keyboard's search key is pressed.
///
/// Choosing a place does nothing yet: the routes to it are the next piece.
///
/// Where CarPlay's templates differ from Android's:
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
        let items = self.rows(CarPlace.list(answer), imperial: CarLink.shared.trip.imperial)
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
      let items = self.rows(CarPlace.list(answer), imperial: CarLink.shared.trip.imperial)
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
    if item.userInfo is String {
      chosen()
    }
    completionHandler()
  }

  // ---- rows ----------------------------------------------------------------------------------------------------------------

  /// A row for each place, in the order Dart gave them: the name, and under it the distance and the address.
  private func rows(_ places: [CarPlace], imperial: Bool) -> [CPListItem] {
    let limit = max(1, min(Self.maxRows, CPListTemplate.maximumItemCount))
    var items: [CPListItem] = []
    for place in places.prefix(limit) {
      let item = CPListItem(text: place.name, detailText: place.detail(imperial: imperial))
      item.userInfo = place.id
      item.handler = { [weak self] _, done in
        self?.chosen()
        done()
      }
      items.append(item)
    }
    return items
  }

  private func chosen() {
    Self.log.info("car lists: a place was chosen, nothing behind it yet")
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
  func carLinkTrip(_ trip: CarTrip) {
    guard savedTemplate != nil, saved != nil, shownImperial != trip.imperial else { return }
    showSaved()
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
