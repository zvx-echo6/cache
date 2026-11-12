import Flutter
import os
import UIKit

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
    }
    // FlutterSceneDelegate finds the engine through the window's view controller, which is why the window is set first: it
    // then passes this connection, and every later scene event, to the plugins.
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
