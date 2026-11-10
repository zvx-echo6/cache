import 'package:flutter/widgets.dart';

import '../linux_ui.dart';

/// From this window width Cache on Linux uses its desktop layout (sidebar or rail, compact density). Under it nothing changes.
const double kLinuxDesktopMin = 1024;

/// From this window width the desktop sidebar is 232 wide (under it, the 72-pixel rail).
const double kLinuxWideMin = 1280;

/// Cache on Linux in a window at least [kLinuxDesktopMin] wide. Every desktop behavior sits behind this; a phone, and Linux in a
/// narrower window, never see it.
bool isLinuxDesktop(BuildContext context) => linuxUi && MediaQuery.sizeOf(context).width >= kLinuxDesktopMin;

/// Cache on Linux in a window at least [kLinuxWideMin] wide.
bool isLinuxWide(BuildContext context) => linuxUi && MediaQuery.sizeOf(context).width >= kLinuxWideMin;

/// The desktop measures. Read them with [DesktopMetrics.of], which is null off the desktop, so a caller keeps its own value there.
class DesktopMetrics {
  const DesktopMetrics._({required this.wide});

  final bool wide;

  /// The sidebar (wide) or rail width.
  static const double sidebarWidth = 232;
  static const double railWidth = 72;

  /// The Settings and other index lists beside a detail: 300 wide, 280 under [kLinuxWideMin].
  double get listWidth => wide ? 300 : 280;

  /// A page's side gutter.
  double get gutter => wide ? 32 : 24;

  /// A page bar's height.
  static const double barHeight = 56;

  /// The widest a settings form is; left-aligned.
  static const double formMaxWidth = 760;

  /// A snackbar's widest.
  static const double snackWidth = 480;

  /// The metrics for the window [context] is in; null unless [isLinuxDesktop].
  static DesktopMetrics? of(BuildContext context) => isLinuxDesktop(context) ? DesktopMetrics._(wide: isLinuxWide(context)) : null;
}
