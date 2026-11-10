import 'package:flutter/material.dart';

import '../theme.dart';
import 'desktop.dart';

/// [base] with the desktop's density: a lower page bar with a hairline, 16-pixel dialogs, smaller body text, 36-pixel buttons,
/// a hover tint and, for a snackbar, a place at the bottom left of a region [regionWidth] wide. Only colours from [CacheTokens]; text
/// styles are [base]'s own, resized, so the font stays whatever the app uses.
ThemeData desktopTheme(ThemeData base, {required double regionWidth}) {
  final k = base.extension<CacheTokens>();
  if (k == null) return base;
  TextStyle? size(TextStyle? s, double px, {double? height}) => s?.copyWith(fontSize: px, height: height);
  ButtonStyle? button(ButtonStyle? s) {
    if (s == null) return null;
    final ts = s.textStyle;
    return s.copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(48, 40)),
      textStyle: ts == null ? null : WidgetStateProperty.resolveWith((st) => size(ts.resolve(st), 14)),
    );
  }

  OutlineInputBorder border(InputBorder? b) {
    final o = b is OutlineInputBorder ? b : const OutlineInputBorder();
    return o.copyWith(borderRadius: BorderRadius.circular(12));
  }

  final text = base.textTheme;
  final dialog = base.dialogTheme;
  final input = base.inputDecorationTheme;
  final right = (regionWidth - DesktopMetrics.snackWidth - 24).clamp(24.0, double.infinity).toDouble();
  return base.copyWith(
    hoverColor: k.text.withValues(alpha: 0.06),
    focusColor: k.accent.withValues(alpha: 0.18),
    highlightColor: k.text.withValues(alpha: 0.10),
    textTheme: text.copyWith(
      bodyLarge: size(text.bodyLarge, 16, height: 1.5),
      bodyMedium: size(text.bodyMedium, 15, height: 1.5),
      titleLarge: size(text.titleLarge, 20),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      toolbarHeight: DesktopMetrics.barHeight,
      titleSpacing: 24,
      titleTextStyle: size(base.appBarTheme.titleTextStyle, 20),
      shape: Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.2))),
    ),
    dialogTheme: dialog.copyWith(
      constraints: const BoxConstraints(maxWidth: 480),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: size(dialog.titleTextStyle, 18),
      contentTextStyle: size(dialog.contentTextStyle, 15, height: 1.5),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      behavior: SnackBarBehavior.floating,
      insetPadding: EdgeInsets.fromLTRB(24, 0, right, 24),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button(base.filledButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button(base.outlinedButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: button(base.textButtonTheme.style)),
    inputDecorationTheme: input.copyWith(
      hintStyle: size(input.hintStyle, 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: border(input.border),
      enabledBorder: border(input.enabledBorder),
      focusedBorder: border(input.focusedBorder),
    ),
  );
}

/// Puts the desktop theme over [child] when the window is a Linux desktop window; otherwise the theme above is passed through
/// unchanged. The tree has the same shape either way, so resizing across the line keeps the pages' state. [regionWidth] is the
/// width a snackbar is placed in (the window's when null).
class DesktopThemeScope extends StatelessWidget {
  const DesktopThemeScope({super.key, required this.child, this.regionWidth});

  final Widget child;
  final double? regionWidth;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final on = isLinuxDesktop(context);
    return Theme(
      data: on ? desktopTheme(base, regionWidth: regionWidth ?? MediaQuery.sizeOf(context).width) : base,
      child: child,
    );
  }
}
