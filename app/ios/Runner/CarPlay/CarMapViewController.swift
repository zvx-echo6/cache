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

  /// The camera keeps the position in view (the Recenter button turns it back on after the map was moved).
  private(set) var following = true

  /// Called when `following` changes, so the car scene can show or hide Recenter.
  var onFollowingChanged: (() -> Void)?

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
    loadStyle()
  }

  /// The car has gone: the map and what it holds are let go.
  func release() {
    styleAttempt += 1
    reload?.cancel()
    reload = nil
    CarLink.shared.removeListener(self)
    NotificationCenter.default.removeObserver(self)
    onFollowingChanged = nil
    mapView?.delegate = nil
    mapView?.removeFromSuperview()
    mapView = nil
    shownStyle = nil
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    // CarPlay's bars, buttons and panels changed the free area. The map view takes the new one for itself in its own layout;
    // the camera is put again after that, at the zoom it had.
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.sayArea()
      self.follow(force: true, keepZoom: true)
    }
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
      map.styleJSON = json
    }
  }

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    guard mapView === self.mapView else { return }
    addOverlays(to: style)
    applyRoute(CarLink.shared.routeGeoJson ?? CarLink.emptyGeoJSON)
    applyTrip(CarLink.shared.trip)
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

    let dot = MLNCircleStyleLayer(identifier: "car-pos", source: position)
    dot.circleColor = NSExpression(forConstantValue: color("position"))
    dot.circleRadius = NSExpression(forConstantValue: 10)
    dot.circleStrokeColor = NSExpression(forConstantValue: color("positionRing"))
    dot.circleStrokeWidth = NSExpression(forConstantValue: 4)
    style.addLayer(dot)
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

  private func applyTrip(_ t: CarTrip) {
    source(Self.positionSource)?.shape = Self.shape(Self.point(t.lat, t.lon))
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
    follow(force: trip.phase != lastCameraPhase)
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
    DispatchQueue.main.async { [weak self] in self?.follow(force: false) }
  }

  /// The camera for the phase: the whole route while choosing one, close behind the position and turned to the heading while
  /// guiding, the position north up while looking at the map. Nothing moves while the driver has moved the map away. The map
  /// view keeps its middle inside the free area by itself (its content inset follows the view's safe area).
  private func follow(force: Bool, keepZoom: Bool = false) {
    guard let map = mapView, following else { return }
    let t = CarLink.shared.trip
    let phase = t.phase
    if phase == "previewing" {
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
        map.setVisibleCoordinateBounds(
          MLNCoordinateBounds(sw: southWest, ne: northEast), edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
          animated: false, completionHandler: nil)
      } else if let lat = t.destinationLat, let lon = t.destinationLon {
        place(lat, lon, zoom: 13, heading: 0, pitch: 0, extraTop: 0, seconds: 0)
      }
      return
    }
    guard let lat = t.lat, let lon = t.lon else { return }
    lastCameraPhase = phase
    let guiding = phase == "guiding"
    let area = map.bounds.inset(by: map.contentInset)
    // While guiding the position sits low in the free area, so more of the road ahead shows.
    let extraTop: CGFloat = guiding ? area.height * 0.35 : 0
    let zoom: Double = guiding ? 16 : ((force && !keepZoom) ? 14 : map.zoomLevel)
    let heading: Double = guiding ? (t.heading ?? map.direction) : 0
    let pitch: CGFloat = (guiding && !hot) ? 45 : 0
    place(lat, lon, zoom: zoom, heading: heading, pitch: pitch, extraTop: extraTop, seconds: force ? 0 : 0.9)
  }

  private func place(_ lat: Double, _ lon: Double, zoom: Double, heading: Double, pitch: CGFloat, extraTop: CGFloat, seconds: TimeInterval) {
    guard let map = mapView else { return }
    let altitude = MLNAltitudeForZoomLevel(zoom, pitch, lat, map.bounds.size)
    let camera = MLNMapCamera(
      lookingAtCenter: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: altitude, pitch: pitch, heading: heading)
    map.setCamera(
      camera, withDuration: seconds, animationTimingFunction: CAMediaTimingFunction(name: .linear),
      edgePadding: UIEdgeInsets(top: extraTop, left: 0, bottom: 0, right: 0), completionHandler: nil)
  }
}
