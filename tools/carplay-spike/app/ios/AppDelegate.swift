// CarPlay spike: a scratch app, not the product. One Flutter engine held by the app delegate and started by whichever scene
// connects first (the phone window or the CarPlay scene); a CarPlay map template over a MapLibre map; one method channel on
// which Dart says hello and the CarPlay scene shows what it said. Everything is in this one file because it replaces the
// AppDelegate.swift that `flutter create` puts in the Runner target.
import CarPlay
import Flutter
import MapKit
import MapLibre
import UIKit

/// One line per event, to the system log and to Documents/spike-log.txt, which the workflow reads from the Mac side.
enum SpikeLog {
  static let start = Date()
  static let directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

  static func write(_ text: String) {
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let line = "SPIKE +\(ms)ms \(text)"
    NSLog("%@", line)
    let url = directory.appendingPathComponent("spike-log.txt")
    guard let data = (line + "\n").data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      _ = handle.seekToEndOfFile()
      handle.write(data)
      handle.closeFile()
    } else {
      try? data.write(to: url)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var engine: FlutterEngine?
  private var channel: FlutterMethodChannel?
  private(set) var engineStartedBy: String?
  private(set) var dartValue: String?
  private(set) var dartSum: Int?
  var onDartHello: (() -> Void)?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let pid = ProcessInfo.processInfo.processIdentifier
    let wall = Int(Date().timeIntervalSince1970)
    SpikeLog.write("launch pid=\(pid) wall=\(wall) appState=\(application.applicationState.rawValue)")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The scene configuration by name from the Info.plist manifest when the role is declared there; made in code when it is not
  /// (the workflow removes the CarPlay entry from a copy of the app to try that).
  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let role = connectingSceneSession.role
    let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
    let configurations = manifest?["UISceneConfigurations"] as? [String: Any]
    let declared = configurations?[role.rawValue] as? [[String: Any]]
    if let name = declared?.first?["UISceneConfigurationName"] as? String {
      SpikeLog.write("scene configuration for \(role.rawValue): '\(name)' from the Info.plist manifest")
      return UISceneConfiguration(name: name, sessionRole: role)
    }
    SpikeLog.write("scene configuration for \(role.rawValue): made in code, the manifest does not declare it")
    let configuration = UISceneConfiguration(name: nil, sessionRole: role)
    if role == UISceneSession.Role.carTemplateApplication {
      configuration.sceneClass = CPTemplateApplicationScene.self
      configuration.delegateClass = CarPlaySceneDelegate.self
    } else {
      configuration.sceneClass = UIWindowScene.self
      configuration.delegateClass = PhoneSceneDelegate.self
    }
    return configuration
  }

  /// The app's one engine: created and run by the first caller, joined by the next.
  func sharedEngine(startedBy who: String) -> FlutterEngine {
    if let engine = engine {
      SpikeLog.write("engine joined by \(who); it was started by \(engineStartedBy ?? "?")")
      return engine
    }
    let began = Date()
    let created = FlutterEngine(name: "spike", project: nil, allowHeadlessExecution: true)
    let ran = created.run()
    GeneratedPluginRegistrant.register(with: created)
    let carChannel = FlutterMethodChannel(name: "spike/car", binaryMessenger: created.binaryMessenger)
    carChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    engine = created
    channel = carChannel
    engineStartedBy = who
    let ms = Int(Date().timeIntervalSince(began) * 1000)
    SpikeLog.write("engine created by \(who): run=\(ran), plugins registered, \(ms) ms")
    return created
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hello":
      let arguments = call.arguments as? [String: Any]
      dartValue = arguments?["value"] as? String
      dartSum = (arguments?["sum"] as? NSNumber)?.intValue
      let sumText = dartSum.map { String($0) } ?? "nil"
      let state = UIApplication.shared.applicationState.rawValue
      SpikeLog.write("dart hello value='\(dartValue ?? "nil")' sum=\(sumText) appState=\(state) scenes=\(sceneSummary())")
      result(["startedBy": engineStartedBy ?? "?"])
      onDartHello?()
    case "log":
      let text = call.arguments as? String ?? ""
      SpikeLog.write("dart log: \(text) scenes=\(sceneSummary())")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Swift asks, Dart answers: the other direction of the channel.
  func askDart(_ why: String) {
    guard let channel = channel else { return }
    let asked = Date()
    channel.invokeMethod("ask", arguments: ["why": why]) { answer in
      let ms = Int(Date().timeIntervalSince(asked) * 1000)
      SpikeLog.write("dart answered ask('\(why)') after \(ms) ms: \(String(describing: answer))")
    }
  }

  /// Every connected scene as role:state (state 0 is foreground active, 1 foreground inactive, 2 background).
  func sceneSummary() -> String {
    let parts = UIApplication.shared.connectedScenes.map { scene in
      "\(scene.session.role.rawValue):\(scene.activationState.rawValue)"
    }
    return parts.sorted().joined(separator: ",")
  }
}

/// The phone window: a FlutterSceneDelegate subclass that builds its window around the shared engine instead of a storyboard.
class PhoneSceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    SpikeLog.write("phone scene willConnect")
    if let windowScene = scene as? UIWindowScene, let app = UIApplication.shared.delegate as? AppDelegate {
      let engine = app.sharedEngine(startedBy: "phone")
      let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
      let phoneWindow = UIWindow(windowScene: windowScene)
      phoneWindow.rootViewController = controller
      window = phoneWindow
      phoneWindow.makeKeyAndVisible()
      app.askDart("phone connected")
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    SpikeLog.write("phone scene connected, FlutterSceneDelegate's own willConnect has run")
  }
}

