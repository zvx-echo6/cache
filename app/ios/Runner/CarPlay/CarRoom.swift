import Foundation

/// The room on the car screen, as CarPlay reports it to the app, in points: the screen's size and what CarPlay's own parts
/// take from each edge of it (the bar at the top, the panel on the leading side, the map buttons on the trailing side, the
/// dock on an upright screen). What is left is the free map. Everything that depends on the size of the car screen is
/// decided from these numbers, never from a list of screens.
struct CarRoom: Equatable {
  let width: Double
  let height: Double
  let top: Double
  let left: Double
  let bottom: Double
  let right: Double

  /// The free map: the part of the screen CarPlay's own parts leave.
  var freeWidth: Double { max(0, width - left - right) }
  var freeHeight: Double { max(0, height - top - bottom) }
}

/// CarPlay's guidance panel and what fits in it.
///
/// CarPlay draws the panel in one of two forms and does not say which. The room tells: with a panel up, what CarPlay takes
/// from the leading edge grows by the panel's width, and that width was 176 points wherever the turn card was stacked (its
/// picture and distance over its words) and 224 where it was one line. A stacked card with a second row under it and the
/// line of what is left below needs more height than the low screens have: the second row was cut off on screens 228 and
/// 240 points high and whole on one 400 high. A row that cannot be shown whole is not handed to CarPlay at all.
enum CarPanel {
  /// A panel at least this wide is the one-line form (seen: 176 stacked, 224 one line).
  static let oneLineFormWidth: Double = 200
  /// The stacked form shows its second row whole on a screen at least this high (seen: cut at 228 and 240, whole at 400).
  static let stackedSecondRowHeight: Double = 300
  /// Less than this taken from the leading edge beyond the dock is no panel yet.
  static let leastPanelWidth: Double = 100
  /// CarPlay's dock at the leading edge, as wide as it was on every landscape screen seen. Used only where the map was
  /// never seen without a panel (the car connecting in the middle of guidance).
  static let dockWidthSeen: Double = 49

  /// The panel's width: what CarPlay takes from the leading edge with a panel up (`withPanel`), less what it takes with
  /// none (`plain`, the dock). Where the plain map was never seen, the dock is taken as none when CarPlay has it at the
  /// bottom (an upright screen: `dockAtBottom`) and as `dockWidthSeen` otherwise. Nil while no panel has been measured.
  static func width(withPanel: Double?, plain: Double?, dockAtBottom: Bool) -> Double? {
    guard let withPanel = withPanel else { return nil }
    let width = withPanel - (plain ?? (dockAtBottom ? 0 : dockWidthSeen))
    return width >= leastPanelWidth ? width : nil
  }

  /// Whether the panel's second row (the turn after next, or the lanes) shows whole. Not known yet (no panel measured): yes,
  /// and the answer is taken again once CarPlay has laid the panel out.
  static func secondRowFits(panelWidth: Double?, screenHeight: Double) -> Bool {
    guard let panelWidth = panelWidth else { return true }
    return panelWidth >= oneLineFormWidth || screenHeight >= stackedSecondRowHeight
  }
}
