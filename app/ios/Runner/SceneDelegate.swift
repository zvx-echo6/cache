import Flutter
import UIKit

/// A cachelink: link (a camera scanning a device's link code), held until Dart takes it and also pushed to a running Dart on the
/// co.cache/link channel. Flutter's own deep-link routing is off (FlutterDeepLinkingEnabled in Info.plist), so the link never
/// becomes a route. Channel set up in AppDelegate.didInitializeImplicitFlutterEngine.
final class LinkBridge {
  static let shared = LinkBridge()
  private var pending: String?
  var channel: FlutterMethodChannel?

  func take() -> String? {
    let link = pending
    pending = nil
    return link
  }

  func receive(_ url: URL) {
    guard url.scheme?.lowercased() == "cachelink" else { return }
    let link = url.absoluteString
    pending = link
    channel?.invokeMethod("opened", arguments: link) { [weak self] reply in
      // Delivered when Dart answered; otherwise (Dart not listening yet) it stays for take().
      if reply is FlutterError { return }
      if let o = reply as AnyObject?, o === (FlutterMethodNotImplemented as AnyObject) { return }
      if self?.pending == link { self?.pending = nil }
    }
  }
}

class SceneDelegate: FlutterSceneDelegate {
  // Cold start: the link comes with the connection options.
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts { LinkBridge.shared.receive(context.url) }
  }

  // Warm start: the app is running.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts { LinkBridge.shared.receive(context.url) }
  }
}
