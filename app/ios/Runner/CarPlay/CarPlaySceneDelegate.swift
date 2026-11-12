import CarPlay
import os
import UIKit

/// Whether this build has the car screen: the CACHE_CARPLAY build setting (NO unless the build passes YES), written into
/// Info.plist. The same setting chooses the entitlements file, so a build with it off carries no CarPlay entitlement:
/// CarPlay then never shows the app and never asks it for a scene, and nothing in this folder runs.
enum CarPlayBuild {
  static let isOn = (Bundle.main.object(forInfoDictionaryKey: "CacheCarPlay") as? String) == "YES"
}

/// The car screen. For now it shows an empty map template with the two buttons of the car design, Search and Saved places,
/// which do nothing yet, over an empty base view. The scene is declared in code (AppDelegate, configurationForConnecting),
/// not in Info.plist.
///
/// It is linked to the phone's guidance (CarLink): when CarPlay opens the app, with or without the phone app open, the app's
/// one Flutter engine is running and the car knows the trip Dart pushes. Nothing of the trip is drawn yet.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CarLinkListener {
  private static let log = Logger(subsystem: "co.cache.car", category: "scene")
  private var interfaceController: CPInterfaceController?
  private var carWindow: CPWindow?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController,
    to window: CPWindow
  ) {
    self.interfaceController = interfaceController
    carWindow = window
    window.rootViewController = CarMapViewController()

    let template = CPMapTemplate()
    // The buttons stay: by default the bar hides after a while with no touch.
    template.automaticallyHidesNavigationBar = false
    // Search on the left and Saved places on the right, as on the Android car screen: CarPlay lays the trailing buttons out
    // from the edge inwards, so the one at the edge comes first.
    template.trailingNavigationBarButtons = [
      barButton("bookmark", "Saved places"),
      barButton("magnifyingglass", "Search"),
    ]
    interfaceController.setRootTemplate(template, animated: false) { _, error in
      if let error = error {
        Self.log.error("car scene: the map template was refused: \(error.localizedDescription, privacy: .public)")
      }
    }
    let width = Int(window.bounds.width)
    let height = Int(window.bounds.height)
    let scale = Int(window.screen.scale)
    Self.log.info("car scene connected, \(width) x \(height) points at \(scale)x")

    // The root template is set; only now the engine, which takes a moment on the main thread when the car is the one to start
    // it (CarPlay opened Cache with the phone app closed). Dart's start-up then runs with no view, and says hello when its
    // car bridge is up; if the phone started the engine, Dart is told at once that a car is here.
    if let app = UIApplication.shared.delegate as? AppDelegate {
      _ = app.obtainFlutterEngine()
    }
    CarLink.shared.addListener(self)
    CarLink.shared.setCarConnected(true)
    Self.log.info("car link: car connected, Dart ready: \(CarLink.shared.dartReady)")
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController,
    from window: CPWindow
  ) {
    self.interfaceController = nil
    carWindow = nil
    CarLink.shared.removeListener(self)
    CarLink.shared.setCarConnected(false)
    Self.log.info("car scene disconnected")
  }

  // What Dart pushes. Nothing is drawn from it yet; the lines say what arrived.

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

  private func barButton(_ symbol: String, _ name: String) -> CPBarButton {
    CPBarButton(image: UIImage(systemName: symbol) ?? UIImage()) { _ in
      Self.log.info("car button pressed, nothing behind it yet: \(name, privacy: .public)")
    }
  }
}

/// The base view of the map template, where the map will be drawn. Empty for now: one plain colour.
final class CarMapViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.90, green: 0.89, blue: 0.84, alpha: 1)
  }
}
