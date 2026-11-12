import CarPlay
import os
import UIKit

/// Whether this build has the car screen: the CACHE_CARPLAY build setting (NO unless the build passes YES), written into
/// Info.plist. The same setting chooses the entitlements file, so a build with it off carries no CarPlay entitlement:
/// CarPlay then never shows the app and never asks it for a scene, and nothing in this folder runs.
enum CarPlayBuild {
  static let isOn = (Bundle.main.object(forInfoDictionaryKey: "CacheCarPlay") as? String) == "YES"
}

/// The car screen: a map template over Cache's own map (CarMapViewController), with the two buttons of the car design, Search
/// and Saved places, which do nothing yet, and the map's own buttons. The scene is declared in code (AppDelegate,
/// configurationForConnecting), not in Info.plist.
///
/// It is linked to the phone's guidance (CarLink): when CarPlay opens the app, with or without the phone app open, the app's
/// one Flutter engine is running and the car knows the trip Dart pushes. The map draws the route, the destination and the
/// position from it; the turn, the distances and the arrival time are not shown yet.
///
/// The map's buttons, as on the Android car screen: Pan, Recenter (only after the map was moved), Zoom in, Zoom out. CarPlay
/// gives no way out of its panning arrows and shows at most two map buttons with them: while panning the two are Zoom in and
/// Zoom out, and the bar holds one button, Done, in place of Search and Saved places.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate, CarLinkListener {
  private static let log = Logger(subsystem: "co.cache.car", category: "scene")
  private var interfaceController: CPInterfaceController?
  private var carWindow: CPWindow?
  private var mapTemplate: CPMapTemplate?
  private var mapController: CarMapViewController?
  private var panning = false
  private var heldPan: Timer?

  private lazy var searchButton = barButton("magnifyingglass", "Search")
  private lazy var savedButton = barButton("bookmark", "Saved places")
  private lazy var doneButton = CPBarButton(title: "Done") { [weak self] _ in self?.endPanning() }
  private lazy var panButton = mapButton("arrow.up.and.down.and.arrow.left.and.right") { [weak self] in self?.beginPanning() }
  private lazy var recenterButton = mapButton("location.fill") { [weak self] in self?.mapController?.recenter() }
  private lazy var zoomInButton = mapButton("plus") { [weak self] in self?.mapController?.zoomIn() }
  private lazy var zoomOutButton = mapButton("minus") { [weak self] in self?.mapController?.zoomOut() }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController,
    to window: CPWindow
  ) {
    self.interfaceController = interfaceController
    carWindow = window
    // Most cars are in their dark setting; anything but a plain "light" is drawn dark.
    let dark = templateApplicationScene.contentStyle != .light
    let controller = CarMapViewController(dark: dark)
    controller.onFollowingChanged = { [weak self] in self?.showButtons() }
    window.rootViewController = controller
    mapController = controller

    let template = CPMapTemplate()
    template.mapDelegate = self
    // The buttons stay: by default the bar hides after a while with no touch.
    template.automaticallyHidesNavigationBar = false
    mapTemplate = template
    panning = false
    showButtons()
    interfaceController.setRootTemplate(template, animated: false) { _, error in
      if let error = error {
        Self.log.error("car scene: the map template was refused: \(error.localizedDescription, privacy: .public)")
      }
    }
    let width = Int(window.bounds.width)
    let height = Int(window.bounds.height)
    let scale = Int(window.screen.scale)
    Self.log.info("car scene connected, \(width) x \(height) points at \(scale)x")
    Self.log.info("car scene: the car's day and night setting is \(dark ? "dark" : "light", privacy: .public)")

    // The root template is set; only now the engine, which takes a moment on the main thread when the car is the one to start
    // it (CarPlay opened Cache with the phone app closed). Dart's start-up then runs with no view, and says hello when its
    // car bridge is up; if the phone started the engine, Dart is told at once that a car is here.
    if let app = UIApplication.shared.delegate as? AppDelegate {
      _ = app.obtainFlutterEngine()
    }
    // The map view only after the engine: its plugins are registered by then (see CarMapViewController.startMap).
    controller.startMap()
    CarLink.shared.addListener(self)
    CarLink.shared.setCarConnected(true)
    Self.log.info("car link: car connected, Dart ready: \(CarLink.shared.dartReady)")
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController,
    from window: CPWindow
  ) {
    stopHeldPan()
    panning = false
    mapController?.release()
    mapController = nil
    mapTemplate = nil
    self.interfaceController = nil
    carWindow = nil
    CarLink.shared.removeListener(self)
    CarLink.shared.setCarConnected(false)
    Self.log.info("car scene disconnected")
  }

  /// The car switched between its day and night settings.
  func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
    let dark = contentStyle != .light
    Self.log.info("car scene: the car's day and night setting is now \(dark ? "dark" : "light", privacy: .public)")
    mapController?.setDark(dark)
  }

  // ---- what Dart pushes. The map draws from it (CarMapViewController); the lines say what arrived. ------------------------

  func carLinkDartReady() {
    Self.log.info("car link: Dart is ready")
  }

  func carLinkTrip(_ trip: CarTrip) {
    // No words of the trip in the log (roads, places): the phase and the counts are enough to see it arrive.
    let hasStep = trip.step != nil
    let left = Int(trip.remainingM ?? -1)
    Self.log.info("car link: trip \(trip.phase, privacy: .public), \(trip.routes.count) routes, next step \(hasStep), \(left) m left")
  }

  func carLinkRoute(geojson: String, bounds: [Double]?) {
    Self.log.info("car link: route line, \(geojson.utf8.count) bytes, bounds \(bounds?.count ?? 0) numbers")
  }

  func carLinkSavedChanged() {
    Self.log.info("car link: saved places changed")
  }

  func carLinkStyleChanged() {
    Self.log.info("car link: map style changed")
  }

  func carLinkNotice(_ text: String) {
    Self.log.info("car link: notice, \(text.count) characters")
  }

  // ---- the buttons ---------------------------------------------------------------------------------------------------------

  /// Puts the buttons that belong to the moment on the template: see the note at the top.
  private func showButtons() {
    guard let template = mapTemplate else { return }
    if panning {
      template.mapButtons = [zoomInButton, zoomOutButton]
      template.trailingNavigationBarButtons = [doneButton]
      return
    }
    var buttons: [CPMapButton] = [panButton]
    if let map = mapController, !map.following {
      buttons.append(recenterButton)
    }
    buttons.append(zoomInButton)
    buttons.append(zoomOutButton)
    template.mapButtons = buttons
    // Search on the left and Saved places on the right, as on the Android car screen: CarPlay lays the trailing buttons out
    // from the edge inwards, so the one at the edge comes first.
    template.trailingNavigationBarButtons = [savedButton, searchButton]
  }

  private func barButton(_ symbol: String, _ name: String) -> CPBarButton {
    CPBarButton(image: UIImage(systemName: symbol) ?? UIImage()) { _ in
      Self.log.info("car button pressed, nothing behind it yet: \(name, privacy: .public)")
    }
  }

  private func mapButton(_ symbol: String, _ pressed: @escaping () -> Void) -> CPMapButton {
    let button = CPMapButton { _ in pressed() }
    button.image = UIImage(systemName: symbol)
    return button
  }

  // ---- panning -------------------------------------------------------------------------------------------------------------

  private func beginPanning() {
    guard let template = mapTemplate, !panning else { return }
    panning = true
    showButtons()
    template.showPanningInterface(animated: true)
    Self.log.info("car map: panning began")
  }

  private func endPanning() {
    guard let template = mapTemplate, panning else { return }
    panning = false
    stopHeldPan()
    template.dismissPanningInterface(animated: true)
    showButtons()
    Self.log.info("car map: panning ended")
  }

  private func stopHeldPan() {
    heldPan?.invalidate()
    heldPan = nil
  }

  /// One step of the map towards a side: what lies that way comes into view.
  private func step(_ direction: CPMapTemplate.PanDirection) {
    guard let map = mapController else { return }
    let by = map.panStep
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    if direction.contains(.left) { dx -= by }
    if direction.contains(.right) { dx += by }
    if direction.contains(.up) { dy -= by }
    if direction.contains(.down) { dy += by }
    if dx != 0 || dy != 0 {
      map.pan(dx: dx, dy: dy, animated: true)
    }
  }

  /// A panning arrow was pressed, or the knob turned.
  func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
    step(direction)
  }

  /// A panning arrow is being held down: a step now and then until it is let go.
  func mapTemplate(_ mapTemplate: CPMapTemplate, panBeganWith direction: CPMapTemplate.PanDirection) {
    stopHeldPan()
    heldPan = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
      self?.step(direction)
    }
  }

  func mapTemplate(_ mapTemplate: CPMapTemplate, panEndedWith direction: CPMapTemplate.PanDirection) {
    stopHeldPan()
  }

  /// A finger drags the map on a touch screen: each call brings how far it moved since the one before.
  func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
    mapController?.pan(dx: -translation.x, dy: -translation.y, animated: false)
  }

  /// Panning ended, by Done or by CarPlay itself.
  func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
    stopHeldPan()
    if panning {
      panning = false
      showButtons()
    }
  }
}
