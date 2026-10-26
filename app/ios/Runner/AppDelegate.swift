import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let permissions = FlutterMethodChannel(
      name: "co.cache/network_access",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    permissions.setMethodCallHandler { call, result in
      switch call.method {
      case "request":
        // iOS has no app-level Internet permission prompt.
        result(true)
      case "notifications":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
          DispatchQueue.main.async {
            if let error = error {
              result(FlutterError(code: "notification_permission", message: error.localizedDescription, details: nil))
            } else {
              result(granted)
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
