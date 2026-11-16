import Foundation

/// How the vehicle's marker moves on the car's map between one position and the next (CarMapViewController draws it). Pure
/// sums, no map: where the marker is part of the way from one position to the next, how long the way takes, when it jumps
/// instead, and which heading the arrow shows. The twin of the Android car's CarMarkerMotion.kt, number for number.
enum CarMarkerMotion {
  /// The longest a glide from one position to the next takes.
  static let maxGlideMs: Int64 = 1200

  /// Positions further apart in time than this are not joined by a glide: the marker was not seen moving between them.
  static let snapGapMs: Int64 = 3000

  /// Positions further apart than this are not joined by a glide either (a new GPS lock, a test drive starting elsewhere).
  static let snapJumpM: Double = 150

  /// The least time between two frames of a glide that are sent to the map: about 30 a second. Each frame is a position and a
  /// camera move for the map, the phone may be drawing its own map and running a model, and CarPlay may slow an app's frames
  /// down by itself, so the glide never counts on more.
  static let minFrameMs: Int64 = 30

  /// Whether a frame of a glide is sent to the map: when at least `minFrameMs` have passed since the last one that was (both
  /// on one clock that only goes forward), and always for the last frame (`fraction` 1), so the marker ends exactly on the
  /// position. A jump is not a frame and is never asked about here.
  static func appliesFrame(fraction: Double, nowMs: Int64, lastAppliedMs: Int64) -> Bool {
    fraction >= 1 || nowMs - lastAppliedMs >= minFrameMs
  }

  /// A heading as 0 up to (not including) 360 degrees.
  static func norm(_ degrees: Double) -> Double {
    let m = degrees.truncatingRemainder(dividingBy: 360)
    return m < 0 ? m + 360 : m
  }

  /// The turn from `a` to `b` in degrees, the shorter way round, from -180 up to (not including) 180.
  private static func turn(from a: Double, to b: Double) -> Double {
    ((b - a).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
  }

  /// How far apart two turns are, in degrees, the shorter way round (359 and 1 are 2 apart).
  static func angleBetween(_ a: Double, _ b: Double) -> Double {
    abs(turn(from: b, to: a))
  }

  /// The arrow's turn on the screen, clockwise from straight up, for a vehicle heading `heading` on a map whose camera is
  /// turned to `cameraBearing` (both compass degrees). While the camera is turned to the heading (guidance) it is 0 and stays
  /// 0 through every corner; with north up it is the heading itself.
  static func arrowTurn(heading: Double, cameraBearing: Double) -> Double {
    norm(heading - cameraBearing)
  }

  /// Whether the camera is turned to the vehicle's heading, so the arrow points straight up the screen (guidance).
  static func arrowIsUp(heading: Double, cameraBearing: Double) -> Bool {
    arrowTurn(heading: heading, cameraBearing: cameraBearing) == 0
  }

  /// The heading the arrow shows: the one the phone reported, or with none the last one known. Nil when none was ever known:
  /// then there is no arrow (a dot is drawn), because an arrow must not point in a made-up direction.
  static func heading(reported: Double?, last: Double?) -> Double? {
    if let reported = reported, reported.isFinite { return norm(reported) }
    return last
  }

  /// The same, for a trip that is guiding or not. While guiding, a position that comes without a heading keeps the last one
  /// (the vehicle is on its route). At any other time a position without a heading has none: the vehicle is parked or its
  /// course is not known, and the marker is the dot, after a drive as before the first one.
  static func heading(reported: Double?, last: Double?, guiding: Bool) -> Double? {
    heading(reported: reported, last: guiding ? last : nil)
  }

  /// The share `f` (0 to 1) of the way from `a` to `b`; exactly `a` at 0 and exactly `b` at 1.
  static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double {
    if f >= 1 { return b }
    if f <= 0 { return a }
    return a + (b - a) * f
  }

  /// The share `f` of the turn from heading `a` to heading `b`, the shorter way round (359 to 1 goes through 0, not back
  /// through 180).
  static func lerpHeading(_ a: Double, _ b: Double, _ f: Double) -> Double {
    if f >= 1 { return norm(b) }
    if f <= 0 { return norm(a) }
    return norm(a + turn(from: a, to: b) * f)
  }

  /// Meters between two positions, on a flat sheet (fine for the short hops this is asked about). The longitudes are taken as
  /// they are, so two positions on either side of the 180 degree line read as far apart and are not glided between.
  static func distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let x = (lon2 - lon1) * .pi / 180 * cos((lat1 + lat2) / 2 * .pi / 180)
    let y = (lat2 - lat1) * .pi / 180
    return (x * x + y * y).squareRoot() * 6_371_000
  }

  /// How long the glide to a new position takes: the time since the position before it, so at a steady speed the marker
  /// arrives as the next position does, but never longer than `maxGlideMs`.
  static func durationMs(gapMs: Int64) -> Int64 {
    min(max(gapMs, 0), maxGlideMs)
  }

  /// Whether the marker jumps to a new position instead of gliding there, because a glide would show movement that did not
  /// happen: the first position, positions more than `snapGapMs` apart in time (or with no time between them) or more than
  /// `snapJumpM` apart on the ground, a change of the trip's phase, or the caller saying so.
  static func snaps(first: Bool, gapMs: Int64, jumpM: Double, phaseChanged: Bool, force: Bool) -> Bool {
    first || force || phaseChanged || gapMs <= 0 || gapMs > snapGapMs || jumpM > snapJumpM
  }
}
