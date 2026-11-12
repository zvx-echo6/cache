import CoreLocation
import MapLibre
import os
import UIKit

/// Cache's map on the car's screen: the base view of the map template.
///
/// CarPlay gives the car scene a window. This is its root view controller, and it holds one ordinary MapLibre map view that
/// fills the view. The map is the car's own: the phone's Flutter map is not touched or moved, and both read the same offline
/// tiles from the core's tile server on 127.0.0.1 with the same style, which Dart builds (the light or dark map palette, as
/// the car asks). It is the twin of the Android car's CarMapRenderer.kt, without the virtual display Android needs.
///
/// Only map content is drawn here (Apple's rule for the base view): the base map, the route, the destination and the position.
/// The buttons, the turn, the distances and the arrival time are the templates'. CarPlay sends the base view no touches: the
/// map moves by the template's buttons and its panning calls, which the car scene passes on.
final class CarMapViewController: UIViewController, MLNMapViewDelegate, CarLinkListener {
  private static let log = Logger(subsystem: "co.cache.car", category: "map")
  private static let routeSource = "car-route-src"
  private static let destinationSource = "car-dest-src"
  private static let positionSource = "car-pos-src"
  private static let badgeSource = "car-badge-src"
  private static let badgeImage = "car-grade-badge-img"
  /// The colours of what the car adds on top of the style, until Dart sends the palette's with the style.
  private static let defaultColors: [String: String] = [
    "route": "#2f7df6", "routeCasing": "#0b3a8a", "routeOffroad": "#d9822b", "routeAlternate": "#8aa4c8",
    "position": "#2f7df6", "positionRing": "#ffffff", "pin": "#d93a3a",
  ]

  private var mapView: MLNMapView?
  private var styleAttempt = 0
  private var colors = CarMapViewController.defaultColors
  private var dark: Bool
  /// "dark" or "light" once the app's own style is the one set on the map; nil while the plain colour stands in.
  private var shownStyle: String?
  private var drawnSaid = false
  private var lastCameraPhase: String?
  private var lastArea = ""
  private var reload: DispatchWorkItem?

  // The vehicle's marker (CarMarkerMotion has its rules). An arrow while a heading is known, a dot while none is. The arrow is
  // there twice, as on Android: one tied to the screen, always pointing up, shown while the camera is turned to the heading
  // (guidance), and one tied to the map and turned to the compass heading, shown otherwise. Which one shows is their opacity,
  // which changes in the same frame as the camera; a symbol's turn reaches the screen later.
  private static let arrowImage = "car-pos-arrow-img"
  private var arrowLayer: MLNSymbolStyleLayer?
  private var compassLayer: MLNSymbolStyleLayer?
  private var dotLayer: MLNCircleStyleLayer?
  private var arrowShown: Bool?
  private var upShown: Bool?
  private var shownRotation = Double.nan
  /// The bearing the camera was last given (0: north up). Nothing else turns the map.
  private var cameraBearing = 0.0
  /// The last heading the phone gave: the arrow keeps it while a position comes without one, as long as the trip is guiding.
  private var lastHeading: Double?
  /// A position was drawn; drawnLat, drawnLon and drawnHeading (not a number: none known) are where the marker is right now.
  private var hasMarker = false
  private var drawnLat = 0.0
  private var drawnLon = 0.0
  private var drawnHeading = Double.nan
  /// The glide in hand: from where the marker was when the newest position came, to that position.
  private var fromLat = 0.0
  private var fromLon = 0.0
  private var fromHeading = Double.nan
  private var toLat = 0.0
  private var toLon = 0.0
  private var toHeading = Double.nan
  /// When the newest position came, and the trip's phase it came in.
  private var lastFixAt: Int64 = 0
  private var markerPhase: String?
  private var glide: CADisplayLink?
  private var glideBegan: Int64 = 0
  private var glideLasts: Int64 = 0
  private var lastFrameAt: Int64 = 0
  /// What the grade marker's picture was last made for (the grade, day or night, the colours).
  private var badgeKey: String?

  /// The whole route is in view instead of the position (the bar's Overview button while guiding).
  private(set) var overview = false

  /// The camera keeps the position in view (the Recenter button turns it back on after the map was moved).
  private(set) var following = true

  /// Called when `following` changes, so the car scene can show or hide Recenter.
  var onFollowingChanged: (() -> Void)?

