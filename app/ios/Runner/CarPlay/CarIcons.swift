import UIKit

/// The car screen's pictures, drawn in code as on the Android car (CarIcons.kt and CarOverlayPainter.kt, shape for shape), so
/// no picture files are added: a turn picture for each of the phone's turn names (CarStep.turn), the route overview
/// button's and the climb alert's shape, all plain shapes with no colour of their own, which CarPlay tints for its light and
/// dark cards; the lane strip, in white and in black for CarPlay's dark and light panels; and the grade marker for the map,
/// in the phone's own colours.
enum CarIcons {
  /// CarPlay shows a maneuver's picture at 50 x 50 points at most.
  private static let side: CGFloat = 50
  private static var made: [String: UIImage] = [:]

  /// The turn arrow for the phone's TurnIcon name.
  static func maneuver(_ turn: String) -> UIImage {
    switch turn {
    case "slightLeft": return arrow(-45)
    case "left": return arrow(-90)
    case "sharpLeft": return arrow(-135)
    case "slightRight": return arrow(45)
    case "right": return arrow(90)
    case "sharpRight": return arrow(135)
    case "merge", "ramp": return arrow(30)
    case "exit": return arrow(45)
    case "uTurn": return uTurn()
    case "roundabout": return roundabout()
    case "arrive", "via": return pin()
    default: return arrow(0)
    }
  }

