import Flutter
import os
import UIKit

/// A cachelink: link (a camera scanning a device's link code), held until Dart takes it and also pushed to a running Dart on the
/// co.cache/link channel. Flutter's own deep-link routing is off (FlutterDeepLinkingEnabled in Info.plist), so the link never
/// becomes a route. Channel set up where the engine is made (AppDelegate.connect), so it is there
/// whichever scene started the engine.
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

/// Whether the phone's own window is on the phone's screen, for Dart (lib/platform/phone_window.dart, channel
/// `co.cache/phone_window`). With the car screen in use the app is not in the background while the phone lies locked in a
/// pocket, so nothing else tells the phone's own views to rest: the phone's scene says so itself, here. Only a build with the
/// car screen has the channel (AppDelegate.connect); in any other build Dart finds nobody to ask and nothing changes.
final class PhoneWindow {
  static let shared = PhoneWindow()
  /// False until a phone scene is in front: the car can start the app with the phone locked.
  private(set) var visible = false
  private var channel: FlutterMethodChannel?
  private var observers: [NSObjectProtocol] = []

  func attach(messenger: FlutterBinaryMessenger) {
    let made = FlutterMethodChannel(name: "co.cache/phone_window", binaryMessenger: messenger)
    made.setMethodCallHandler { [weak self] call, result in
      if call.method == "get" {
        result(self?.visible ?? false)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    channel = made
  }

  /// The phone's scene connected: its coming to the front and its going are followed from here on.
  func follow(_ scene: UIScene) {
    let center = NotificationCenter.default
    for observer in observers { center.removeObserver(observer) }
    observers = []
    let shown: [Notification.Name] = [UIScene.willEnterForegroundNotification, UIScene.didActivateNotification]
    let hidden: [Notification.Name] = [UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification]
    for name in shown {
      observers.append(center.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in self?.set(true) })
    }
    for name in hidden {
      observers.append(center.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in self?.set(false) })
    }
    set(scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
  }

  private func set(_ on: Bool) {
    if on == visible { return }
    visible = on
    if on {
      os_log("The phone scene came to the front", type: .info)
    } else {
      os_log("The phone scene went to the background", type: .info)
    }
    channel?.invokeMethod("changed", arguments: on)
  }
}

/// The phone's window, built here around the app's one Flutter engine (AppDelegate.obtainFlutterEngine) instead of by the
/// storyboard, whose view controller made an engine of its own that no other scene could share.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let windowScene = scene as? UIWindowScene, let app = UIApplication.shared.delegate as? AppDelegate {
      let engine = app.obtainFlutterEngine()
      // An engine shows in one view controller at a time: one left from a window that has gone is let go first.
      if engine.viewController != nil {
        engine.viewController = nil
      }
      let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
      // The launch screen stays over the Flutter view until its first frame, as it did for the storyboard's view controller.
      controller.loadDefaultSplashScreenView()
      // A scene session iOS saved from a build whose scene still named the storyboard can bring the storyboard's window, with
      // a view controller and an engine of its own: that window is kept and given this view controller in its place.
      if window != nil {
        os_log("The phone scene came with the storyboard's window: its view controller is replaced", type: .info)
      }
      let phoneWindow = window ?? UIWindow(windowScene: windowScene)
      phoneWindow.rootViewController = controller
      window = phoneWindow
      phoneWindow.makeKeyAndVisible()
      PhoneWindow.shared.follow(scene)
    }
    // FlutterSceneDelegate finds the engine through the window's view controller, which is why the window is set first: it
    // then passes this connection, and every later scene event, to the plugins.
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Cold start by a cachelink: link: it comes with the connection options. The engine and its link channel are up by now
    // (made above, or earlier by the car scene); if Dart is not listening yet the link waits for it to ask.
    for context in connectionOptions.urlContexts { LinkBridge.shared.receive(context.url) }
  }

  // Warm start: the app is running.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts { LinkBridge.shared.receive(context.url) }
  }
}