  /// The room CarPlay reports (takeFreeArea), and what it took from the leading edge when last seen with a panel up and
  /// with none. Called when any of it changes.
  private(set) var room: CarRoom?
  private(set) var panelLeft: Double?
  private(set) var plainLeft: Double?
  var onRoomChanged: (() -> Void)?

  init(dark: Bool) {
    self.dark = dark
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Self.uiColor(Self.restColor(dark: dark))
  }

  // ---- the map view ------------------------------------------------------------------------------------------------------

  /// Makes the map. The car scene calls it once the engine is up: the map plugin sets MapLibre's shared network configuration
  /// when the engine registers its plugins, and that has to come before the first map view exists.
  func startMap() {
    guard mapView == nil else { return }
    // A style of one plain colour until Dart answers with the app's: the map view's own default style is on the network.
    let map = MLNMapView(frame: view.bounds, styleJSON: Self.restStyle(dark: dark))
    map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    map.delegate = self
    map.isScrollEnabled = false
    map.isZoomEnabled = false
    map.isRotateEnabled = false
    map.isPitchEnabled = false
    map.logoView.isHidden = true
    map.attributionButton.isHidden = true
    map.compassView.compassVisibility = .hidden
    map.minimumZoomLevel = 2
    map.maximumZoomLevel = 19
    // At most 30 frames a second: the phone may be doing its own drawing, and a car's screen can be large.
    map.preferredFramesPerSecond = .lowPower
    // The free area is told to the map here (takeFreeArea), not left for the map to find in its own, later, layout.
    map.automaticallyAdjustsContentInset = false
    map.contentInset = view.safeAreaInsets
    let t = CarLink.shared.trip
    if let lat = t.lat ?? t.destinationLat, let lon = t.lon ?? t.destinationLon {
      map.setCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon), zoomLevel: 14, animated: false)
    } else {
      map.setCenter(CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35), zoomLevel: 3, animated: false)
    }
    view.addSubview(map)
    mapView = map
    CarLink.shared.addListener(self)
    NotificationCenter.default.addObserver(
      self, selector: #selector(heatChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)
    Self.log.info("car map: map view made, \(width) x \(height) points")
    sayArea()
    loadStyle()
  }

  /// The car has gone: the map and what it holds are let go.
  func release() {
    styleAttempt += 1
    reload?.cancel()
    reload = nil
    glide?.invalidate()
    glide = nil
    dropStyleParts()
    hasMarker = false
    CarLink.shared.removeListener(self)
    NotificationCenter.default.removeObserver(self)
    onFollowingChanged = nil
    onRoomChanged = nil
    mapView?.delegate = nil
    mapView?.removeFromSuperview()
    mapView = nil
    shownStyle = nil
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    takeFreeArea()
  }

  /// CarPlay's bars, buttons and panels leave part of the view free, and that part changes as they come and go. The map is
  /// given it as its content inset: its middle, and what the camera fits, then stay inside the free area. The camera is put
  /// again for the new area, at the zoom it had.
  private func takeFreeArea() {
    guard let map = mapView else { return }
    let free = view.safeAreaInsets
    if map.contentInset == free { return }
    map.contentInset = free
    sayArea()
    // What CarPlay takes from the leading edge, with one of its panels up and without: the panel's width follows from the two.
    if CarLink.shared.trip.phase == "browsing" {
      plainLeft = Double(free.left)
    } else {
      panelLeft = Double(free.left)
    }
    room = CarRoom(
      width: Double(view.bounds.width), height: Double(view.bounds.height), top: Double(free.top), left: Double(free.left),
      bottom: Double(free.bottom), right: Double(free.right))
    onRoomChanged?()
    follow(force: true, keepZoom: true)
  }

  private func sayArea() {
    guard let map = mapView else { return }
    let size = "\(Int(view.bounds.width)) x \(Int(view.bounds.height))"
    let free = Self.edges(view.safeAreaInsets)
    let kept = Self.edges(map.contentInset)
    let text = "the bars and buttons take \(free) of \(size) points; the map keeps clear of \(kept)"
    if text == lastArea { return }
    lastArea = text
    Self.log.info("car map: \(text, privacy: .public)")
  }

  private static func edges(_ insets: UIEdgeInsets) -> String {
    let top = Int(insets.top)
    let left = Int(insets.left)
    let bottom = Int(insets.bottom)
    let right = Int(insets.right)
    return "top \(top) left \(left) bottom \(bottom) right \(right)"
  }

  // ---- the map's buttons and panning -----------------------------------------------------------------------------------

  func zoomIn() {
    zoom(by: 1)
  }

  func zoomOut() {
    zoom(by: -1)
  }

  private func zoom(by levels: Double) {
    guard let map = mapView else { return }
    let level = min(max(map.zoomLevel + levels, map.minimumZoomLevel), map.maximumZoomLevel)
    map.setZoomLevel(level, animated: true)
  }

  func recenter() {
    setFollowing(true)
    lastCameraPhase = nil
    follow(force: true)
  }

  /// The whole route in view, north up and flat (the Overview button), and back to following the position when it goes.
  func setOverview(_ on: Bool) {
    if overview == on { return }
    overview = on
    Self.log.info("car map: route overview \(on ? "on" : "off", privacy: .public)")
    let was = following
    following = true
    lastCameraPhase = nil
    if !was { onFollowingChanged?() }
    follow(force: true)
  }

  /// How far one press of a panning arrow moves the map, in points: a quarter of the free area's shorter side.
  var panStep: CGFloat {
    guard let map = mapView else { return 0 }
    let area = map.bounds.inset(by: map.contentInset)
    return min(area.width, area.height) / 4
  }

  /// Shows what lies this many points from the middle of the free area. The driver moved the map: the camera stops following
  /// until Recenter.
  func pan(dx: CGFloat, dy: CGFloat, animated: Bool) {
    guard let map = mapView else { return }
    setFollowing(false)
    let area = map.bounds.inset(by: map.contentInset)
    let to = CGPoint(x: area.midX + dx, y: area.midY + dy)
    map.setCenter(map.convert(to, toCoordinateFrom: map), animated: animated)
  }

  private func setFollowing(_ on: Bool) {
    if following == on { return }
    following = on
    Self.log.info("car map: following the position: \(on)")
    onFollowingChanged?()
  }

  // ---- light and dark --------------------------------------------------------------------------------------------------

  /// The car's day or night setting, from the car scene.
  func setDark(_ on: Bool) {
    if on == dark { return }
    dark = on
    view.backgroundColor = Self.uiColor(Self.restColor(dark: dark))
    loadStyle()
  }

  // ---- style and overlays ----------------------------------------------------------------------------------------------

  private func loadStyle() {
    guard mapView != nil else { return }
    styleAttempt += 1
    let attempt = styleAttempt
    let wanted = dark
    CarLink.shared.call("style", ["dark": wanted]) { [weak self] answer in
      guard let self = self, let map = self.mapView, attempt == self.styleAttempt else { return }
      let res = CarValue.map(answer)
      guard let json = res?["style"] as? String, Self.isStyle(json) else {
        // Dart or the layer engine is still starting: ask again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
          guard let self = self, attempt == self.styleAttempt else { return }
          self.loadStyle()
        }
        return
      }
      var colors = Self.defaultColors
      if let sent = res?["colors"] as? [String: Any] {
        for (role, value) in sent {
          if let text = value as? String, CarValue.rgba(text) != nil { colors[role] = text }
        }
      }
      self.colors = colors
      self.shownStyle = wanted ? "dark" : "light"
      self.drawnSaid = false
      self.dropStyleParts()
      map.styleJSON = json
    }
  }

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    guard mapView === self.mapView else { return }
    addOverlays(to: style)
    applyRoute(CarLink.shared.routeGeoJson ?? CarLink.emptyGeoJSON)
    applyTrip(CarLink.shared.trip)
    // The new style's position source is empty: the marker is drawn into it at once.
    _ = moveMarker(CarLink.shared.trip, force: true)
    lastCameraPhase = nil
    follow(force: true, keepZoom: true)
    if let shown = shownStyle {
      Self.log.info("car map: style loaded, \(shown, privacy: .public), \(style.layers.count) layers")
    }
  }

  func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
    guard mapView === self.mapView, fullyRendered, !drawnSaid, let shown = shownStyle else { return }
    drawnSaid = true
    Self.log.info("car map: drawn in full, \(shown, privacy: .public)")
  }

  func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
    Self.log.error("car map: the map did not load: \(error.localizedDescription, privacy: .public)")
  }

  /// The route (alternatives under the chosen one, which has a casing, and its off-road stretches dashed), the destination
  /// and the position, on top of every layer of the style.
  private func addOverlays(to style: MLNStyle) {
    guard style.source(withIdentifier: Self.routeSource) == nil else { return }
    let route = MLNShapeSource(identifier: Self.routeSource, shape: nil, options: nil)
    let destination = MLNShapeSource(identifier: Self.destinationSource, shape: nil, options: nil)
    let position = MLNShapeSource(identifier: Self.positionSource, shape: nil, options: nil)
    style.addSource(route)
    style.addSource(destination)
    style.addSource(position)

    let isAlternate = NSPredicate(format: "%K == %@", "alt", NSNumber(value: true))
    let isMain = NSPredicate(format: "%K == %@", "alt", NSNumber(value: false))
    let isRoad = NSPredicate(format: "%K == %@", "kind", "road")
    let mainRoad = NSCompoundPredicate(andPredicateWithSubpredicates: [isMain, isRoad])
    let mainOffRoad = NSCompoundPredicate(andPredicateWithSubpredicates: [isMain, NSCompoundPredicate(notPredicateWithSubpredicate: isRoad)])

    style.addLayer(line("car-route-alt", route, isAlternate, role: "routeAlternate", width: 6, round: true))
    style.addLayer(line("car-route-casing", route, isMain, role: "routeCasing", width: 12, round: true))
    style.addLayer(line("car-route", route, mainRoad, role: "route", width: 8, round: true))
    let offRoad = line("car-route-offroad", route, mainOffRoad, role: "routeOffroad", width: 8, round: false)
    offRoad.lineDashPattern = NSExpression(forConstantValue: [1.2, 0.8])
    style.addLayer(offRoad)

    let pin = MLNCircleStyleLayer(identifier: "car-dest", source: destination)
    pin.circleColor = NSExpression(forConstantValue: color("pin"))
    pin.circleRadius = NSExpression(forConstantValue: 9)
    pin.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
    pin.circleStrokeWidth = NSExpression(forConstantValue: 3)
    style.addLayer(pin)

    // The grade marker at the steepest point of a climb ahead (applyBadge): part of the map, tied to its place like a sign.
    let badgePoint = MLNShapeSource(identifier: Self.badgeSource, shape: nil, options: nil)
    style.addSource(badgePoint)
    let badge = MLNSymbolStyleLayer(identifier: "car-grade-badge", source: badgePoint)
    badge.iconImageName = NSExpression(forConstantValue: Self.badgeImage)
    badge.iconAllowsOverlap = NSExpression(forConstantValue: true)
    badge.iconIgnoresPlacement = NSExpression(forConstantValue: true)
    style.addLayer(badge)
    badgeKey = nil

    // The vehicle's marker: the dot and the two arrows on the one position, all hidden until a position is drawn (showHeading
    // shows the one that applies). The arrow's picture is made here, so each style (day and night) has it in its own colours.
    let dot = MLNCircleStyleLayer(identifier: "car-pos-dot", source: position)
    dot.circleColor = NSExpression(forConstantValue: color("position"))
    dot.circleRadius = NSExpression(forConstantValue: 10)
    dot.circleStrokeColor = NSExpression(forConstantValue: color("positionRing"))
    dot.circleStrokeWidth = NSExpression(forConstantValue: 4)
    dot.isVisible = false
    style.addLayer(dot)
    style.setImage(Self.arrowPicture(fill: color("position"), outline: color("positionRing")), forName: Self.arrowImage)
    let compass = arrow("car-pos-compass", position, tiedTo: "map")
    let up = arrow("car-pos", position, tiedTo: "viewport")
    style.addLayer(compass)
    style.addLayer(up)
    dotLayer = dot
    compassLayer = compass
    arrowLayer = up
    arrowShown = nil
    upShown = nil
    shownRotation = Double.nan
  }

  private func arrow(_ id: String, _ source: MLNSource, tiedTo alignment: String) -> MLNSymbolStyleLayer {
    let layer = MLNSymbolStyleLayer(identifier: id, source: source)
    layer.iconImageName = NSExpression(forConstantValue: Self.arrowImage)
    layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
    layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
    layer.iconRotationAlignment = NSExpression(forConstantValue: alignment)
    // Upright when the map is tilted, as the dot is.
    layer.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
    layer.iconRotation = NSExpression(forConstantValue: 0)
    layer.iconOpacity = NSExpression(forConstantValue: 0)
    layer.iconOpacityTransition = MLNTransition(duration: 0, delay: 0)
    layer.isVisible = false
    return layer
  }

  /// The arrowhead pointing up, the position at the picture's middle (which is what the map puts on the position and turns
  /// the picture about): a pointed chevron with a notch at the back, in the Android car's sizes.
  private static func arrowPicture(fill: UIColor, outline: UIColor) -> UIImage {
    let width: CGFloat = 30
    let ahead: CGFloat = 19
    let below: CGFloat = 15
    let notch: CGFloat = 8.5
    let edge: CGFloat = 3
    let pad: CGFloat = 2
    let size = CGSize(width: width + 2 * pad, height: 2 * ahead + 2 * pad)
    return UIGraphicsImageRenderer(size: size).image { _ in
      let cx = size.width / 2
      let cy = size.height / 2
      let tailY = cy + below - edge / 2
      let wing = width / 2 - edge / 2
      let path = UIBezierPath()
      path.move(to: CGPoint(x: cx, y: cy - ahead + edge / 2))
      path.addLine(to: CGPoint(x: cx + wing, y: tailY))
      path.addLine(to: CGPoint(x: cx, y: tailY - notch))
      path.addLine(to: CGPoint(x: cx - wing, y: tailY))
      path.close()
      fill.setFill()
      path.fill()
      outline.setStroke()
      path.lineWidth = edge
      path.lineJoinStyle = .round
      path.stroke()
    }
  }

  /// The present style is going (a new one is loading, or the map is let go): nothing of it is used again.
  private func dropStyleParts() {
    arrowLayer = nil
    compassLayer = nil
    dotLayer = nil
    arrowShown = nil
    upShown = nil
    shownRotation = Double.nan
  }

  private func line(_ id: String, _ source: MLNSource, _ predicate: NSPredicate, role: String, width: Double, round: Bool) -> MLNLineStyleLayer {
    let layer = MLNLineStyleLayer(identifier: id, source: source)
    layer.predicate = predicate
    layer.lineColor = NSExpression(forConstantValue: color(role))
    layer.lineWidth = NSExpression(forConstantValue: width)
    if round {
      layer.lineCap = NSExpression(forConstantValue: "round")
      layer.lineJoin = NSExpression(forConstantValue: "round")
    }
    return layer
  }

  private func color(_ role: String) -> UIColor {
    Self.uiColor(colors[role] ?? Self.defaultColors[role] ?? "#000000")
  }

  private static func uiColor(_ css: String) -> UIColor {
    let c: [Double] = CarValue.rgba(css) ?? [0, 0, 0, 1]
    return UIColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: CGFloat(c[3]))
  }

  /// The plain colour shown before the app's style has come.
  private static func restColor(dark: Bool) -> String {
    dark ? "#14171c" : "#e6e3d6"
  }

  private static func restStyle(dark: Bool) -> String {
    let background = restColor(dark: dark)
    return "{\"version\":8,\"sources\":{},\"layers\":[{\"id\":\"background\",\"type\":\"background\",\"paint\":{\"background-color\":\"\(background)\"}}]}"
  }

  /// Whether the text is a JSON object: the map view raises an exception on anything else.
  private static func isStyle(_ json: String) -> Bool {
    guard let data = json.data(using: .utf8) else { return false }
    let parsed: Any? = try? JSONSerialization.jsonObject(with: data)
    return parsed is [String: Any]
  }

  private static func shape(_ geojson: String) -> MLNShape? {
    guard let data = geojson.data(using: .utf8) else { return nil }
    return try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
  }

  private static func point(_ lat: Double?, _ lon: Double?) -> String {
    guard let lat = lat, let lon = lon else { return CarLink.emptyGeoJSON }
    return "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[\(lon),\(lat)]},\"properties\":{}}]}"
  }

  private func source(_ identifier: String) -> MLNShapeSource? {
    mapView?.style?.source(withIdentifier: identifier) as? MLNShapeSource
  }

  private func applyRoute(_ geojson: String) {
    source(Self.routeSource)?.shape = Self.shape(geojson)
  }

  /// The grade marker: while guiding, with the phone's climb switch on, at the steepest point of the climb ahead, in the
  /// phone's colours for the car's day or night. Its picture is made again only when what it shows changes.
  private func applyBadge(_ t: CarTrip) {
    guard let style = mapView?.style, let point = source(Self.badgeSource) else { return }
    let colors = dark ? t.badgeNight : t.badgeDay
    guard t.guiding, t.showClimb, let colors = colors, let grade = t.steepGradePct, let lat = t.steepLat, let lon = t.steepLon else {
      point.shape = Self.shape(CarLink.emptyGeoJSON)
      return
    }
    let words = CarText.grade(grade)
    let key = "\(words)|\(dark)|\(colors.badge)|\(colors.glyph)|\(colors.edge)"
    if key != badgeKey {
      badgeKey = key
      style.setImage(CarIcons.gradeBadge(words, colors: colors), forName: Self.badgeImage)
    }
    let place = MLNPointFeature()
    place.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    point.shape = place
  }

  private func applyTrip(_ t: CarTrip) {
    applyBadge(t)
    let showDestination = t.phase != "browsing"
    let destination = showDestination ? Self.point(t.destinationLat, t.destinationLon) : CarLink.emptyGeoJSON
    source(Self.destinationSource)?.shape = Self.shape(destination)
  }

  // ---- what Dart pushes --------------------------------------------------------------------------------------------------

  func carLinkDartReady() {
    loadStyle()
  }

  func carLinkTrip(_ trip: CarTrip) {
    applyTrip(trip)
    // The overview is of a route being driven: it goes when guidance does.
    if overview && !trip.guiding {
      overview = false
    }
    let force = (overview ? "overview" : trip.phase) != lastCameraPhase
    // While the driver has moved the map away the camera does not move, so its phase is not kept up: that must not make the
    // marker jump each second.
    let snapped = moveMarker(trip, force: force && following)
    follow(force: force, snapped: snapped)
  }

  func carLinkRoute(geojson: String, bounds: [Double]?) {
    applyRoute(geojson)
    lastCameraPhase = nil
    follow(force: true)
  }

  func carLinkStyleChanged() {
    reload?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.loadStyle() }
    reload = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  // ---- the camera --------------------------------------------------------------------------------------------------------

  /// The phone is hot enough that the system asks apps to do less: the map then stays flat while guiding.
  private var hot: Bool {
    let state = ProcessInfo.processInfo.thermalState
    return state == .serious || state == .critical
  }

  @objc private func heatChanged() {
    DispatchQueue.main.async { [weak self] in self?.follow(force: true, keepZoom: true) }
  }

  // ---- the vehicle's marker and the camera that follows it ---------------------------------------------------------------

  private static func nowMs() -> Int64 {
    Int64(ProcessInfo.processInfo.systemUptime * 1000)
  }

  private static func sameHeading(_ a: Double, _ b: Double) -> Bool {
    a == b || (a.isNaN && b.isNaN)
  }

  /// The trip's position for the marker. A new position starts a glide to it from wherever the marker is drawn at this moment
  /// (also in the middle of the glide before), lasting as long as the time since the position before, capped; or the marker
  /// jumps there, when CarMarkerMotion.snaps says a glide would lie. The same position again starts nothing. Answers whether
  /// the marker jumped: then the camera is to be put there at once (follow); in a glide the frames carry it.
  private func moveMarker(_ t: CarTrip, force: Bool) -> Bool {
    guard let lat = t.lat, let lon = t.lon else {
      stopGlide()
      if hasMarker {
        source(Self.positionSource)?.shape = Self.shape(CarLink.emptyGeoJSON)
      }
      hasMarker = false
      return false
    }
    let known = CarMarkerMotion.heading(reported: t.heading, last: lastHeading, guiding: t.guiding)
    lastHeading = known
    let heading: Double = known ?? Double.nan
    let now = Self.nowMs()
    let phaseChanged = t.phase != markerPhase
    markerPhase = t.phase
    if hasMarker && !force && !phaseChanged && lat == toLat && lon == toLon && Self.sameHeading(heading, toHeading) {
      // The same position again (the trip changed in some other way, or the vehicle stands still). While it stands the clock
      // is kept up, so that pulling away is a glide of the last second and not of the whole wait. During a glide it is not:
      // the next position's glide is to last from the position before it, not from this push.
      if !gliding { lastFixAt = now }
      return false
    }
    let gap = now - lastFixAt
    let jump: Double = hasMarker ? CarMarkerMotion.distanceM(lat1: toLat, lon1: toLon, lat2: lat, lon2: lon) : 0
    let snap = CarMarkerMotion.snaps(first: !hasMarker, gapMs: gap, jumpM: jump, phaseChanged: phaseChanged, force: force)
    lastFixAt = now
    toLat = lat
    toLon = lon
    toHeading = heading
    if snap {
      stopGlide()
      hasMarker = true
      drawMarker(lat, lon, heading)
      return true
    }
    fromLat = drawnLat
    fromLon = drawnLon
    fromHeading = drawnHeading
    glideBegan = now
    glideLasts = CarMarkerMotion.durationMs(gapMs: gap)
    Self.log.debug("car map: the marker glides for \(self.glideLasts) ms")
    startGlide()
    return false
  }

  private var gliding: Bool {
    guard let glide = glide else { return false }
    return !glide.isPaused
  }

  /// The glide's clock: one display link for the map's lifetime, running only while a glide is. At most 30 frames a second
  /// are asked for; CarPlay may give fewer, and the glide is by the time passed, so it ends on time whatever the frames are.
  private func startGlide() {
    if glide == nil {
      let link = view.window?.screen.displayLink(withTarget: self, selector: #selector(glideFrame))
        ?? CADisplayLink(target: self, selector: #selector(glideFrame))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
      link.add(to: .main, forMode: .common)
      glide = link
    }
    glide?.isPaused = false
  }

  private func stopGlide() {
    glide?.isPaused = true
  }

  /// A frame of the glide: the marker, and with it the camera, at the share of the way that the share of the time gives
  /// (linear). Frames are sent to the map about 30 times a second at most (CarMarkerMotion.appliesFrame), the last one always.
  /// Nothing is sent either when the frame is where the marker already is.
  @objc private func glideFrame() {
    let now = Self.nowMs()
    let f: Double = glideLasts <= 0 ? 1 : min(1, Double(now - glideBegan) / Double(glideLasts))
    if !CarMarkerMotion.appliesFrame(fraction: f, nowMs: now, lastAppliedMs: lastFrameAt) { return }
    let lat = CarMarkerMotion.lerp(fromLat, toLat, f)
    let lon = CarMarkerMotion.lerp(fromLon, toLon, f)
    var heading = Double.nan
    if !toHeading.isNaN {
      heading = fromHeading.isNaN ? toHeading : CarMarkerMotion.lerpHeading(fromHeading, toHeading, f)
    }
    if lat != drawnLat || lon != drawnLon || !Self.sameHeading(heading, drawnHeading) {
      lastFrameAt = now
      // The camera first: the arrow's turn is worked out against the bearing the camera has in this same frame.
      drawnLat = lat
      drawnLon = lon
      drawnHeading = heading
      glideCamera()
      drawMarker(lat, lon, heading)
    }
    if f >= 1 {
      stopGlide()
    }
  }

  /// The marker at a place: the position as one point, and the arrow's turn or the dot (showHeading).
  private func drawMarker(_ lat: Double, _ lon: Double, _ heading: Double) {
    drawnLat = lat
    drawnLon = lon
    drawnHeading = heading
    guard let position = source(Self.positionSource) else { return }
    showHeading(heading)
    let point = MLNPointFeature()
    point.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    position.shape = point
  }

  /// The marker for a heading (degrees from north; not a number when none is known): the arrow turned to it, or the dot with
  /// none. Only what changed is sent to the map; the map-tied arrow is turned again once the heading is a degree away from
  /// the turn it has, and it keeps the compass heading also while it is not the one showing, so it is right the moment it is.
  private func showHeading(_ heading: Double) {
    let arrow = !heading.isNaN
    if arrowShown != arrow {
      arrowShown = arrow
      arrowLayer?.isVisible = arrow
      compassLayer?.isVisible = arrow
      dotLayer?.isVisible = !arrow
    }
    if !arrow { return }
    if shownRotation.isNaN || CarMarkerMotion.angleBetween(heading, shownRotation) >= 1 {
      shownRotation = heading
      compassLayer?.iconRotation = NSExpression(forConstantValue: heading)
    }
    let up = CarMarkerMotion.arrowIsUp(heading: heading, cameraBearing: cameraBearing)
    if upShown != up {
      upShown = up
      arrowLayer?.iconOpacity = NSExpression(forConstantValue: up ? 1 : 0)
      compassLayer?.iconOpacity = NSExpression(forConstantValue: up ? 0 : 1)
    }
  }

  /// A frame's camera: on the marker, where the camera follows the position. Not while the driver has moved the map away, and
  /// not while a route is chosen (the camera shows the whole route there, and only the marker glides).
  private func glideCamera() {
    guard let map = mapView, following else { return }
    let phase = overview ? "overview" : CarLink.shared.trip.phase
    if phase == "previewing" || phase == "overview" { return }
    placeCamera(map, drawnLat, drawnLon, drawnHeading, guiding: phase == "guiding", resetZoom: false)
  }

  /// The camera on a position, at once (one camera move; a glide calls this each frame). Close behind the position, turned to
  /// the heading and tilted while guiding, with the position low in the free area so more of the road ahead shows; north up
  /// otherwise, at the zoom the map has (resetZoom: at the starting zoom). The map view keeps its middle inside the free
  /// area (its content inset, takeFreeArea).
  private func placeCamera(_ map: MLNMapView, _ lat: Double, _ lon: Double, _ heading: Double, guiding: Bool, resetZoom: Bool) {
    let area = map.bounds.inset(by: map.contentInset)
    let extraTop: CGFloat = guiding ? area.height * 0.35 : 0
    let bearing: Double = guiding ? (heading.isNaN ? map.direction : heading) : 0
    let zoom: Double = guiding ? 16 : (resetZoom ? 14 : map.zoomLevel)
    let pitch: CGFloat = (guiding && !hot) ? 45 : 0
    jump(to: lat, lon, zoom: zoom, bearing: bearing, pitch: pitch, extraTop: extraTop)
    cameraTurnedTo(bearing)
  }

  private func jump(to lat: Double, _ lon: Double, zoom: Double, bearing: Double, pitch: CGFloat, extraTop: CGFloat) {
    guard let map = mapView else { return }
    let altitude = MLNAltitudeForZoomLevel(zoom, pitch, lat, map.bounds.size)
    let camera = MLNMapCamera(
      lookingAtCenter: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: altitude, pitch: pitch, heading: bearing)
    map.setCamera(
      camera, withDuration: 0, animationTimingFunction: nil,
      edgePadding: UIEdgeInsets(top: extraTop, left: 0, bottom: 0, right: 0), completionHandler: nil)
  }

  /// The camera was given a bearing: the arrow's turn on the screen follows from it (showHeading), in the same frame.
  private func cameraTurnedTo(_ bearing: Double) {
    if bearing == cameraBearing { return }
    cameraBearing = bearing
    if hasMarker {
      showHeading(drawnHeading)
    }
  }

  /// The camera for the phase: the whole route while choosing one, close behind the position and turned to the heading while
  /// guiding, the position north up while looking at the map. Nothing moves while the driver has moved the map away. While
  /// following the position the camera is put on the marker here only when it has to be there at once (`force`, or the
  /// marker `snapped`): otherwise the glide's frames move it with the marker.
  private func follow(force: Bool, snapped: Bool = false, keepZoom: Bool = false) {
    guard let map = mapView, following else { return }
    let t = CarLink.shared.trip
    let phase = overview ? "overview" : t.phase
    if phase == "previewing" || phase == "overview" {
      if !force && lastCameraPhase == phase { return }
      lastCameraPhase = phase
      if let b = CarLink.shared.routeBounds, b.count == 4 {
        // The route's bounds as Dart sends them (MapRoute.bounds): south, west, north, east.
        let southWest = CLLocationCoordinate2D(latitude: min(b[0], b[2]), longitude: min(b[1], b[3]))
        let northEast = CLLocationCoordinate2D(latitude: max(b[0], b[2]), longitude: max(b[1], b[3]))
        // North up and flat first: the fit keeps the turn and the tilt the camera has.
        let flat = map.camera
        flat.heading = 0
        flat.pitch = 0
        map.setCamera(flat, animated: false)
        // Android's margin of 40 around the route, or less where CarPlay's panels leave little room for the map (beside the
        // route panel, and most of all on a portrait screen, where 40 on each side would leave none).
        let free = map.bounds.inset(by: map.contentInset)
        let margin = max(4, min(40, min(free.width, free.height) * 0.15))
        map.setVisibleCoordinateBounds(
          MLNCoordinateBounds(sw: southWest, ne: northEast),
          edgePadding: UIEdgeInsets(top: margin, left: margin, bottom: margin, right: margin), animated: false, completionHandler: nil)
      } else if let lat = t.destinationLat, let lon = t.destinationLon {
        jump(to: lat, lon, zoom: 13, bearing: 0, pitch: 0, extraTop: 0)
      }
      cameraTurnedTo(0)
      return
    }
    // Where the marker is drawn (in a glide: where it is at this moment); before any marker, the trip's position.
    var lat = drawnLat
    var lon = drawnLon
    var heading = drawnHeading
    if !hasMarker {
      guard let tripLat = t.lat, let tripLon = t.lon else { return }
      lat = tripLat
      lon = tripLon
      heading = CarMarkerMotion.heading(reported: t.heading, last: lastHeading) ?? Double.nan
    }
    lastCameraPhase = phase
    if !force && !snapped { return }
    placeCamera(map, lat, lon, heading, guiding: phase == "guiding", resetZoom: force && !keepZoom)
  }
}
