import AVFoundation
import CarPlay
import CoreBluetooth
import Flutter
import Darwin
import MapLibre
import os
import Security
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import flutter_local_notifications
import workmanager_apple

/// Permission and power UI only. Prns owns the restoration-aware data managers and all BLE packet traffic.
private final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
  private var manager: CBCentralManager?
  private var handle: Int64?

  private func prepare() {
    if manager == nil {
      manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
  }

  func request() {
    if CBManager.authorization == .denied || CBManager.authorization == .restricted {
      if let settings = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(settings) }
    } else {
      prepare()
    }
  }

  func status() -> [String: Any] {
    let authorized = CBManager.authorization == .allowedAlways
    // Polling an undecided permission must never create a manager and display a system prompt.
    if authorized { prepare() }
    let supported = manager?.state != .unsupported
    let enabled = authorized && manager?.state == .poweredOn
    if !enabled { handle = nil }
    let selected: Any = handle.map { NSNumber(value: $0) as Any } ?? NSNull()
    return ["supported": supported, "enabled": enabled, "missing_permissions": authorized ? [] : ["bluetooth"],
            "handle": selected, "active": enabled && handle != nil]
  }

  func select(_ value: Int64) { handle = value }
  func stop(expected: Int64?) {
    if let expected, expected != handle { return }
    handle = nil
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .poweredOn { handle = nil }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  let folderAccess = FolderAccess()
  let routeSnapshot = RouteSnapshot()
  private let bluetoothAccess = BluetoothAccess()
  /// The app's one Flutter engine. It is made by the first scene that needs it (obtainFlutterEngine), not by a storyboard's
  /// view controller, so that it does not belong to one window: a window is built around it (SceneDelegate.swift).
  private var flutterEngine: FlutterEngine?
  /// The CPR metronome's tick, ready to play again and again (see the co.cache/cpr channel).
  private var cprTick: AVAudioPlayer?

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
    // Background sync with linked devices (lib/background/sync_background.dart): an app-refresh task, and a processing task for
    // while the phone charges. iOS decides if and when either runs. Same names as kSyncRefreshTask and kSyncProcessingTask and
    // BGTaskSchedulerPermittedIdentifiers (Info.plist); registered before launch finishes, as the weather update is.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.happylittle.cache.sync-refresh",
      earliestBeginInSeconds: NSNumber(value: 60 * 60)
    )
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "com.happylittle.cache.sync-processing")
    WorkmanagerPlugin.registerLaunchHandlers()
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Alert pop-ups are shown while the app is open too, and their taps reach Flutter.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if launchOptions?[.bluetoothCentrals] != nil || launchOptions?[.bluetoothPeripherals] != nil {
      // Give the existing Sharing startup a chance to recreate Prns's restoration-aware managers on a Bluetooth relaunch.
      // Restoration/background delivery still requires real-device proof; no scene is required to start this engine.
      _ = obtainFlutterEngine()
    }
    return launched
  }

  /// The app's Flutter engine: made, started and given its plugins and channels by the first caller, the same engine for
  /// every later one. It starts at the first scene, not when the process starts, so a launch with no scene (the weather
  /// update, a location relaunch) stays as light as it was.
  ///
  /// What the storyboard's view controller used to do for its own engine is done here, in the same order: the engine with the
  /// name and settings Flutter gave it ("io.flutter", no state restoration), the plugins and the app's channels, then the two
  /// launch events Flutter sends plugins once they are registered. Two things differ. The engine keeps running without a view
  /// (the storyboard's stopped with its view controller). And Dart starts here rather than when the view loads, a moment
  /// earlier; its first calls still wait for this method to return, so they find the plugins.
  func obtainFlutterEngine() -> FlutterEngine {
    if let engine = flutterEngine { return engine }
    let engine = FlutterEngine(name: "io.flutter", project: nil, allowHeadlessExecution: true)
    if !engine.run() {
      os_log("The Flutter engine did not start", type: .fault)
    }
    flutterEngine = engine
    connect(registry: engine, messenger: engine.binaryMessenger)
    // Plugins hear about the launch after they are registered. With scenes, Flutter sent these two events from the
    // storyboard's view controller (FlutterViewController.sharedSetupWithProject), with empty options; nothing else sends
    // them for an engine the app makes itself.
    _ = super.application(UIApplication.shared, willFinishLaunchingWithOptions: [:])
    _ = super.application(UIApplication.shared, didFinishLaunchingWithOptions: [:])
    os_log("The Flutter engine was started for the first scene", type: .info)
    return engine
  }

  /// CarPlay's scene is declared here, not in Info.plist, so a build with the car screen off has nothing of it in its manifest.
  /// iOS asks only when CarPlay starts the app on the car's screen, which needs the CarPlay entitlement. Every other scene
  /// gets what Info.plist declares for it (the phone's is "flutter"), as if this method were not here.
  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let role = connectingSceneSession.role
    if role == UISceneSession.Role.carTemplateApplication {
      let configuration = UISceneConfiguration(name: nil, sessionRole: role)
      configuration.sceneClass = CPTemplateApplicationScene.self
      configuration.delegateClass = CarPlaySceneDelegate.self
      return configuration
    }
    let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
    let declared = (manifest?["UISceneConfigurations"] as? [String: Any])?[role.rawValue] as? [[String: Any]]
    return UISceneConfiguration(name: declared?.first?["UISceneConfigurationName"] as? String, sessionRole: role)
  }

  /// A build with the car screen off does not have the method above as far as iOS can tell: it goes on taking every scene
  /// from Info.plist, exactly as before.
  override func responds(to aSelector: Selector!) -> Bool {
    if aSelector == #selector(application(_:configurationForConnecting:options:)) {
      return CarPlayBuild.isOn
    }
    return super.responds(to: aSelector)
  }

  /// The plugins and the app's own channels, once, on the engine obtainFlutterEngine made.
  private func connect(registry: FlutterPluginRegistry, messenger: FlutterBinaryMessenger) {
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: registry)
    let bluetooth = FlutterMethodChannel(name: "co.cache/bluetooth", binaryMessenger: messenger)
    bluetooth.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "status": result(self.bluetoothAccess.status())
      case "request_permissions":
        guard UIApplication.shared.applicationState == .active else {
          result(FlutterError(code: "bluetooth", message: "Open Cache to allow Bluetooth", details: nil)); return
        }
        self.bluetoothAccess.request()
        result(self.bluetoothAccess.status())
      case "start":
        guard let args = call.arguments as? [String: Any], let handle = args["handle"] as? NSNumber,
              handle.int64Value > 0, self.bluetoothAccess.status()["enabled"] as? Bool == true else {
          result(FlutterError(code: "bluetooth", message: "Bluetooth permission and an enabled adapter are required", details: nil)); return
        }
        self.bluetoothAccess.select(handle.int64Value)
        result(self.bluetoothAccess.status())
      case "stop":
        let args = call.arguments as? [String: Any]
        self.bluetoothAccess.stop(expected: (args?["handle"] as? NSNumber)?.int64Value)
        result(self.bluetoothAccess.status())
      default: result(FlutterMethodNotImplemented)
      }
    }
    // Whether this build has the car screen, for Dart (lib/car/car_support.dart), which makes its car bridge only then.
    let build = FlutterMethodChannel(name: "cache/build", binaryMessenger: messenger)
    build.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(["carPlay": CarPlayBuild.isOn])
    }
    // The car's side of the co.cache/car channel (Runner/CarPlay/CarLink.swift), set where the engine is made so that Dart's
    // hello is answered whichever scene started it. Only in a build with the car screen.
    if CarPlayBuild.isOn {
      CarLink.shared.attach(messenger: messenger)
      // Before each spoken prompt Dart asks the car side how iOS wants it given (Runner/CarPlay/CarPrompts.swift).
      CarPrompts.shared.start()
      // Whether the phone's own window is on the phone's screen, so the phone's maps rest while it is not (PhoneWindow in
      // SceneDelegate.swift).
      PhoneWindow.shared.attach(messenger: messenger)
    }
    // A cachelink: link from outside (see LinkBridge in SceneDelegate.swift). Set where the engine is made, so a link reaches
    // Dart whichever scene started the engine.
    let link = FlutterMethodChannel(name: "co.cache/link", binaryMessenger: messenger)
    LinkBridge.shared.channel = link
    link.setMethodCallHandler { call, result in
      if call.method == "take" { result(LinkBridge.shared.take()) } else { result(FlutterMethodNotImplemented) }
    }
    // Notebooks > Connections: a folder the person picks for Obsidian or Logseq, kept as a security-scoped bookmark.
    let folders = FlutterMethodChannel(name: "co.cache/folders", binaryMessenger: messenger)
    let access = folderAccess
    folders.setMethodCallHandler { call, result in access.handle(call, result: result) }
    let permissions = FlutterMethodChannel(
      name: "co.cache/network_access",
      binaryMessenger: messenger
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
    // The install marker (lib/sharing/install_marker.dart): the device-only install id in the Keychain, and the backup-exclusion flag on
    // the sync folder.
    let installMarker = FlutterMethodChannel(name: "co.cache/install_marker", binaryMessenger: messenger)
    installMarker.setMethodCallHandler { call, result in InstallMarker.handle(call, result: result) }
    // The log's device identifier and fresh app memory readings for guards and PDF diagnostics.
    let memory = FlutterMethodChannel(name: "co.cache/memory", binaryMessenger: messenger)
    memory.setMethodCallHandler { call, result in
      if call.method == "read" {
        result(cacheMemoryReading())
        return
      }
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
    // iOS's memory warning goes to the app, which lets the search model go (lib/platform/memory.dart, listenMemoryTrim).
    NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
      memory.invokeMethod("memoryWarning", arguments: nil)
    }
    // Battery level and whether the iPhone is plugged in (lib/platform/battery.dart), for long automatic work (search indexes).
    let battery = FlutterMethodChannel(name: "co.cache/battery", binaryMessenger: messenger)
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
    // The whole-route picture during guidance (RouteSnapshot below, lib/nav/overview/route_overview.dart).
    let snapshots = FlutterMethodChannel(name: "co.cache/route_snapshot", binaryMessenger: messenger)
    let snapshot = routeSnapshot
    snapshots.setMethodCallHandler { call, result in snapshot.handle(call, result: result) }
    // Turn-by-turn guidance keeps the screen on (lib/nav/guidance_wakelock.dart): the idle timer is off while it asks, and back on
    // as soon as it says so or the app goes to the background.
    let screenAwake = FlutterMethodChannel(name: "co.cache/screen_awake", binaryMessenger: messenger)
    screenAwake.setMethodCallHandler { call, result in
      guard call.method == "keepScreenOn" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      UIApplication.shared.isIdleTimerDisabled = on
      result(nil)
    }
    NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      UIApplication.shared.isIdleTimerDisabled = false
    }
    // The CPR metronome's tick and buzz (lib/firstaid/cpr_feedback.dart). The tick is a short WAV the app makes; it plays in a playback
    // audio session, which the silent switch does not mute. The buzz is a heavy tap of the haptic engine.
    let cpr = FlutterMethodChannel(name: "co.cache/cpr", binaryMessenger: messenger)
    cpr.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "begin":
        guard let wav = (call.arguments as? [String: Any])?["wav"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "bad_sound", message: "No sound given", details: nil))
          return
        }
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playback, mode: .default, options: [])
          try session.setActive(true)
          let player = try AVAudioPlayer(data: wav.data)
          player.prepareToPlay()
          self?.cprTick = player
          result(nil)
        } catch {
          result(FlutterError(code: "no_audio", message: "\(error)", details: nil))
        }
      case "tick":
        self?.cprTick?.currentTime = 0
        self?.cprTick?.play()
        result(nil)
      case "buzz":
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        result(nil)
      case "end":
        self?.cprTick?.stop()
        self?.cprTick = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // The thermal state changed: the app reads it again at once (background index work eases off or pauses).
    NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
      battery.invokeMethod("changed", arguments: nil)
    }
  }
}