/// The car side: a map template with bar buttons and map buttons over a base view that holds a MapLibre map.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate {
  private var interfaceController: CPInterfaceController?
  private var mapTemplate: CPMapTemplate?
  private var mapController: CarMapViewController?
  private var navigationSession: CPNavigationSession?
  private var modeTimer: Timer?
  private var appliedMode: String?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController,
    to window: CPWindow
  ) {
    guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
    let screen = window.screen
    var facts: [String] = []
    facts.append("window=\(Int(window.bounds.width))x\(Int(window.bounds.height))")
    facts.append("screen=\(Int(screen.bounds.width))x\(Int(screen.bounds.height))")
    facts.append("scale=\(screen.scale)")
    facts.append("native=\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))")
    facts.append("contentStyle=\(templateApplicationScene.contentStyle.rawValue)")
    facts.append("appState=\(UIApplication.shared.applicationState.rawValue)")
    facts.append("scenes=\(app.sceneSummary())")
    SpikeLog.write("carplay didConnect " + facts.joined(separator: " "))
    self.interfaceController = interfaceController

    // The engine first: its plugins are registered before the first map view exists.
    app.onDartHello = { [weak self] in self?.refreshBarButtons() }
    _ = app.sharedEngine(startedBy: "car")
    app.askDart("car connected")

    let controller = CarMapViewController()
    controller.carWindow = window
    window.rootViewController = controller
    mapController = controller

    let template = CPMapTemplate()
    template.mapDelegate = self
    template.automaticallyHidesNavigationBar = false
    template.mapButtons = [
      mapButton("plus", "zoom in"), mapButton("minus", "zoom out"),
      mapButton("arrow.up.and.down.and.arrow.left.and.right", "pan"), mapButton("location.fill", "recenter"),
    ]
    mapTemplate = template
    refreshBarButtons()
    interfaceController.setRootTemplate(template, animated: false) { done, error in
      SpikeLog.write("map template set as root: done=\(done) error=\(String(describing: error))")
    }

    modeTimer?.invalidate()
    modeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.pollMode()
    }
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController,
    from window: CPWindow
  ) {
    SpikeLog.write("carplay didDisconnect")
    modeTimer?.invalidate()
    modeTimer = nil
    navigationSession = nil
    mapTemplate = nil
    mapController = nil
    self.interfaceController = nil
    appliedMode = nil
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    SpikeLog.write("carplay scene active, appState=\(UIApplication.shared.applicationState.rawValue)")
  }

  func sceneWillResignActive(_ scene: UIScene) {
    SpikeLog.write("carplay scene will resign active")
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    SpikeLog.write("carplay scene in background")
  }

  func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
    SpikeLog.write("carplay content style changed to \(contentStyle.rawValue)")
  }

  private func mapButton(_ symbol: String, _ name: String) -> CPMapButton {
    let button = CPMapButton { _ in
      SpikeLog.write("map button pressed: \(name)")
    }
    button.image = UIImage(systemName: symbol)
    return button
  }

  /// The bar buttons carry what Dart sent over the channel: the proof, in the picture, that Dart ran.
  private func refreshBarButtons() {
    guard let template = mapTemplate, let app = UIApplication.shared.delegate as? AppDelegate else { return }
    let value = app.dartValue ?? "no Dart"
    let sum = app.dartSum.map { "1..9=\($0)" } ?? "wait"
    let sumButton = CPBarButton(title: sum) { _ in
      SpikeLog.write("bar button pressed: sum")
    }
    let valueButton = CPBarButton(title: value) { _ in
      SpikeLog.write("bar button pressed: value")
    }
    template.leadingNavigationBarButtons = [sumButton]
    template.trailingNavigationBarButtons = [valueButton]
    SpikeLog.write("bar buttons set: '\(sum)' and '\(value)'")
  }

  /// The workflow writes words into Documents/spike-mode.txt to change what is shown without touching the screen:
  /// "overlay" (a second small map, two lines of text and the safe-area outlines in the base view), "guide" (a navigation
  /// session with a maneuver and estimates, so Apple's panels show), "demo" (MapLibre's public demo style).
  private func pollMode() {
    let url = SpikeLog.directory.appendingPathComponent("spike-mode.txt")
    let read = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let mode = read.trimmingCharacters(in: .whitespacesAndNewlines)
    if mode == appliedMode { return }
    appliedMode = mode
    let words = mode.split(separator: " ").map { String($0) }
    mapController?.setDemoStyle(words.contains("demo"))
    mapController?.setOverlay(words.contains("overlay"))
    if words.contains("guide") {
      startGuidance()
    } else {
      stopGuidance()
    }
    SpikeLog.write("mode applied: '\(mode)'")
  }

  private func startGuidance() {
    guard navigationSession == nil, let template = mapTemplate else { return }
    let origin = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)))
    let destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 0.02, longitude: 0.03)))
    destination.name = "Destination"
    let choice = CPRouteChoice(
      summaryVariants: ["Main road"],
      additionalInformationVariants: ["Fastest"],
      selectionSummaryVariants: ["Main road"]
    )
    let trip = CPTrip(origin: origin, destination: destination, routeChoices: [choice])
    let session = template.startNavigationSession(for: trip)
    let first = CPManeuver()
    first.instructionVariants = ["Turn right onto Second Street", "Turn right"]
    first.symbolImage = UIImage(systemName: "arrow.turn.up.right")
    first.initialTravelEstimates = CPTravelEstimates(
      distanceRemaining: Measurement(value: 400, unit: UnitLength.meters),
      timeRemaining: 45
    )
    let second = CPManeuver()
    second.instructionVariants = ["Keep left"]
    second.symbolImage = UIImage(systemName: "arrow.up.left")
    second.initialTravelEstimates = CPTravelEstimates(
      distanceRemaining: Measurement(value: 1200, unit: UnitLength.meters),
      timeRemaining: 120
    )
    session.upcomingManeuvers = [first, second]
    let whole = CPTravelEstimates(
      distanceRemaining: Measurement(value: 12.4, unit: UnitLength.kilometers),
      timeRemaining: 16 * 60
    )
    template.updateEstimates(whole, for: trip)
    navigationSession = session
    SpikeLog.write("guidance started: two maneuvers and trip estimates given to the template")
  }

  private func stopGuidance() {
    guard let session = navigationSession else { return }
    session.finishTrip()
    navigationSession = nil
    SpikeLog.write("guidance stopped")
  }
}

