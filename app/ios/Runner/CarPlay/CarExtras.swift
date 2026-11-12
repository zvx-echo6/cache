import CoreGraphics
import Foundation

/// How a car screen stands to the two extras (the route mini map and the climb ahead), measured from the room CarPlay
/// reports (CarExtras.layout), never from a list of screens. The same measure and the same number as the Android car's
/// (CarOverlayPainter.extrasMeasure); the names are its names, as the log writes them.
enum CarScreenClass: String {
  /// The two do not both fit at full size beside the vehicle and the road ahead: never on the car.
  case small = "SMALL"
  /// They fit, but take more than CarExtras.bigMaxShare of the free map: on the car, except while the phone's drive screen
  /// shows.
  case between = "IN_BETWEEN"
  /// They fit and take no more than that: always on the car.
  case big = "BIG"
}

/// The two extras on the car's map: where they go, which class a screen is in, and when they fade. Pure sums; the drawing is
/// CarExtrasView's. The Android car draws the same two pieces (CarOverlayPainter.kt); the sizes here are its sizes.
///
/// Where they go: inside the free map (what CarPlay's bar, panel, buttons and dock leave), along its bottom edge, the climb
/// in the leading corner and the mini map in the trailing one, each beside the vehicle's column and never in it. The
/// vehicle is where the guidance camera draws it (the middle of the free map sideways, low in it), and its column is the
/// marker with a little free map on each side, up to the top: the road ahead.
enum CarExtras {
  /// THE ONE PLACE that takes the mini map and the climb off CarPlay's map: false here, and nothing of them is drawn on
  /// any car screen (the grade marker on the route, which is map content, stays).
  static let onMap = true

  // ---- the named numbers, in points ---------------------------------------------------------------------------------

  /// One CarPlay point for two of the Android car's own pixels: a CarPlay screen has about half as many points across as
  /// the Android car has pixels, and CarPlay's small text is about 12 points where the Android host's is 24 pixels.
  static let scale: Double = 0.5
  /// Free map kept between a piece and the free map's edge.
  static let margin: Double = 16 * scale
  /// The mini map's tile, at its one size.
  static let miniWidth: Double = 220 * scale
  static let miniHeight: Double = 140 * scale
  /// The climb's one-line card: its height, and the least and the most it is wide.
  static let lineHeight: Double = 64 * scale
  static let lineMinWidth: Double = 200 * scale
  static let lineMaxWidth: Double = 400 * scale
  /// The vehicle's marker (the arrow, 30 points wide, reaching 15 below the position) and the free map kept on each side
  /// of it and of the road ahead.
  static let markerHalf: Double = 15
  static let markerBelow: Double = 15
  static let vehicleSide: Double = 16 * scale
  /// The guidance camera leaves this share of the free map's height above the position (CarMapViewController.placeCamera).
  static let topShare: Double = 0.35
  /// The most of the free map the two may take on a screen that always carries them: at or below it the screen is big,
  /// above it in-between. The Android car's number (EXTRAS_BIG_MAX_SHARE). Change it here and nowhere else.
  static let bigMaxShare: Double = 0.15
  /// The one pause before a fade starts, and the fade.
  static let pauseSeconds: Double = 2
  static let fadeSeconds: Double = 0.5

  // ---- where they go, and the screen's class ------------------------------------------------------------------------

  struct Layout: Equatable {
    /// The mini map's tile and the climb's card in the car window's points; both nil where the two do not both fit.
    let mini: CGRect?
    let climb: CGRect?
    /// Whether both fit at full size, clear of the vehicle and the road ahead.
    let fits: Bool
    /// The area the pieces take as placed (of whichever could be placed), and the free map's area, in square points.
    let extrasArea: Double
    let freeArea: Double
    let screenClass: CarScreenClass

    /// The share of the free map the pieces take.
    var share: Double { freeArea > 0 ? extrasArea / freeArea : 1 }

    /// The measure in a line, in the shape the Android car logs it.
    var words: String {
      "\(screenClass.rawValue) (they \(fits ? "fit" : "do not fit"); \(Int(extrasArea.rounded())) pt of \(Int(freeArea.rounded())) pt free map, \(Int((share * 100).rounded())) %)"
    }
  }

  /// Where the guidance camera draws the position in the free map.
  static func vehiclePoint(_ free: CGRect) -> CGPoint {
    CGPoint(x: free.midX, y: free.minY + free.height * CGFloat((1 + topShare) / 2))
  }

