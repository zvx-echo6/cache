import Flutter
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import flutter_local_notifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  let folderAccess = FolderAccess()

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
    // Notebooks > Connections: a folder the person picks for Obsidian or Logseq, kept as a security-scoped bookmark.
    let folders = FlutterMethodChannel(name: "co.cache/folders", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    let access = folderAccess
    folders.setMethodCallHandler { call, result in access.handle(call, result: result) }
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
    // The log's header: the iPhone's model identifier ("iPhone17,1"). Free memory is not read here (the app's start does not
    // wait for it on iPhone).
    let memory = FlutterMethodChannel(name: "co.cache/memory", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    memory.setMethodCallHandler { call, result in
      guard call.method == "device" else {
        result(FlutterMethodNotImplemented)
        return
      }
      var info = utsname()
      uname(&info)
      let machine = withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
      }
      result(machine)
    }
    // Battery level and whether the iPhone is plugged in (lib/platform/battery.dart), for long automatic work (search indexes).
    let battery = FlutterMethodChannel(name: "co.cache/battery", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    // Monitoring is on from the start, so the first read already has the level (UIDevice reports -1 until it is on; the app
    // then treats the battery as unknown and does not hold work for it).
    UIDevice.current.isBatteryMonitoringEnabled = true
    battery.setMethodCallHandler { call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let device = UIDevice.current
      device.isBatteryMonitoringEnabled = true
      let level = device.batteryLevel
      let charging = device.batteryState == .charging || device.batteryState == .full
      let percent: Int = level < 0 ? -1 : Int((level * 100).rounded())
      // How warm the iPhone is: nominal and fair (where an iPhone sits under any steady work) run as usual, serious slows
      // background index work down ("moderate"), only critical pauses it.
      let thermal: String
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: thermal = "nominal"
      case .fair: thermal = "light"
      case .serious: thermal = "moderate"
      case .critical: thermal = "critical"
      @unknown default: thermal = "unknown"
      }
      let answer: [String: Any] = ["percent": percent, "charging": charging, "thermal": thermal]
      result(answer)
    }
    // The thermal state changed: the app reads it again at once (background index work eases off or pauses).
    NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
      battery.invokeMethod("changed", arguments: nil)
    }
  }
}

/// A folder the person picks (an Obsidian vault, a Logseq graph), kept across restarts as a security-scoped bookmark.
/// "pick" shows the folder picker and answers {"bookmark": base64, "name"} (nil when cancelled). "resolve" takes a bookmark,
/// starts access for as long as the app runs and answers {"path"} (and a fresh "bookmark" when the old one went stale).
final class FolderAccess: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var open: [String: URL] = [:]

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pick":
      pick(result)
    case "resolve":
      resolve(call.arguments as? String, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "A folder picker is already open", details: nil))
      return
    }
    guard let top = topController() else {
      result(FlutterError(code: "no_window", message: "No window to show the folder picker in", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pending = result
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = pending
    pending = nil
    guard let url = urls.first else {
      result?(nil)
      return
    }
    let started = url.startAccessingSecurityScopedResource()
    defer {
      if started { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      result?(["bookmark": data.base64EncodedString(), "name": url.lastPathComponent])
    } catch {
      result?(FlutterError(code: "bookmark", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pending
    pending = nil
    result?(nil)
  }

  private func resolve(_ base64: String?, _ result: FlutterResult) {
    guard let base64 = base64, let data = Data(base64Encoded: base64) else {
      result(FlutterError(code: "bad_bookmark", message: "Not a folder bookmark", details: nil))
      return
    }
    if let url = open[base64] {
      result(["path": url.path])
      return
    }
    var stale = false
    do {
      let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
      guard url.startAccessingSecurityScopedResource() else {
        result(FlutterError(code: "denied", message: "Cache may no longer use this folder", details: nil))
        return
      }
      open[base64] = url
      var out: [String: Any] = ["path": url.path]
      if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
        out["bookmark"] = fresh.base64EncodedString()
      }
      result(out)
    } catch {
      result(FlutterError(code: "unreachable", message: error.localizedDescription, details: nil))
    }
  }

  private func topController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
