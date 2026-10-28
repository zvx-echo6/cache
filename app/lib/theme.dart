import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The colour tokens of one theme. Screens read colours from here (via `context.t`) and never
/// hard-code them.
@immutable
class CacheTokens extends ThemeExtension<CacheTokens> {
  const CacheTokens({
    required this.background,
    required this.surface,
    required this.text,
    required this.secondary,
    required this.accent,
    required this.emergency,
    required this.warning,
    required this.ok,
  });

  final Color background;
  final Color surface;
  final Color text;
  final Color secondary;
  final Color accent;
  final Color emergency;
  final Color warning;
  final Color ok;

  @override
  CacheTokens copyWith({
    Color? background,
    Color? surface,
    Color? text,
    Color? secondary,
    Color? accent,
    Color? emergency,
    Color? warning,
    Color? ok,
  }) =>
      CacheTokens(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        text: text ?? this.text,
        secondary: secondary ?? this.secondary,
        accent: accent ?? this.accent,
        emergency: emergency ?? this.emergency,
        warning: warning ?? this.warning,
        ok: ok ?? this.ok,
      );

  @override
  CacheTokens lerp(ThemeExtension<CacheTokens>? other, double t) {
    if (other is! CacheTokens) return this;
    return CacheTokens(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      text: Color.lerp(text, other.text, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      emergency: Color.lerp(emergency, other.emergency, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
    );
  }
}

extension CacheTokensContext on BuildContext {
  CacheTokens get t => Theme.of(this).extension<CacheTokens>()!;
}

enum CacheThemeId { dark, light, parchment, tactical }

extension CacheThemeIdInfo on CacheThemeId {
  String get label => switch (this) {
        CacheThemeId.dark => 'Dark',
        CacheThemeId.light => 'Light',
        CacheThemeId.parchment => 'Parchment',
        CacheThemeId.tactical => 'Tactical',
      };

  String get hint => switch (this) {
        CacheThemeId.dark => 'Default',
        CacheThemeId.light => 'Bright, for indoors',
        CacheThemeId.parchment => 'Warm paper, easy reading in daylight',
        CacheThemeId.tactical => 'Red on black, protects night vision',
      };

  bool get isLight => this == CacheThemeId.light || this == CacheThemeId.parchment;
}

const Map<CacheThemeId, CacheTokens> cacheTokens = {
  CacheThemeId.dark: CacheTokens(
    background: Color(0xFF0F1115),
    surface: Color(0xFF1A1D23),
    text: Color(0xFFE8EAED),
    secondary: Color(0xFF8A9099),
    accent: Color(0xFF6BB4DE),
    emergency: Color(0xFFFF6B5E),
    warning: Color(0xFFE0B45A),
    ok: Color(0xFF5FB98A),
  ),
  CacheThemeId.light: CacheTokens(
    background: Color(0xFFF7F7F5),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF15171A),
    secondary: Color(0xFF5C636E),
    accent: Color(0xFF1F6FA8),
    emergency: Color(0xFFC62E24),
    warning: Color(0xFF8A5A00),
    ok: Color(0xFF1E7A4B),
  ),
  CacheThemeId.parchment: CacheTokens(
    background: Color(0xFFF3E9D2),
    surface: Color(0xFFEADCBE),
    text: Color(0xFF2B2118),
    secondary: Color(0xFF6B5A45),
    accent: Color(0xFF7A4E1D),
    emergency: Color(0xFFA3261C),
    warning: Color(0xFF8A5A00),
    ok: Color(0xFF3F6B2E),
  ),
  CacheThemeId.tactical: CacheTokens(
    background: Color(0xFF000000),
    surface: Color(0xFF120404),
    text: Color(0xFFE0473C),
    secondary: Color(0xFF8E2B24),
    accent: Color(0xFFFF5A4A),
    emergency: Color(0xFFFF2D1F),
    warning: Color(0xFFC24A1E),
    ok: Color(0xFFB23A2E),
  ),
};

ThemeData buildTheme(CacheThemeId id) {
  final k = cacheTokens[id]!;
  final brightness = id.isLight ? Brightness.light : Brightness.dark;
  // Text and icons on top of the accent colour.
  final onAccent = k.background;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: k.accent,
    onPrimary: onAccent,
    primaryContainer: k.surface,
    onPrimaryContainer: k.text,
    secondary: k.accent,
    onSecondary: onAccent,
    secondaryContainer: k.surface,
    onSecondaryContainer: k.text,
    tertiary: k.accent,
    onTertiary: onAccent,
    error: k.emergency,
    onError: onAccent,
    surface: k.background,
    onSurface: k.text,
    onSurfaceVariant: k.secondary,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: k.background,
    surfaceContainerLow: k.surface,
    surfaceContainer: k.surface,
    surfaceContainerHigh: k.surface,
    surfaceContainerHighest: k.surface,
    outline: k.secondary,
    outlineVariant: k.surface,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: k.text,
    onInverseSurface: k.background,
    inversePrimary: k.accent,
  );