  /// What no piece may cover: the marker with free map on each side, and the column above it up to the top (the road ahead).
  static func keepClear(_ free: CGRect) -> CGRect {
    let v = vehiclePoint(free)
    let half = CGFloat(markerHalf + vehicleSide)
    return CGRect(x: v.x - half, y: free.minY, width: 2 * half, height: v.y + CGFloat(markerBelow) - free.minY)
  }

  /// The two pieces in `free` (the free map while guiding: the room CarPlay leaves the map, its safe area), and the
  /// screen's class from them. The mini map is its full size in the trailing bottom corner, beside the vehicle's column; the
  /// climb's card runs from the leading edge to the column, no wider than its most. They FIT when both can be placed so.
  /// They TAKE the area of the pieces as placed. Small: they do not fit. In-between: they take more than `bigMaxShare` of
  /// the free map. Big: otherwise.
  static func layout(free: CGRect) -> Layout {
    let freeArea = Double(max(0, free.width) * max(0, free.height))
    if freeArea <= 0 { return Layout(mini: nil, climb: nil, fits: false, extrasArea: 0, freeArea: 0, screenClass: .small) }
    let keep = keepClear(free)
    let edge = CGFloat(margin)
    var mini: CGRect?
    let tile = CGRect(
      x: free.maxX - edge - CGFloat(miniWidth), y: free.maxY - edge - CGFloat(miniHeight), width: CGFloat(miniWidth), height: CGFloat(miniHeight))
    if tile.minX >= keep.maxX && tile.minY >= free.minY + edge {
      mini = tile
    }
    var climb: CGRect?
    let left = free.minX + edge
    let right = min(keep.minX, left + CGFloat(lineMaxWidth))
    let top = free.maxY - edge - CGFloat(lineHeight)
    if right - left >= CGFloat(lineMinWidth) && top >= free.minY + edge {
      climb = CGRect(x: left, y: top, width: right - left, height: CGFloat(lineHeight))
    }
    let fits = mini != nil && climb != nil
    var extras: Double = 0
    if let a = mini { extras += Double(a.width * a.height) }
    if let b = climb { extras += Double(b.width * b.height) }
    let screen: CarScreenClass = !fits ? .small : (extras > bigMaxShare * freeArea ? .between : .big)
    return Layout(mini: fits ? mini : nil, climb: fits ? climb : nil, fits: fits, extrasArea: extras, freeArea: freeArea, screenClass: screen)
  }

  /// How a screen of this class carries the two, in the word the car side tells the phone (the method `extras` on the car
  /// channel, `carries`): the phone shows them itself for "never", while its drive screen shows for "unlessPhone", and
  /// not at all for "always". With the two taken off the map (`onMap`), every screen is "never".
  static func carriesWord(_ screen: CarScreenClass) -> String {
    if !onMap { return "never" }
    switch screen {
    case .small: return "never"
    case .between: return "unlessPhone"
    case .big: return "always"
    }
  }

  /// Whether a screen of this class carries the two at this moment: a small one never, a big one always, an in-between one
  /// except while the phone's drive screen shows (`phoneDrive`, the phone's own word for it in the trip).
  static func carries(_ screen: CarScreenClass, phoneDrive: Bool) -> Bool {
    switch screen {
    case .small: return false
    case .big: return true
    case .between: return !phoneDrive
    }
  }

  // ---- the mini map's picture ---------------------------------------------------------------------------------------

  /// The route's points ([latitude, longitude]) in a box, one scale, centred, with `pad` around: longitude narrowed by the
  /// cosine of the middle latitude. No tiles, no labels.
  static func project(_ points: [[Double]], in box: CGRect, pad: CGFloat) -> [CGPoint] {
    if points.isEmpty { return [] }
    let lat0: Double = points.map { $0[0] }.reduce(0, +) / Double(points.count)
    let kx: Double = cos(lat0 * Double.pi / 180)
    let xs: [Double] = points.map { $0[1] * kx }
    let ys: [Double] = points.map { -$0[0] }
    let minX = xs.min() ?? 0
    let minY = ys.min() ?? 0
    let w: Double = max((xs.max() ?? 0) - minX, 1e-9)
    let h: Double = max((ys.max() ?? 0) - minY, 1e-9)
    let aw = Double(box.width - 2 * pad)
    let ah = Double(box.height - 2 * pad)
    let s: Double = min(aw / w, ah / h)
    let ox: Double = Double(box.minX + pad) + (aw - w * s) / 2
    let oy: Double = Double(box.minY + pad) + (ah - h * s) / 2
    var out: [CGPoint] = []
    for i in points.indices {
      out.append(CGPoint(x: ox + (xs[i] - minX) * s, y: oy + (ys[i] - minY) * s))
    }
    return out
  }

