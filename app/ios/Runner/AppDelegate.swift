import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Background updates (weather, alerts, fires): re-register the BGTaskScheduler handlers before launch finishes, and give the
    // background engine the app's plugins.
    // The weather update's identifier is registered by name here, before any is scheduled: registerLaunchHandlers() only
    // re-registers tasks iOS already holds, and BGTaskScheduler aborts the app when a task is submitted with no handler
    // (the first launch with weather on did exactly that). Same name as kBackgroundTask (lib/weather/background.dart) and
    // BGTaskSchedulerPermittedIdentifiers (Info.plist).
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.happylittle.cache.live-update",
      earliestBeginInSeconds: NSNumber(value: 30 * 60)
    )
    WorkmanagerPlugin.registerLaunchHandlers()
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Alert pop-ups are shown while the app is open too, and their taps reach Flutter.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
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