  /// The route overview button's picture: a winding line between two dots, as the Android car's.
  static var overview: UIImage {
    picture("overview", side: 24) { s in
      let path = UIBezierPath()
      path.move(to: CGPoint(x: s * 0.26, y: s * 0.76))
      path.addCurve(
        to: CGPoint(x: s * 0.7, y: s * 0.3), controlPoint1: CGPoint(x: s * 0.26, y: s * 0.5), controlPoint2: CGPoint(x: s * 0.7, y: s * 0.62))
      stroke(path, s * 0.08)
      UIBezierPath(arcCenter: CGPoint(x: s * 0.26, y: s * 0.76), radius: s * 0.09, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
      UIBezierPath(arcCenter: CGPoint(x: s * 0.7, y: s * 0.26), radius: s * 0.09, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
    }
  }

  /// The shape of the road ahead for the climb alert: the heights as a line with what is under it filled lightly, and the
  /// steep stretch filled fully (the Android climb card's shape, in one colour that CarPlay tints).
  static func climbShape(_ climb: CarClimb) -> UIImage {
    let heights = climb.heightsM
    let size = CGSize(width: side, height: side)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    format.opaque = false
    let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      guard heights.count >= 2, let low = heights.min(), let high = heights.max() else { return }
      let top: CGFloat = 6
      let bottom: CGFloat = size.height - 8
      let span = max(high - low, 1)
      func x(_ i: Int) -> CGFloat { size.width * CGFloat(i) / CGFloat(heights.count - 1) }
      func y(_ i: Int) -> CGFloat { bottom - (bottom - top) * CGFloat((heights[i] - low) / span) }
      func area(_ from: Int, _ to: Int) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x(from), y: y(from)))
        for i in (from + 1)...to { path.addLine(to: CGPoint(x: x(i), y: y(i))) }
        path.addLine(to: CGPoint(x: x(to), y: size.height))
        path.addLine(to: CGPoint(x: x(from), y: size.height))
        path.close()
        return path
      }
      UIColor.white.withAlphaComponent(0.35).setFill()
      area(0, heights.count - 1).fill()
      if let from = climb.steepFrom, let to = climb.steepTo, from >= 0, to > from, to < heights.count {
        UIColor.white.setFill()
        area(from, to).fill()
      }
    }
    return drawn.withRenderingMode(.alwaysTemplate)
  }

  /// The grade marker for the map: a pill with a slope triangle and the grade, in the phone's colours for it (the Android
  /// car's badge, its sizes).
  static func gradeBadge(_ percent: String, colors: CarBadgeColors) -> UIImage {
    let font = UIFont.systemFont(ofSize: 24, weight: .bold)
    let glyph = color(colors.glyph)
    let words = NSAttributedString(string: percent, attributes: [.font: font, .foregroundColor: glyph])
    let height: CGFloat = 36
    let width = 34 + 12 + ceil(words.size().width)
    let size = CGSize(width: width + 4, height: height + 4)
    return UIGraphicsImageRenderer(size: size).image { _ in
      let box = CGRect(x: 2, y: 2, width: width, height: height)
      let pill = UIBezierPath(roundedRect: box, cornerRadius: height / 2)
      color(colors.badge).setFill()
      pill.fill()
      color(colors.edge).setStroke()
      pill.lineWidth = 1.5
      pill.stroke()
      let cy = box.midY
      let left = box.minX + 12
      let slope = UIBezierPath()
      slope.move(to: CGPoint(x: left, y: cy + 8))
      slope.addLine(to: CGPoint(x: left + 16, y: cy - 8))
      slope.addLine(to: CGPoint(x: left + 16, y: cy + 8))
      slope.close()
      glyph.setFill()
      slope.fill()
      words.draw(at: CGPoint(x: box.minX + 34, y: cy - words.size().height / 2))
    }
  }

  /// The lanes of the road at the next maneuver, for CarPlay's place for them (the second maneuver, a picture only, 120 by 18
  /// points at most): the phone's lane strip (lane_strip.dart), arrow for arrow. One ink, so the phone's tones are strengths
  /// of it: the arrow to take on the lane to be in is full, with a faint plate behind its lane; the other arrows of that lane
  /// and the lanes that also work are lighter; lanes that do not work are the phone's 38%. With no lane marked every lane is
  /// full. Apple asks for a dark and a light picture: white ink for a dark panel and black for a light one, and CarPlay
  /// takes the one for the car's setting.
  static func laneStrip(_ lanes: [CarLane]) -> UIImage {
    let dark = UITraitCollection(userInterfaceStyle: .dark)
    let asset = UIImageAsset()
    asset.register(laneStrip(lanes, ink: .white), with: dark)
    asset.register(laneStrip(lanes, ink: .black), with: UITraitCollection(userInterfaceStyle: .light))
    return asset.image(with: dark)
  }

  private static func laneStrip(_ lanes: [CarLane], ink: UIColor) -> UIImage {
    let count = max(1, lanes.count)
    let height: CGFloat = 18
    let cell: CGFloat = min(22, ((120 - CGFloat(count - 1)) / CGFloat(count)).rounded(.down))
    let glyph: CGFloat = max(6, min(height - 2, cell - 2))
    let size = CGSize(width: cell * CGFloat(count) + CGFloat(count - 1), height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    format.opaque = false
    let drawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
      for (i, lane) in lanes.enumerated() {
        let x = CGFloat(i) * (cell + 1)
        let active = lane.role == "active"
        if i > 0 && !active && lanes[i - 1].role != "active" {
          ink.withAlphaComponent(0.25).setFill()
          UIRectFillUsingBlendMode(CGRect(x: x - 1, y: (height - glyph * 0.8) / 2, width: 1, height: glyph * 0.8), .normal)
        }
        if active {
          ink.withAlphaComponent(0.18).setFill()
          UIBezierPath(roundedRect: CGRect(x: x, y: 0, width: cell, height: height), cornerRadius: 4).fill()
        }
        let tone: CGFloat = lane.role == "dim" ? 0.38 : (lane.role == "plain" ? 1 : 0.62)
        let box = CGRect(x: x + (cell - glyph) / 2, y: (height - glyph) / 2, width: glyph, height: glyph)
        let lit: String? = active ? (lane.take ?? "through") : nil
        // The arrow to take is drawn last, over the others.
        for direction in lane.directions where direction != lit {
          laneArrow(direction, in: box, color: ink.withAlphaComponent(tone), context: context.cgContext)
        }
        if let lit = lit {
          laneArrow(lit, in: box, color: ink, context: context.cgContext)
        }
      }
    }
    return drawn.withRenderingMode(.alwaysOriginal)
  }

  /// One lane arrow in a square, the phone's shapes in a unit square (LaneGlyphPainter): a stem from the foot that bends to
  /// the arrow's way, with a head; the way back as a hook; a merging lane as a stem that slides over.
  private static func laneArrow(_ direction: String, in box: CGRect, color: UIColor, context: CGContext) {
    context.saveGState()
    context.translateBy(x: box.minX, y: box.minY)
    context.scaleBy(x: box.width, y: box.height)
    color.setStroke()
    color.setFill()
    func line(_ path: UIBezierPath) {
      path.lineWidth = 0.12
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.stroke()
    }
    func head(_ tip: CGPoint, _ degrees: CGFloat) {
      let t = degrees * .pi / 180
      let dir = CGPoint(x: sin(t), y: -cos(t))
      let perp = CGPoint(x: cos(t), y: sin(t))
      let base = CGPoint(x: tip.x - dir.x * 0.3, y: tip.y - dir.y * 0.3)
      let path = UIBezierPath()
      path.move(to: tip)
      path.addLine(to: CGPoint(x: base.x + perp.x * 0.21, y: base.y + perp.y * 0.21))
      path.addLine(to: CGPoint(x: base.x - perp.x * 0.21, y: base.y - perp.y * 0.21))
      path.close()
      path.fill()
    }
    switch direction {
    case "reverse":
      let path = UIBezierPath()
      path.move(to: CGPoint(x: 0.68, y: 0.97))
      path.addLine(to: CGPoint(x: 0.68, y: 0.38))
      path.addArc(withCenter: CGPoint(x: 0.5, y: 0.38), radius: 0.18, startAngle: 0, endAngle: -.pi, clockwise: false)
      path.addLine(to: CGPoint(x: 0.32, y: 0.56))
      line(path)
      head(CGPoint(x: 0.32, y: 0.88), 180)
    case "mergeToLeft", "mergeToRight":
      let m: CGFloat = direction == "mergeToRight" ? -1 : 1
      func x(_ v: CGFloat) -> CGFloat { 0.5 + (v - 0.5) * m }
      let path = UIBezierPath()
      path.move(to: CGPoint(x: x(0.66), y: 0.97))
      path.addLine(to: CGPoint(x: x(0.66), y: 0.7))
      path.addCurve(
        to: CGPoint(x: x(0.34), y: 0.4), controlPoint1: CGPoint(x: x(0.66), y: 0.52), controlPoint2: CGPoint(x: x(0.34), y: 0.56))
      path.addLine(to: CGPoint(x: x(0.34), y: 0.3))
      line(path)
      head(CGPoint(x: x(0.34), y: 0.04), 0)
    default:
      let turn: Double = CarLane.angle(direction) ?? 0
      if turn == 0 {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.5, y: 0.97))
        path.addLine(to: CGPoint(x: 0.5, y: 0.26))
        line(path)
        head(CGPoint(x: 0.5, y: 0.03), 0)
      } else {
        let degrees = CGFloat(turn)
        let t = degrees * .pi / 180
        let dir = CGPoint(x: sin(t), y: -cos(t))
        // A sharp turn bends higher up, so its arm is long enough to read.
        let bend = CGPoint(x: 0.5, y: abs(degrees) > 90 ? 0.4 : 0.6)
        let tip = CGPoint(x: bend.x + dir.x * 0.38, y: bend.y + dir.y * 0.38)
        let end = CGPoint(x: tip.x - dir.x * 0.24, y: tip.y - dir.y * 0.24)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.5, y: 0.97))
        path.addLine(to: CGPoint(x: 0.5, y: bend.y + 0.1))
        path.addQuadCurve(to: CGPoint(x: bend.x + dir.x * 0.1, y: bend.y + dir.y * 0.1), controlPoint: bend)
        path.addLine(to: end)
        line(path)
        head(tip, degrees)
      }
    }
    context.restoreGState()
  }

  /// A colour as Dart writes it ("#rrggbb"); black for anything else.
  static func color(_ css: String) -> UIColor {
    let c: [Double] = CarValue.rgba(css) ?? [0, 0, 0, 1]
    return UIColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: CGFloat(c[3]))
  }

  private static func picture(_ key: String, side: CGFloat = CarIcons.side, _ draw: (CGFloat) -> Void) -> UIImage {
    if let image = made[key] { return image }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
    let drawn = renderer.image { _ in
      UIColor.white.setFill()
      UIColor.white.setStroke()
      draw(side)
    }
    let image = drawn.withRenderingMode(.alwaysTemplate)
    made[key] = image
    return image
  }

  private static func stroke(_ path: UIBezierPath, _ width: CGFloat) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
  }

  private static func radians(_ degrees: CGFloat) -> CGFloat {
    degrees * .pi / 180
  }

  /// An arrow head at a point, pointing along `degrees` (0 up, 90 to the right).
  private static func head(_ x: CGFloat, _ y: CGFloat, _ degrees: CGFloat, _ s: CGFloat) {
    let a = radians(degrees)
    let length = s * 0.17
    let wide = s * 0.13
    let dx = sin(a)
    let dy = -cos(a)
    let path = UIBezierPath()
    path.move(to: CGPoint(x: x + dx * length * 0.6, y: y + dy * length * 0.6))
    path.addLine(to: CGPoint(x: x - dx * length * 0.5 - dy * wide, y: y - dy * length * 0.5 + dx * wide))
    path.addLine(to: CGPoint(x: x - dx * length * 0.5 + dy * wide, y: y - dy * length * 0.5 - dx * wide))
    path.close()
    path.fill()
  }

  /// A stem up from the bottom, then bent by `degrees` (0 straight on, negative to the left), with its head.
  private static func arrow(_ degrees: CGFloat) -> UIImage {
    picture("arrow \(Int(degrees))") { s in
      let bottomX = s * 0.5 - (degrees / 135) * s * 0.12
      let kneeY = degrees == 0 ? s * 0.26 : s * 0.5
      let a = radians(degrees)
      let length = degrees == 0 ? 0 : s * 0.28
      let tipX = bottomX + sin(a) * length
      let tipY = kneeY - cos(a) * length
      let path = UIBezierPath()
      path.move(to: CGPoint(x: bottomX, y: s * 0.9))
      path.addLine(to: CGPoint(x: bottomX, y: kneeY))
      if length > 0 {
        path.addLine(to: CGPoint(x: tipX, y: tipY))
      }
      stroke(path, s * 0.11)
      head(tipX, tipY, degrees, s)
    }
  }

  private static func uTurn() -> UIImage {
    picture("u-turn") { s in
      let path = UIBezierPath()
      path.move(to: CGPoint(x: s * 0.64, y: s * 0.9))
      path.addLine(to: CGPoint(x: s * 0.64, y: s * 0.42))
      // Over the top, from the right side to the left.
      path.addArc(withCenter: CGPoint(x: s * 0.47, y: s * 0.42), radius: s * 0.17, startAngle: 0, endAngle: .pi, clockwise: false)
      path.addLine(to: CGPoint(x: s * 0.3, y: s * 0.62))
      stroke(path, s * 0.11)
      head(s * 0.3, s * 0.7, 180, s)
    }
  }

  private static func roundabout() -> UIImage {
    picture("roundabout") { s in
      let width = s * 0.1
      stroke(UIBezierPath(arcCenter: CGPoint(x: s * 0.5, y: s * 0.5), radius: s * 0.2, startAngle: 0, endAngle: 2 * .pi, clockwise: true), width)
      let entry = UIBezierPath()
      entry.move(to: CGPoint(x: s * 0.5, y: s * 0.92))
      entry.addLine(to: CGPoint(x: s * 0.5, y: s * 0.7))
      stroke(entry, width)
      let exit = UIBezierPath()
      exit.move(to: CGPoint(x: s * 0.64, y: s * 0.36))
      exit.addLine(to: CGPoint(x: s * 0.8, y: s * 0.2))
      stroke(exit, width)
      head(s * 0.82, s * 0.18, 45, s)
    }
  }

  /// A map pin, for arriving and for a stop on the way.
  private static func pin() -> UIImage {
    picture("pin") { s in
      let path = UIBezierPath()
      path.move(to: CGPoint(x: s * 0.5, y: s * 0.92))
      path.addLine(to: CGPoint(x: s * 0.27, y: s * 0.48))
      // Round the top, from the lower left to the lower right.
      path.addArc(withCenter: CGPoint(x: s * 0.5, y: s * 0.37), radius: s * 0.25, startAngle: radians(155), endAngle: radians(385), clockwise: true)
      path.close()
      // The hole in the pin's head.
      path.append(UIBezierPath(arcCenter: CGPoint(x: s * 0.5, y: s * 0.37), radius: s * 0.1, startAngle: 0, endAngle: 2 * .pi, clockwise: true))
      path.usesEvenOddFillRule = true
      path.fill()
    }
  }
}