  /// The first `fraction` of a line (by length), ending exactly there.
  static func cut(_ points: [CGPoint], fraction: Double) -> [CGPoint] {
    guard let first = points.first else { return [] }
    if points.count < 2 || fraction <= 0 { return [first] }
    var along: [Double] = [0]
    for i in 1..<points.count {
      let dx = Double(points[i].x - points[i - 1].x)
      let dy = Double(points[i].y - points[i - 1].y)
      along.append(along[i - 1] + (dx * dx + dy * dy).squareRoot())
    }
    let target: Double = (along.last ?? 0) * min(max(fraction, 0), 1)
    var out: [CGPoint] = [first]
    for i in 1..<points.count {
      if along[i] <= target {
        out.append(points[i])
        continue
      }
      let part: Double = along[i] - along[i - 1]
      let t: Double = part <= 0 ? 0 : (target - along[i - 1]) / part
      let x = Double(points[i - 1].x) + Double(points[i].x - points[i - 1].x) * t
      let y = Double(points[i - 1].y) + Double(points[i].y - points[i - 1].y) * t
      out.append(CGPoint(x: x, y: y))
      break
    }
    return out
  }

  // ---- the climb's shape and line -----------------------------------------------------------------------------------

  /// The shape's whole height stands for at least this much rise, in meters, so a small rise draws low and a flat road flat.
  static let shapeMinRiseM: Double = 100

  /// Where a height is drawn between `top` (high) and `bottom` (low), for a stretch whose heights run from `lo` to `hi`.
  static func shapeY(_ heightM: Double, lo: Double, hi: Double, top: Double, bottom: Double) -> Double {
    let span: Double = max(hi - lo, shapeMinRiseM)
    return (top + bottom) / 2 - ((heightM - (lo + hi) / 2) / span) * (bottom - top)
  }

  /// What the one-line card holds, most first.
  enum LineForm: Equatable { case shapeFigureGradeDistance, figureGradeDistance, figureGrade, figure }

  /// What a line `avail` wide holds at its fixed text sizes: the figure always; then the grade; then the distance; the
  /// shape only when all three fit beside it. So the shape is the first to go and the distance the next.
  static func lineForm(avail: Double, figureW: Double, gradeDistanceW: Double?, gradeW: Double?) -> LineForm {
    let gap: Double = 12 * scale
    if let both = gradeDistanceW {
      let inset: Double = (28 - 16) * scale
      if inset + 60 * scale + gap + figureW + gap + both <= avail { return .shapeFigureGradeDistance }
      if figureW + gap + both <= avail { return .figureGradeDistance }
    }
    if let grade = gradeW, figureW + gap + grade <= avail { return .figureGrade }
    return .figure
  }
}

/// When the two extras fade on an in-between screen. The phone says at once whether its drive screen shows; the car waits one
/// pause before it follows, so a quick flip on the phone and back changes nothing on the car, and then fades. Pure: the
/// clock is handed in.
struct CarExtrasFade: Equatable {
  /// What the car shows, or is fading to.
  private(set) var shown: Bool
  /// What it should show, as last told, and since when.
  private(set) var wanted: Bool
  private var wantedSince: Double = 0

  init(shown: Bool) {
    self.shown = shown
    wanted = shown
  }

  /// The plain truth, as it comes. A change back to what the car shows, inside the pause, ends the wait.
  mutating func want(_ on: Bool, at now: Double) {
    if on == wanted { return }
    wanted = on
    wantedSince = now
  }

  /// When to look again (the end of the pause), or nil with nothing waiting.
  var due: Double? {
    wanted == shown ? nil : wantedSince + CarExtras.pauseSeconds
  }

  /// At `now`: whether a fade starts (the pause has run out), and to what. Nil when nothing starts.
  mutating func start(at now: Double) -> Bool? {
    guard let due = due, now >= due else { return nil }
    shown = wanted
    return shown
  }

  /// With no pause and no fade: what the car shows from now (a new drive, a new screen).
  mutating func set(_ on: Bool) {
    shown = on
    wanted = on
  }
}
