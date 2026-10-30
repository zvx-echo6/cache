import 'dart:io';

import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pictures of real screens for people to look at (the owner's review renders, the guide's screenshots): the app's own widgets with
/// sample data, in the light theme, drawn with real fonts (the test default draws every letter as a box). Run with
/// `flutter test test_shots/<file> --update-goldens`; the pictures are written next to the file. Not part of the test suite.

bool _fonts = false;

/// Loads Roboto and the Material icons from the Flutter SDK's own copies (no font is added to the app).
Future<void> loadShotFonts() async {
  if (_fonts) return;
  final root = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  Future<void> family(String name, bool Function(String file) pick) async {
    final loader = FontLoader(name);
    for (final f in dir.listSync().whereType<File>().where((f) => pick(f.uri.pathSegments.last.toLowerCase()))) {
      final bytes = f.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await family('Roboto', (n) => n.startsWith('roboto-') && n.endsWith('.ttf'));
  await family('MaterialIcons', (n) => n.startsWith('materialicons'));
  _fonts = true;
}

/// The phone the pictures are drawn for: 430 x 932 points at 3x (1290 x 2796 pixels, an iPhone Pro Max), or [size] at [ratio].
void phone(WidgetTester tester, {Size size = const Size(430, 932), double ratio = 3}) {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
}

/// The light theme with every text style in Roboto (the phone's own font; a test draws a style with no family as boxes).
ThemeData shotTheme() {
  final t = buildTheme(CacheThemeId.light);
  TextStyle? r(TextStyle? x) => x?.copyWith(fontFamily: 'Roboto');
  ButtonStyle? b(ButtonStyle? st) {
    if (st == null) return null;
    final ts = st.textStyle;
    return st.copyWith(textStyle: ts == null ? null : WidgetStateProperty.resolveWith((s) => r(ts.resolve(s))));
  }

  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: 'Roboto'),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Roboto'),
    appBarTheme: t.appBarTheme.copyWith(titleTextStyle: r(t.appBarTheme.titleTextStyle)),
    dialogTheme: t.dialogTheme.copyWith(titleTextStyle: r(t.dialogTheme.titleTextStyle), contentTextStyle: r(t.dialogTheme.contentTextStyle)),
    // A test draws an elevation shadow as a hard black edge; the phone draws it soft. The pictures leave it out.
    snackBarTheme: t.snackBarTheme.copyWith(contentTextStyle: r(t.snackBarTheme.contentTextStyle), elevation: 0),
    filledButtonTheme: FilledButtonThemeData(style: b(t.filledButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: b(t.outlinedButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: b(t.textButtonTheme.style)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: b(t.elevatedButtonTheme.style)),
    inputDecorationTheme: t.inputDecorationTheme.copyWith(hintStyle: r(t.inputDecorationTheme.hintStyle)),
    navigationBarTheme: t.navigationBarTheme.copyWith(
      labelTextStyle: t.navigationBarTheme.labelTextStyle == null ? null : WidgetStateProperty.resolveWith((s) => r(t.navigationBarTheme.labelTextStyle!.resolve(s))),
    ),
  );
}

/// [page] in the app's light theme, as the phone shows it (a status bar's room at the top). Each call is a new app (a dialog left
/// open by the last picture is gone).
Widget shotApp(Widget page, {GlobalKey<ScaffoldMessengerState>? messenger}) => MaterialApp(
  key: UniqueKey(),
  debugShowCheckedModeBanner: false,
  scaffoldMessengerKey: messenger,
  theme: shotTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 54, bottom: 34), viewPadding: const EdgeInsets.only(top: 54, bottom: 34)),
    child: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
  ),
  home: page,
);

/// Writes (with --update-goldens) or checks the picture of the whole screen as [name].png in [folder].
Future<void> snap(WidgetTester tester, String folder, String name) async {
  await expectLater(find.byType(MaterialApp).first, matchesGoldenFile('$folder/$name.png'));
}