  final base = ThemeData(brightness: brightness, useMaterial3: true);
  final textTheme = base.textTheme.apply(bodyColor: k.text, displayColor: k.text).copyWith(
        bodyLarge: TextStyle(fontSize: 18, height: 1.4, color: k.text),
        bodyMedium: TextStyle(fontSize: 17, height: 1.4, color: k.text),
        bodySmall: TextStyle(fontSize: 14, color: k.secondary),
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text),
        titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text),
        labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text),
      );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: k.background,
    canvasColor: k.background,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    iconTheme: IconThemeData(color: k.text),
    dividerColor: k.surface,
    splashFactory: InkRipple.splashFactory,
    extensions: [k],
    appBarTheme: AppBarTheme(
      backgroundColor: k.background,
      foregroundColor: k.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      iconTheme: IconThemeData(color: k.text),
      systemOverlayStyle: overlayFor(id),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: k.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: k.accent.withValues(alpha: 0.25),
      height: 72,
      iconTheme: WidgetStateProperty.resolveWith((s) =>
          IconThemeData(size: 26, color: s.contains(WidgetState.selected) ? k.accent : k.secondary)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected) ? k.accent : k.secondary,
          )),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: k.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleMedium,
      contentTextStyle: textTheme.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: k.surface,
      surfaceTintColor: Colors.transparent,
      textStyle: textTheme.bodyMedium,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: k.surface,
      contentTextStyle: TextStyle(fontSize: 16, color: k.text),
      actionTextColor: k.accent,
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: k.accent,
      linearTrackColor: k.surface,
      circularTrackColor: k.surface,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: k.accent,
      selectionColor: k.accent.withValues(alpha: 0.35),
      selectionHandleColor: k.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: k.surface,
      hintStyle: TextStyle(fontSize: 17, color: k.secondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide(color: k.accent)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: k.accent,
        foregroundColor: onAccent,
        minimumSize: const Size(48, 52),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: k.accent,
        side: BorderSide(color: k.secondary),
        minimumSize: const Size(48, 52),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: k.accent, minimumSize: const Size(48, 48)),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStatePropertyAll(k.accent)),
    listTileTheme: ListTileThemeData(
      iconColor: k.secondary,
      textColor: k.text,
      subtitleTextStyle: TextStyle(fontSize: 15, color: k.secondary),
    ),
  );
}

/// Status bar / navigation bar styling. Android can only draw white or dark icons, so the
/// Tactical theme hides the bars entirely (see [applySystemUi]) and this style is a fallback.
SystemUiOverlayStyle overlayFor(CacheThemeId id) {
  final k = cacheTokens[id]!;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: id.isLight ? Brightness.dark : Brightness.light,
    statusBarBrightness: id.isLight ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: k.surface,
    systemNavigationBarIconBrightness: id.isLight ? Brightness.dark : Brightness.light,
    systemNavigationBarDividerColor: k.surface,
  );
}

/// Tactical hides the system bars (their white icons would break night vision); swipe from the
/// edge to bring them back for a moment. Other themes show them normally.
void applySystemUi(CacheThemeId id) {
  if (id == CacheThemeId.tactical) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } else {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  SystemChrome.setSystemUIOverlayStyle(overlayFor(id));
}