/// App headroom is the current app limit minus its footprint, not system-wide free RAM.
private func cacheMemoryReading() -> [String: Any] {
  let available = os_proc_available_memory()
  var answer: [String: Any] = [
    "avail": Int64(available), "total": Int64(ProcessInfo.processInfo.physicalMemory),
    "threshold": 0, "low": available == 0, "appScoped": true
  ]
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let status = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  if status == KERN_SUCCESS {
    answer["footprint"] = Int64(info.phys_footprint)
    answer["resident"] = Int64(info.resident_size)
    answer["compressed"] = Int64(info.compressed)
  }
  return answer
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

/// The whole-route picture during guidance (lib/nav/overview/route_overview.dart): MapLibre's offscreen map snapshotter renders the
/// app's map style, with the route written into it, at a fixed camera, once per route, size and theme. It reads the same tile
/// server on 127.0.0.1 as the live map, which it never touches. The MapLibre framework is the one the maplibre_gl plugin brings in,
/// at the version the Podfile pins (tools/check_maplibre_pin.py keeps the two the same).
///
/// "render" takes {style (JSON), lat, lon, zoom, width, height (points), pixelRatio} and answers {rgba (the pixels, row by row),
/// width, height (pixels), ms (the render alone)}. A newer request cancels one still running, which answers "cancelled".
final class RouteSnapshot {
  private var active: MLNMapSnapshotter?
  private var activeResult: FlutterResult?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "render" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let a = call.arguments as? [String: Any], let style = a["style"] as? String,
          let lat = (a["lat"] as? NSNumber)?.doubleValue, let lon = (a["lon"] as? NSNumber)?.doubleValue,
          let zoom = (a["zoom"] as? NSNumber)?.doubleValue, let width = (a["width"] as? NSNumber)?.doubleValue,
          let height = (a["height"] as? NSNumber)?.doubleValue, width > 0, height > 0 else {
      result(FlutterError(code: "bad_args", message: "style, lat, lon, zoom, width and height are needed", details: nil))
      return
    }
    let ratio = (a["pixelRatio"] as? NSNumber)?.doubleValue ?? Double(UIScreen.main.scale)
    cancel()
    // The snapshotter reads a style from an address: the JSON goes to a file in the temporary folder.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("route-overview-style-\(UUID().uuidString).json")
    do {
      try style.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      result(FlutterError(code: "snapshot", message: error.localizedDescription, details: nil))
      return
    }
    let camera = MLNMapCamera()
    camera.centerCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    camera.heading = 0
    camera.pitch = 0
    let options = MLNMapSnapshotOptions(styleURL: url, camera: camera, size: CGSize(width: width, height: height))
    options.zoomLevel = zoom
    options.scale = CGFloat(ratio)
    options.showsLogo = false
    let snapshotter = MLNMapSnapshotter(options: options)
    active = snapshotter
    activeResult = result
    let started = DispatchTime.now().uptimeNanoseconds
    snapshotter.start { [weak self] snapshot, error in
      try? FileManager.default.removeItem(at: url)
      guard let self = self, self.active === snapshotter else { return }
      self.active = nil
      self.activeResult = nil
      let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
      if let error = error {
        result(FlutterError(code: "snapshot", message: error.localizedDescription, details: nil))
        return
      }
      guard let cg = snapshot?.image.cgImage else {
        result(FlutterError(code: "snapshot", message: "No picture", details: nil))
        return
      }
      let w = cg.width, h = cg.height
      var data = Data(count: w * h * 4)
      let drawn: Bool = data.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
      }
      guard drawn else {
        result(FlutterError(code: "snapshot", message: "Could not read the picture", details: nil))
        return
      }
      let answer: [String: Any] = ["rgba": FlutterStandardTypedData(bytes: data), "width": w, "height": h, "ms": ms]
      result(answer)
    }
  }

  private func cancel() {
    active?.cancel()
    active = nil
    activeResult?(FlutterError(code: "cancelled", message: "a newer picture was asked for", details: nil))
    activeResult = nil
  }
}

