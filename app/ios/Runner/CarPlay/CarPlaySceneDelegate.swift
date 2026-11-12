import CarPlay
import os
import UIKit

/// Whether this build has the car screen: the CACHE_CARPLAY build setting (NO unless the build passes YES), written into
/// Info.plist. The same setting chooses the entitlements file, so a build with it off carries no CarPlay entitlement:
/// CarPlay then never shows the app and never asks it for a scene, and nothing in this folder runs.
enum CarPlayBuild {
  static let isOn = (Bundle.main.object(forInfoDictionaryKey: "CacheCarPlay") as? String) == "YES"
}

/// The car screen. For now it is empty: a map template with the two buttons of the car design, Search and Saved places,
/// which do nothing yet, over an empty base view. The scene is declared in code (AppDelegate, configurationForConnecting),
/// not in Info.plist.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
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
    template.trailingNavigationBarButtons = [
      barButton("magnifyingglass", "Search"),
      barButton("bookmark.fill", "Saved places"),
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
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController,
    from window: CPWindow
  ) {
    self.interfaceController = nil
    carWindow = nil
    Self.log.info("car scene disconnected")
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
