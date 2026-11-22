import UIKit

/// Draws the two extras on the car's map, over the map view and under everything of CarPlay's: the route mini map (the whole
/// route as a drawn line with a moving dot; no tiles, not a second map) and the climb ahead as a one-line card (the road's
/// shape, how much is climbed, the steepest grade and how far off it is). The Android car's pieces, shape for shape and
/// colour for colour (CarOverlayPainter.kt), at CarExtras.scale, in the colours of the phone's chosen theme from the trip's
/// palette (the car follows the phone's theme day and night). A picture only: nothing in it can be touched, and it takes no
/// touch from the map under it.
///
/// Where the pieces go and whether the screen carries them is CarExtras' (the map controller hands the layout in); the fade is
/// this view's opacity, set by the map controller.
final class CarExtrasView: UIView {
  /// The colours the pieces are drawn in.
  private struct Look {
    let cardFill: UIColor
    let cardEdge: UIColor
    let text: UIColor
    let secondary: UIColor
    let route: UIColor
    let driven: UIColor
    let startDot: UIColor
    let destDot: UIColor
    let posFill: UIColor
    let posRing: UIColor
    let pill: UIColor
    let pillGlyph: UIColor
    let pillEdge: UIColor
    let hatch: UIColor
    let miniBg: UIColor

    /// Only until the trip's palette has come: the Android car's dark cards like the host's (its HOST_STYLE).
    static let fallback: Look = {
      func rgb(_ v: Int) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
      }
      let card = rgb(0x242627)
      let route = rgb(0x6BB4DE)
      return Look(
        cardFill: card, cardEdge: rgb(0x45474B), text: .white, secondary: rgb(0xC7CBD1), route: route, driven: rgb(0x5A6672),
        startDot: rgb(0x8A96A3), destDot: .white, posFill: .white, posRing: route, pill: rgb(0xF4F6F8), pillGlyph: rgb(0x161B20),
        pillEdge: card, hatch: .white, miniBg: card)
    }()

