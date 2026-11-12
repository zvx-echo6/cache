import UIKit

/// The car screen's turn pictures, drawn in code as on the Android car (CarIcons.kt, shape for shape): plain shapes with no
/// colour of their own, which CarPlay tints for its light and dark cards, so no picture files are added. One for each of the
/// phone's turn names (CarStep.turn).
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

  private static func picture(_ key: String, _ draw: (CGFloat) -> Void) -> UIImage {
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
