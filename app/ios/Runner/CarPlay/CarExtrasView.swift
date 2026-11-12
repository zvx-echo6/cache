import UIKit

/// Draws the two extras on the car's map, over the map view and under everything of CarPlay's: the route mini map (the whole
/// route as a drawn line with a moving dot; no tiles, not a second map) and the climb ahead as a one-line card (the road's
/// shape, how much is climbed, the steepest grade and how far off it is). The Android car's pieces, shape for shape and
/// colour for colour (CarOverlayPainter.kt, its split layout), at CarExtras.scale. A picture only: nothing in it can be
/// touched, and it takes no touch from the map under it.
///
/// Where the pieces go and whether the screen carries them is CarExtras' (the map controller hands the layout in); the fade is
/// this view's opacity, set by the map controller.
final class CarExtrasView: UIView {
  // The Android car's colours for its pieces (HOST_STYLE): dark cards like the host's, by day and by night.
  private static let cardFill = UIColor(red: 0x24 / 255.0, green: 0x26 / 255.0, blue: 0x27 / 255.0, alpha: 1)
  private static let cardEdge = UIColor(red: 0x45 / 255.0, green: 0x47 / 255.0, blue: 0x4B / 255.0, alpha: 1)
  private static let text = UIColor.white
  private static let secondary = UIColor(red: 0xC7 / 255.0, green: 0xCB / 255.0, blue: 0xD1 / 255.0, alpha: 1)
  private static let route = UIColor(red: 0x6B / 255.0, green: 0xB4 / 255.0, blue: 0xDE / 255.0, alpha: 1)
  private static let driven = UIColor(red: 0x5A / 255.0, green: 0x66 / 255.0, blue: 0x72 / 255.0, alpha: 1)
  private static let startDot = UIColor(red: 0x8A / 255.0, green: 0x96 / 255.0, blue: 0xA3 / 255.0, alpha: 1)
  private static let pill = UIColor(red: 0xF4 / 255.0, green: 0xF6 / 255.0, blue: 0xF8 / 255.0, alpha: 1)
  private static let pillGlyph = UIColor(red: 0x16 / 255.0, green: 0x1B / 255.0, blue: 0x20 / 255.0, alpha: 1)

  /// One CarPlay point for two of the Android painter's pixels.
  private static let k = CGFloat(CarExtras.scale)