    /// The phone's chosen theme, as the Android car paints it (CarOverlayPainter with the trip's palette).
    static func of(_ p: CarThemeColors?) -> Look {
      guard let p = p else { return fallback }
      func c(_ css: String) -> UIColor {
        let v: [Double] = CarValue.rgba(css) ?? [0, 0, 0, 1]
        return UIColor(red: CGFloat(v[0]), green: CGFloat(v[1]), blue: CGFloat(v[2]), alpha: CGFloat(v[3]))
      }
      return Look(
        cardFill: c(p.card), cardEdge: c(p.miniBorder), text: c(p.cardText), secondary: c(p.cardSecondary), route: c(p.route),
        driven: c(p.routeDriven), startDot: c(p.startDot), destDot: c(p.destDot), posFill: c(p.posFill), posRing: c(p.posRing),
        pill: c(p.badge), pillGlyph: c(p.badgeGlyph), pillEdge: c(p.badgeEdge), hatch: c(p.hatch), miniBg: c(p.miniBg))
    }
  }

  /// The box's climb label: the Android car's words for it (CarOverlayPainter.drawClimbPart).
  private static let climbLabel = "Climb ahead"

  /// One CarPlay point for two of the Android painter's pixels.
  private static let k = CGFloat(CarExtras.scale)

  private var layout: CarExtras.Layout?
  private var climb: CarClimb?
  private var points: [[Double]] = []
  private var drivenFraction: Double = 0
  private var steep: [Double]?
  private var imperial = true
  private var palette: CarThemeColors?
  private var look = Look.fallback

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
      && steepNow == steep && trip.imperial == imperial && trip.palette == palette {
      return
    }
    self.layout = layout
    climb = trip.climb
    points = trip.overviewPoints
    drivenFraction = trip.drivenFraction
    steep = steepNow
    imperial = trip.imperial
    if trip.palette != palette {
      palette = trip.palette
      look = Look.of(palette)
    }
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard let layout = layout, let context = UIGraphicsGetCurrentContext() else { return }
    if layout.mode == .oneBox {
      drawOneBox(layout, context)
      return
    }
    if let box = layout.climb, let climb = climb {
      drawClimbLine(box, climb, context)
    }
    if let box = layout.mini, points.count >= 2 {
      drawMiniMap(box, context)
    }
  }

  /// The one box (Android's ONE_BOX): one card, the mini map in its upper part, a thin divider, the climb in its lower part.
  /// Each part keeps its place when the other has nothing to show; the card is then that part alone.
  private func drawOneBox(_ layout: CarExtras.Layout, _ context: CGContext) {
    let mini: CGRect? = points.count >= 2 ? layout.mini : nil
    let part: CGRect? = climb != nil ? layout.climb : nil
    guard let box = mini.map({ m in part.map { m.union($0) } ?? m }) ?? part else { return }
    look.cardFill.setFill()
    card(box).fill()
    context.saveGState()
    card(box).addClip()
    if let m = mini {
      context.saveGState()
      context.clip(to: m)
      // The mini map's part on the theme's page colour, as its tile (Android's ONE_BOX does the same).
      look.miniBg.setFill()
      UIRectFill(m)
      drawMiniContent(m, context)
      context.restoreGState()
    }
    if let r = part, let c = climb {
      drawClimbPart(r, c, context)
      if mini != nil {
        look.cardEdge.setFill()
        UIRectFill(CGRect(x: r.minX, y: r.minY, width: r.width, height: Self.k))
      }
    }
    context.restoreGState()
    drawEdge(box)
  }

  /// The climb in the box's lower part (no card of its own), as Android's drawClimbPart: the label, the figure in bold and
  /// the grade line in semibold one under the other, and the shape right of the label and the figure. The shape takes what
  /// those two leave and is left out when that is under half of its least width.
  private func drawClimbPart(_ r: CGRect, _ c: CarClimb, _ context: CGContext) {
    let x0 = r.minX + CGFloat(CarExtras.boxPadX)
    let labelFont = UIFont.systemFont(ofSize: CGFloat(CarExtras.climbLabelSize), weight: .regular)
    let figureFont = UIFont.systemFont(ofSize: CGFloat(CarExtras.climbFigureSize), weight: .bold)
    let gradeFont = UIFont.systemFont(ofSize: CGFloat(CarExtras.climbGradeSize), weight: .semibold)
    let label = NSAttributedString(string: Self.climbLabel, attributes: [.font: labelFont, .foregroundColor: look.secondary])
    let figure = NSAttributedString(string: CarText.climb(c.climbAheadM, imperial: imperial), attributes: [.font: figureFont, .foregroundColor: look.text])
    let labelY = r.minY + CGFloat(CarExtras.boxPadTop + CarExtras.climbLabelSize)
    let figureY = labelY + CGFloat(CarExtras.climbFigureDrop)
    label.draw(at: CGPoint(x: x0, y: labelY - labelFont.ascender))
    figure.draw(at: CGPoint(x: x0, y: figureY - figureFont.ascender))
    if let g = c.gradePct, let into = c.steepestInM {
      let line = NSAttributedString(
        string: "\(CarText.grade(g)) in \(CarText.ahead(into, imperial: imperial))", attributes: [.font: gradeFont, .foregroundColor: look.text])
      line.draw(at: CGPoint(x: x0, y: figureY + CGFloat(CarExtras.climbGradeDrop) - gradeFont.ascender))
    }
    let shapeRight = r.maxX - CGFloat(CarExtras.boxPadX)
    let shapeLeft = x0 + max(ceil(label.size().width), ceil(figure.size().width)) + CGFloat(CarExtras.climbGap)
    if shapeRight - shapeLeft < CGFloat(CarExtras.shapeMinWidth) * 0.5 { return }
    // Level with the label and the figure: from the label's top to the figure's baseline, the shape in the middle.
    let mid = (r.minY + CGFloat(CarExtras.boxPadTop) + figureY) / 2
    let h = CGFloat(CarExtras.shapeHeight)
    drawShape(CGRect(x: shapeLeft, y: mid - h / 2, width: shapeRight - shapeLeft, height: h), c, filled: true, context)
  }

  // ---- a card like the Android host's ---------------------------------------------------------------------------------

  private func card(_ r: CGRect) -> UIBezierPath {
    UIBezierPath(roundedRect: r, cornerRadius: 22 * Self.k)
  }

  private func drawEdge(_ r: CGRect) {
    let w = 2 * Self.k
    let edge = UIBezierPath(roundedRect: r.insetBy(dx: w / 2, dy: w / 2), cornerRadius: 22 * Self.k - w / 2)
    edge.lineWidth = w
    look.cardEdge.setStroke()
    edge.stroke()
  }

  // ---- the climb ahead, one line ----------------------------------------------------------------------------------------

  private func drawClimbLine(_ r: CGRect, _ c: CarClimb, _ context: CGContext) {
    let k = Self.k
    look.cardFill.setFill()
    card(r).fill()
    let figureFont = UIFont.systemFont(ofSize: 28 * k, weight: .bold)
    let textFont = UIFont.systemFont(ofSize: 24 * k, weight: .regular)
    let figure = NSAttributedString(string: CarText.climb(c.climbAheadM, imperial: imperial), attributes: [.font: figureFont, .foregroundColor: look.text])
    var grade: NSAttributedString?
    var gradeDistance: NSAttributedString?
    if let g = c.gradePct {
      grade = NSAttributedString(string: CarText.grade(g), attributes: [.font: textFont, .foregroundColor: look.secondary])
      if let into = c.steepestInM {
        gradeDistance = NSAttributedString(
          string: "\(CarText.grade(g)) in \(CarText.ahead(into, imperial: imperial))", attributes: [.font: textFont, .foregroundColor: look.secondary])
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
      look.route.withAlphaComponent(0.22).setFill()
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
      look.hatch.withAlphaComponent(0.6).setStroke()
      hatch.stroke()
      context.restoreGState()
    }
    line.lineWidth = 3 * k
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    look.route.setStroke()
    line.stroke()
    let dot = UIBezierPath(arcCenter: CGPoint(x: x(0), y: y(0)), radius: 5 * k, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
    look.posFill.setFill()
    dot.fill()
    dot.lineWidth = 2 * k
    look.posRing.setStroke()
    dot.stroke()
  }

  // ---- the route mini map -----------------------------------------------------------------------------------------------

  /// The mini map as a tile of its own: the theme's page colour, the content, the outline.
  private func drawMiniMap(_ r: CGRect, _ context: CGContext) {
    look.miniBg.setFill()
    card(r).fill()
    context.saveGState()
    card(r).addClip()
    drawMiniContent(r, context)
    context.restoreGState()
    drawEdge(r)
  }

  /// The route, the driven part, the grade pill and the three dots in `r`; the caller clips.
  private func drawMiniContent(_ r: CGRect, _ context: CGContext) {
    let k = Self.k
    // The steepest point is placed with the route, so it shares its frame.
    var all = points
    if let steep = steep { all.append(steep) }
    let placed = CarExtras.project(all, in: r, pad: 24 * k)
    let line = Array(placed.prefix(points.count))
    stroke(line, look.route, 5 * k)
    let done = CarExtras.cut(line, fraction: drivenFraction)
    if done.count >= 2 { stroke(done, look.driven, 5 * k) }
    if let end = line.last, let start = line.first {
      if steep != nil, let at = placed.last, abs(at.x - end.x) >= (14 + 6 + 2) * k || abs(at.y - end.y) >= (10 + 6 + 2) * k {
        // The grade's small pill, left out where it would lie under the destination's dot.
        let box = CGRect(x: at.x - 14 * k, y: at.y - 10 * k, width: 28 * k, height: 20 * k)
        let shape = UIBezierPath(roundedRect: box, cornerRadius: 10 * k)
        look.pill.setFill()
        shape.fill()
        shape.lineWidth = 1.5 * k  // Android: max(1, 1.5) pixels at density 1
        look.pillEdge.setStroke()
        shape.stroke()
        let slope = UIBezierPath()
        slope.move(to: CGPoint(x: at.x - 7 * k, y: at.y + 5 * k))
        slope.addLine(to: CGPoint(x: at.x + 3 * k, y: at.y - 5 * k))
        slope.addLine(to: CGPoint(x: at.x + 3 * k, y: at.y + 5 * k))
        slope.close()
        look.pillGlyph.setFill()
        slope.fill()
      }
      dot(start, 5 * k, look.startDot, ring: nil, 0)
      dot(end, 6 * k, look.destDot, ring: nil, 0)
      dot(done.last ?? start, 8 * k, look.posFill, ring: look.posRing, 3 * k)
    }
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