/// The device-only half of the install marker (lib/sharing/install_marker.dart), and the sync folder's backup flag.
/// - "read" / "write": one Keychain item (a generic password) with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, which neither
///   an iCloud or computer backup restored onto another iPhone nor a phone-to-phone transfer carries. After first unlock, so a
///   background sync round (which can run with the phone locked) can read it.
/// - "excludeFromBackup": creates the folder if needed and sets NSURLIsExcludedFromBackupKey on it. The app calls it at every start.
/// - "excludeIfPresent": sets the same flag on a file or folder that exists (true), or does nothing when it is missing (false).
/// - "readIdentity" / "writeIdentity": the second copy of the device's sync key with its install id (lib/sharing/identity_keep.dart),
///   one more Keychain item of the same kind (same service and accessibility, account "identity-keep"). Not found is nil; any other
///   Keychain failure is an error, so the app never takes it for "every copy is gone".
enum InstallMarker {
  private static let service = "co.cache.install-marker"
  private static let account = "install-id"
  private static let identityAccount = "identity-keep"

  private static func query(_ acct: String = account) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: acct,
    ]
  }

  /// Replaces the item for [acct] with [data], readable only on this device, after first unlock.
  private static func keep(_ acct: String, _ data: Data) -> OSStatus {
    SecItemDelete(query(acct) as CFDictionary)
    var add = query(acct)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil)
  }

  static func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "readIdentity":
      var q = query(identityAccount)
      q[kSecReturnData as String] = true
      q[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(q as CFDictionary, &item)
      if status == errSecItemNotFound {
        result(nil)
      } else if status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) {
        result(text)
      } else {
        result(FlutterError(code: "identity_read", message: "Keychain read failed (\(status))", details: nil))
      }
    case "writeIdentity":
      guard let args = call.arguments as? [String: Any], let text = args["value"] as? String, !text.isEmpty,
        let data = text.data(using: .utf8)
      else {
        result(FlutterError(code: "bad_value", message: "no value given", details: nil))
        return
      }
      let status = keep(identityAccount, data)
      if status == errSecSuccess {
        result(nil)
      } else {
        result(FlutterError(code: "identity_write", message: "Keychain write failed (\(status))", details: nil))
      }
    case "read":
      var q = query()
      q[kSecReturnData as String] = true
      q[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(q as CFDictionary, &item)
      if status == errSecItemNotFound {
        result(nil)
      } else if status == errSecSuccess, let data = item as? Data, let id = String(data: data, encoding: .utf8) {
        result(id)
      } else {
        result(FlutterError(code: "keychain_read", message: "Keychain read failed (\(status))", details: nil))
      }
    case "write":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? String, !id.isEmpty,
        let data = id.data(using: .utf8)
      else {
        result(FlutterError(code: "bad_id", message: "no id given", details: nil))
        return
      }
      SecItemDelete(query() as CFDictionary)
      var add = query()
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(add as CFDictionary, nil)
      if status == errSecSuccess {
        result(nil)
      } else {
        result(FlutterError(code: "keychain_write", message: "Keychain write failed (\(status))", details: nil))
      }
    case "excludeFromBackup":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "bad_path", message: "no path given", details: nil))
        return
      }
      do {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "exclude_failed", message: error.localizedDescription, details: nil))
      }
    case "excludeIfPresent":
      // The backup sweep (lib/platform/backup_scope.dart): flags a file or folder that is already there, creates nothing.
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "bad_path", message: "no path given", details: nil))
        return
      }
      guard FileManager.default.fileExists(atPath: path) else {
        result(false)
        return
      }
      do {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(true)
      } catch {
        result(FlutterError(code: "exclude_failed", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