  private var layout: CarExtras.Layout?
  private var climb: CarClimb?
  private var points: [[Double]] = []
  private var drivenFraction: Double = 0
  private var steep: [Double]?
  private var imperial = true

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
  }

  required init?(coder: NSCoder) {
    fatalError("not made from a storyboard")
  }

  /// What to draw: the places, and the trip's climb and route. Drawn again only when something of it changed.
  func show(_ layout: CarExtras.Layout, trip: CarTrip) {
    let steepNow: [Double]? = (trip.steepLat != nil && trip.steepLon != nil && trip.steepGradePct != nil) ? [trip.steepLat ?? 0, trip.steepLon ?? 0] : nil
    if layout == self.layout && trip.climb == climb && trip.overviewPoints == points && trip.drivenFraction == drivenFraction
      && steepNow == steep && trip.imperial == imperial {
      return
    }
    self.layout = layout
    climb = trip.climb
    points = trip.overviewPoints
    drivenFraction = trip.drivenFraction
    steep = steepNow
    imperial = trip.imperial
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard let layout = layout, let context = UIGraphicsGetCurrentContext() else { return }
    if let box = layout.climb, let climb = climb {
      drawClimbLine(box, climb, context)
    }
    if let box = layout.mini, points.count >= 2 {
      drawMiniMap(box, context)
    }
  }

  // ---- a card like the Android host's ---------------------------------------------------------------------------------

  private func card(_ r: CGRect) -> UIBezierPath {
    UIBezierPath(roundedRect: r, cornerRadius: 22 * Self.k)
  }

  private func drawEdge(_ r: CGRect) {
    let w = 2 * Self.k
    let edge = UIBezierPath(roundedRect: r.insetBy(dx: w / 2, dy: w / 2), cornerRadius: 22 * Self.k - w / 2)
    edge.lineWidth = w
    Self.cardEdge.setStroke()
    edge.stroke()
  }

  // ---- the climb ahead, one line ----------------------------------------------------------------------------------------

  private func drawClimbLine(_ r: CGRect, _ c: CarClimb, _ context: CGContext) {
    let k = Self.k
    Self.cardFill.setFill()
    card(r).fill()
    let figureFont = UIFont.systemFont(ofSize: 28 * k, weight: .bold)
    let textFont = UIFont.systemFont(ofSize: 24 * k, weight: .regular)
    let figure = NSAttributedString(string: CarText.climb(c.climbAheadM, imperial: imperial), attributes: [.font: figureFont, .foregroundColor: Self.text])
    var grade: NSAttributedString?
    var gradeDistance: NSAttributedString?
    if let g = c.gradePct {
      grade = NSAttributedString(string: CarText.grade(g), attributes: [.font: textFont, .foregroundColor: Self.secondary])
      if let into = c.steepestInM {
        gradeDistance = NSAttributedString(
          string: "\(CarText.grade(g)) in \(CarText.ahead(into, imperial: imperial))", attributes: [.font: textFont, .foregroundColor: Self.secondary])
      }
    }
    let pad = 16 * k
    let gap = 12 * k
    let figureW = ceil(figure.size().width)
    let form = CarExtras.lineForm(
      avail: Double(r.width - 2 * pad), figureW: Double(figureW), gradeDistanceW: gradeDistance.map { Double(ceil($0.size().width)) },
      gradeW: grade.map { Double(ceil($0.size().width)) })
    var second: NSAttributedString?
    switch form {
    case .shapeFigureGradeDistance, .figureGradeDistance: second = gradeDistance
    case .figureGrade: second = grade
    case .figure: second = nil
    }
    var x = r.minX + pad
    if form == .shapeFigureGradeDistance, let second = second {
      x = r.minX + 28 * k
      let w = min(84 * k, r.maxX - pad - x - figureW - ceil(second.size().width) - 2 * gap)
      drawShape(CGRect(x: x, y: r.midY - 52 * k / 2, width: w, height: 52 * k), c, filled: false, context)
      x += w + gap
    }
    // Both texts on one baseline: half the figure's digit height under the middle.
    let baseline = r.midY + 28 * 0.355 * k
    figure.draw(at: CGPoint(x: x, y: baseline - figureFont.ascender))
    if let second = second {
      second.draw(at: CGPoint(x: x + figureW + gap, y: baseline - textFont.ascender))
    }
    drawEdge(r)
  }

  /// The shape of the road ahead, no axes: a line (lightly filled under it when `filled`), a dot at the start, the steepest
  /// stretch hatched.
  private func drawShape(_ box: CGRect, _ c: CarClimb, filled: Bool, _ context: CGContext) {
    let k = Self.k
    let heights = c.heightsM
    let n = heights.count
    guard n >= 2, let lo = heights.min(), let hi = heights.max(), box.width > 1 else { return }
    let top = Double(box.minY + 5 * k)
    let bottom = Double(box.minY + 48 * k)
    func x(_ i: Int) -> CGFloat { box.minX + box.width * CGFloat(i) / CGFloat(n - 1) }
    func y(_ i: Int) -> CGFloat { CGFloat(CarExtras.shapeY(heights[i], lo: lo, hi: hi, top: top, bottom: bottom)) }
    let line = UIBezierPath()
    line.move(to: CGPoint(x: x(0), y: y(0)))
    for i in 1..<n { line.addLine(to: CGPoint(x: x(i), y: y(i))) }
    if filled {
      let area = UIBezierPath(cgPath: line.cgPath)
      area.addLine(to: CGPoint(x: x(n - 1), y: box.maxY))
      area.addLine(to: CGPoint(x: x(0), y: box.maxY))
      area.close()
      Self.route.withAlphaComponent(0.22).setFill()
      area.fill()
    }
    if let from = c.steepFrom, let to = c.steepTo, from >= 0, to > from, to < n {
      let steep = UIBezierPath()
      steep.move(to: CGPoint(x: x(from), y: y(from)))
      for i in (from + 1)...to { steep.addLine(to: CGPoint(x: x(i), y: y(i))) }
      steep.addLine(to: CGPoint(x: x(to), y: box.maxY))
      steep.addLine(to: CGPoint(x: x(from), y: box.maxY))
      steep.close()
      context.saveGState()
      steep.addClip()
      let hatch = UIBezierPath()
      var hx = x(from) - box.height
      while hx < x(to) {
        hatch.move(to: CGPoint(x: hx, y: box.maxY))
        hatch.addLine(to: CGPoint(x: hx + box.height, y: box.minY))
        hx += 6 * k * 1.4142
      }
      hatch.lineWidth = 2 * k
      UIColor.white.withAlphaComponent(0.6).setStroke()
      hatch.stroke()
      context.restoreGState()
    }
    line.lineWidth = 3 * k
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    Self.route.setStroke()
    line.stroke()
    let dot = UIBezierPath(arcCenter: CGPoint(x: x(0), y: y(0)), radius: 5 * k, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
    Self.text.setFill()
    dot.fill()
    dot.lineWidth = 2 * k
    Self.route.setStroke()
    dot.stroke()
  }

  // ---- the route mini map -----------------------------------------------------------------------------------------------

  private func drawMiniMap(_ r: CGRect, _ context: CGContext) {
    let k = Self.k
    Self.cardFill.setFill()
    card(r).fill()
    context.saveGState()
    card(r).addClip()
    // The steepest point is placed with the route, so it shares its frame.
    var all = points
    if let steep = steep { all.append(steep) }
    let placed = CarExtras.project(all, in: r, pad: 24 * k)
    let line = Array(placed.prefix(points.count))
    stroke(line, Self.route, 5 * k)
    let done = CarExtras.cut(line, fraction: drivenFraction)
    if done.count >= 2 { stroke(done, Self.driven, 5 * k) }
    if let end = line.last, let start = line.first {
      if steep != nil, let at = placed.last, abs(at.x - end.x) >= (14 + 6 + 2) * k || abs(at.y - end.y) >= (10 + 6 + 2) * k {
        // The grade's small pill, left out where it would lie under the destination's dot.
        let box = CGRect(x: at.x - 14 * k, y: at.y - 10 * k, width: 28 * k, height: 20 * k)
        let shape = UIBezierPath(roundedRect: box, cornerRadius: 10 * k)
        Self.pill.setFill()
        shape.fill()
        shape.lineWidth = max(1, 1.5 * k)
        Self.cardFill.setStroke()
        shape.stroke()
        let slope = UIBezierPath()
        slope.move(to: CGPoint(x: at.x - 7 * k, y: at.y + 5 * k))
        slope.addLine(to: CGPoint(x: at.x + 3 * k, y: at.y - 5 * k))
        slope.addLine(to: CGPoint(x: at.x + 3 * k, y: at.y + 5 * k))
        slope.close()
        Self.pillGlyph.setFill()
        slope.fill()
      }
      dot(start, 5 * k, Self.startDot, ring: nil, 0)
      dot(end, 6 * k, Self.text, ring: nil, 0)
      dot(done.last ?? start, 8 * k, Self.text, ring: Self.route, 3 * k)
    }
    context.restoreGState()
    drawEdge(r)
  }

  private func stroke(_ points: [CGPoint], _ color: UIColor, _ width: CGFloat) {
    guard let first = points.first, points.count >= 2 else { return }
    let path = UIBezierPath()
    path.move(to: first)
    for p in points.dropFirst() { path.addLine(to: p) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
  }

  private func dot(_ at: CGPoint, _ radius: CGFloat, _ fill: UIColor, ring: UIColor?, _ ringWidth: CGFloat) {
    let path = UIBezierPath(arcCenter: at, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
    fill.setFill()
    path.fill()
    if let ring = ring {
      path.lineWidth = ringWidth
      ring.setStroke()
      path.stroke()
    }
  }
}