/// The base view: one MapLibre map view filling the window CarPlay hands over, with a plain background style written here
/// (no tiles, no servers), one line and two markers.
final class CarMapViewController: UIViewController, MLNMapViewDelegate {
  weak var carWindow: CPWindow?
  private var mapView: MLNMapView?
  private var miniMap: MLNMapView?
  private var overlayViews: [UIView] = []
  private var safeOutline: UIView?
  private var buttonOutline: UIView?
  private var demoStyle = false
  private var lastLayout = ""
  private var renders = 0
  private var loggedFull = false

  static let center = CLLocationCoordinate2D(latitude: 0.010, longitude: 0.015)
  static let routeEnd = CLLocationCoordinate2D(latitude: 0.020, longitude: 0.030)
  static let route: [CLLocationCoordinate2D] = [
    CLLocationCoordinate2D(latitude: 0.000, longitude: 0.000),
    CLLocationCoordinate2D(latitude: 0.004, longitude: 0.008),
    CLLocationCoordinate2D(latitude: 0.010, longitude: 0.015),
    CLLocationCoordinate2D(latitude: 0.012, longitude: 0.022),
    CLLocationCoordinate2D(latitude: 0.020, longitude: 0.030),
  ]

  /// A style with nothing but a background colour, written to the temporary folder (the map view reads a style from an address).
  static func styleURL(named name: String, background: String) -> URL {
    let json = "{\"version\":8,\"name\":\"\(name)\",\"sources\":{},\"layers\":[{\"id\":\"background\",\"type\":\"background\",\"paint\":{\"background-color\":\"\(background)\"}}]}"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
    try? json.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black
    let map = MLNMapView(frame: view.bounds, styleURL: Self.styleURL(named: "spike-plain", background: "#e6e2d3"))
    map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    map.delegate = self
    map.setCenter(Self.center, zoomLevel: 12.5, animated: false)
    view.addSubview(map)
    let pin = MLNPointAnnotation()
    pin.coordinate = Self.routeEnd
    pin.title = "End"
    map.addAnnotation(pin)
    mapView = map
    SpikeLog.write("map view created in the CarPlay window, bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutOutlines()
    logLayout()
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    layoutOutlines()
    logLayout()
  }

  private func logLayout() {
    let insets = view.safeAreaInsets
    var parts: [String] = []
    parts.append("bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
    parts.append("safeInsets top=\(Int(insets.top)) left=\(Int(insets.left)) bottom=\(Int(insets.bottom)) right=\(Int(insets.right))")
    if let window = carWindow {
      let frame = window.mapButtonSafeAreaLayoutGuide.layoutFrame
      parts.append("mapButtonGuide x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))")
    }
    if let map = mapView {
      let inset = map.contentInset
      parts.append("mapContentInset top=\(Int(inset.top)) left=\(Int(inset.left)) bottom=\(Int(inset.bottom)) right=\(Int(inset.right))")
    }
    let text = parts.joined(separator: " ")
    if text != lastLayout {
      lastLayout = text
      SpikeLog.write("layout " + text)
    }
  }

  private func layoutOutlines() {
    safeOutline?.frame = view.bounds.inset(by: view.safeAreaInsets)
    if let window = carWindow, let outline = buttonOutline {
      outline.frame = view.convert(window.mapButtonSafeAreaLayoutGuide.layoutFrame, from: window)
    }
  }

  func setDemoStyle(_ on: Bool) {
    guard on != demoStyle, let map = mapView else { return }
    demoStyle = on
    loggedFull = false
    if on {
      map.styleURL = URL(string: "https://demotiles.maplibre.org/style.json")
      map.setCenter(CLLocationCoordinate2D(latitude: 20, longitude: 10), zoomLevel: 1.6, animated: false)
    } else {
      map.styleURL = Self.styleURL(named: "spike-plain", background: "#e6e2d3")
      map.setCenter(Self.center, zoomLevel: 12.5, animated: false)
    }
    SpikeLog.write("style switched to \(on ? "MapLibre's demo tiles" : "the plain style")")
  }

  /// For the optional look at how Apple's panels sit around app-drawn pieces: a second, small map view at the bottom right of
  /// the safe area, two lines of text at the bottom left, a yellow outline of the safe area and a blue one of the area clear of
  /// the map buttons.
  func setOverlay(_ on: Bool) {
    for item in overlayViews {
      item.removeFromSuperview()
    }
    overlayViews = []
    miniMap = nil
    safeOutline = nil
    buttonOutline = nil
    guard on else { return }
    let guide = view.safeAreaLayoutGuide

    let mini = MLNMapView(
      frame: CGRect(x: 0, y: 0, width: 96, height: 72),
      styleURL: Self.styleURL(named: "spike-mini", background: "#22323e")
    )
    mini.translatesAutoresizingMaskIntoConstraints = false
    mini.delegate = self
    mini.isUserInteractionEnabled = false
    mini.logoView.isHidden = true
    mini.attributionButton.isHidden = true
    mini.layer.borderColor = UIColor.white.cgColor
    mini.layer.borderWidth = 2
    mini.layer.cornerRadius = 8
    mini.clipsToBounds = true
    mini.setCenter(Self.center, zoomLevel: 10.4, animated: false)
    view.addSubview(mini)

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 2
    label.text = " Climb ahead 3% \n 330 ft in 1.2 mi "
    label.font = UIFont.boldSystemFont(ofSize: 13)
    label.textColor = UIColor.white
    label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
    view.addSubview(label)

    NSLayoutConstraint.activate([
      mini.widthAnchor.constraint(equalToConstant: 96),
      mini.heightAnchor.constraint(equalToConstant: 72),
      mini.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -6),
      mini.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -6),
      label.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 6),
      label.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -6),
    ])

    let safe = UIView()
    safe.isUserInteractionEnabled = false
    safe.backgroundColor = UIColor.clear
    safe.layer.borderColor = UIColor.systemYellow.cgColor
    safe.layer.borderWidth = 2
    view.addSubview(safe)
    let buttons = UIView()
    buttons.isUserInteractionEnabled = false
    buttons.backgroundColor = UIColor.clear
    buttons.layer.borderColor = UIColor.systemBlue.cgColor
    buttons.layer.borderWidth = 1
    view.addSubview(buttons)

    miniMap = mini
    safeOutline = safe
    buttonOutline = buttons
    overlayViews = [mini, label, safe, buttons]
    layoutOutlines()
    SpikeLog.write("overlay shown: second map view 96x72, two lines of text, safe-area outlines")
  }

  private func addRoute(to style: MLNStyle, thin: Bool) {
    var coordinates = Self.route
    let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
    let lineSource = MLNShapeSource(identifier: "spike-route", shape: line, options: nil)
    style.addSource(lineSource)
    if !thin {
      let casing = MLNLineStyleLayer(identifier: "spike-route-casing", source: lineSource)
      casing.lineColor = NSExpression(forConstantValue: UIColor.white)
      casing.lineWidth = NSExpression(forConstantValue: 9)
      casing.lineCap = NSExpression(forConstantValue: "round")
      casing.lineJoin = NSExpression(forConstantValue: "round")
      style.addLayer(casing)
    }
    let routeLine = MLNLineStyleLayer(identifier: "spike-route-line", source: lineSource)
    routeLine.lineColor = NSExpression(forConstantValue: UIColor(red: 0.10, green: 0.42, blue: 0.92, alpha: 1))
    routeLine.lineWidth = NSExpression(forConstantValue: thin ? 3 : 5)
    routeLine.lineCap = NSExpression(forConstantValue: "round")
    routeLine.lineJoin = NSExpression(forConstantValue: "round")
    style.addLayer(routeLine)

    let point = MLNPointFeature()
    point.coordinate = Self.center
    let pointSource = MLNShapeSource(identifier: "spike-position", shape: point, options: nil)
    style.addSource(pointSource)
    let dot = MLNCircleStyleLayer(identifier: "spike-position-dot", source: pointSource)
    dot.circleRadius = NSExpression(forConstantValue: thin ? 4 : 9)
    dot.circleColor = NSExpression(forConstantValue: UIColor.red)
    dot.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
    dot.circleStrokeWidth = NSExpression(forConstantValue: thin ? 1 : 3)
    style.addLayer(dot)
  }

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    let which = mapView === miniMap ? "second map" : "car map"
    addRoute(to: style, thin: mapView === miniMap)
    SpikeLog.write("style loaded on the \(which): '\(style.name ?? "unnamed")', \(style.layers.count) layers after adding the line and the dot")
  }

  func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
    guard mapView === self.mapView else { return }
    renders += 1
    if fullyRendered && !loggedFull {
      loggedFull = true
      SpikeLog.write("car map finished rendering map, fully rendered (render callback \(renders))")
    } else if renders <= 2 {
      SpikeLog.write("car map finished rendering map, fullyRendered=\(fullyRendered) (render callback \(renders))")
    }
  }

  func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
    SpikeLog.write("map failed to load: \(error.localizedDescription)")
  }
}
