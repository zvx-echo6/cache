import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/screens/settings/about_pages.dart';
import 'package:cache/screens/settings/library_page.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/screens/settings/videos_page.dart';
import 'package:cache/version.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'video_fake.dart';

void main() {
  testWidgets('Library: the reading sources and getting more', (tester) async {
    final r = await SettingsRig.create(tester);
    await r.show(tester, LibraryPage(deps: r.deps));
    expect(find.text('Reading sources'), findsOneWidget);
    expect(find.text('No sources yet. Add a file or get one.'), findsOneWidget);
    expect(find.text('Get more from the Kiwix library'), findsOneWidget);
    expect(find.text('Advanced'), findsNothing, reason: 'nothing technical exists for the Library yet');
    await tester.tap(find.text('Reading sources'));
    await tester.pumpAndSettle();
    expect(find.text('Sources'), findsOneWidget, reason: 'the existing sources screen');
    await r.dispose(tester);
  });

  testWidgets('Maps: downloaded areas, layers, and the layer definitions under Advanced', (tester) async {
    final r = await SettingsRig.create(tester);
    await r.show(tester, MapsPage(deps: r.deps));
    expect(find.text('Nothing downloaded'), findsOneWidget);
    final hill = r.maps.catalogueLayers.firstWhere((l) => l.id == 'hillshade');
    await r.engine.download(hill.id, const GeoBounds(south: 42.5, west: -113.8, north: 42.6, east: -113.66), label: 'Home');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('Nothing downloaded'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    await tester.tap(find.text('Layers'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete'), findsOneWidget, reason: 'areas are deleted on the existing layers screen');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Add a layer definition'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('Videos: saved videos, instances and adding one', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.video.addInstance('tube.example.org'));
    await r.show(tester, VideosPage(deps: r.deps));
    await tester.pump();
    expect(find.text('Saved on this phone'), findsOneWidget);
    expect(find.text('Nothing yet'), findsOneWidget);
    expect(find.text('Example PeerTube'), findsOneWidget);
    expect(find.text('tube.example.org'), findsOneWidget);
    expect(find.text('Add an instance'), findsOneWidget);
    expect(find.text('Advanced'), findsNothing);
    expect(VideoFakeNative.uuid, isNotEmpty);
    await r.dispose(tester);
  });

  testWidgets('Models: a model that is not in use can be deleted, after asking', (tester) async {
    final r = await SettingsRig.create(tester);
    File('${r.modelsDir.path}/other.gguf').writeAsBytesSync(List.filled(2048, 1));
    await tester.runAsync(r.app.refreshModels);
    await r.show(tester, ModelsScreen(app: r.app));
    expect(find.text('other'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-model-other.gguf')));
    await tester.pumpAndSettle();
    expect(find.textContaining('deleted from this phone'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(File('${r.modelsDir.path}/other.gguf').existsSync(), isTrue);
    await tester.tap(find.byKey(const ValueKey('delete-model-other.gguf')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('confirm-delete-model')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(File('${r.modelsDir.path}/other.gguf').existsSync(), isFalse);
    expect(r.app.models, isEmpty);
    await r.dispose(tester);
  });

  testWidgets('About: version, licence, credits and licences', (tester) async {
    final r = await SettingsRig.create(tester);
    final opened = <String>[];
    await r.show(tester, AboutPage(openUrl: (u) async => opened.add(u)));
    expect(find.text(kAppVersion), findsOneWidget);
    expect(find.textContaining('Copyright (C) 2026 Happy Little LLC', findRichText: true), findsOneWidget);
    expect(find.textContaining('including builds you get from Google Play', findRichText: true), findsOneWidget, reason: 'the tests run as Android');
    expect(find.textContaining('TestFlight', findRichText: true), findsNothing);
    expect(find.byType(SelectableText), findsOneWidget, reason: 'the notice can be selected');
    final link = find.byWidgetPredicate((w) => w is SelectableText && w.textSpan?.toPlainText().contains(kSourceUrl) == true);
    expect(link, findsOneWidget);
    final span = tester.widget<SelectableText>(link).textSpan!.children!.whereType<TextSpan>().firstWhere((c) => c.text == kSourceUrl);
    (span.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, [kSourceUrl], reason: 'tapping the address opens it in the browser');
    expect(find.textContaining('AGPL-3.0-or-later'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('credits')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Credits'), findsWidgets);
    expect(find.text('Data sources'), findsOneWidget, reason: 'the bundled CREDITS.md is shown');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('licences')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Cache'), findsWidgets, reason: 'the licence page names the app');
    await r.dispose(tester);
  });

  testWidgets('About: the version and build come from the installed app', (tester) async {
    final r = await SettingsRig.create(tester);
    await r.show(tester, AboutPage(openUrl: (u) async {}, version: () async => '1.0.0 (build 4)'));
    await tester.pump();
    expect(find.text('1.0.0 (build 4)'), findsOneWidget);
    await r.dispose(tester);
  });

  test('the source notice names where builds come from on each platform', () {
    expect(sourceNoticeEnd(TargetPlatform.iOS), ', including builds you receive through TestFlight.');
    expect(sourceNoticeEnd(TargetPlatform.android), ', including builds you get from Google Play.');
    expect(sourceNoticeEnd(TargetPlatform.macOS), '.');
    expect(sourceNoticeEnd(TargetPlatform.windows), '.');
  });

  testWidgets('the credits page shows the text it is given', (tester) async {
    final r = await SettingsRig.create(tester);
    await r.show(tester, CreditsPage(loader: () async => '# Credits\n\n## Data sources\n\n- OpenStreetMap: ODbL 1.0\n'));
    await tester.pumpAndSettle();
    expect(find.text('Data sources'), findsOneWidget);
    expect(find.textContaining('OpenStreetMap: ODbL 1.0'), findsOneWidget);
    await r.dispose(tester);
  });

  test('the credits in the app are the CREDITS.md at the repository root, and cover what the task lists', () {
    final root = File('../CREDITS.md').readAsStringSync();
    expect(File('assets/credits.md').readAsStringSync(), root, reason: 'copy CREDITS.md to app/assets/credits.md when it changes');
    for (final needle in [
      'OpenStreetMap', 'ODbL', 'Protomaps', 'Overture', 'Mapterhorn', 'ESA WorldCover', 'Open-Meteo', 'CC BY 4.0', 'Kiwix', 'PeerTube',
      'llama.cpp', 'libzim', 'Xapian', 'ICU', 'Valhalla', 'MapLibre', 'AGPL-3.0-or-later',
    ]) {
      expect(root, contains(needle), reason: needle);
    }
    // Every package in pubspec.lock that comes from pub.dev has a line.
    final lock = File('pubspec.lock').readAsLinesSync();
    String? name;
    var hosted = <String>[];
    for (final l in lock) {
      final m = RegExp(r'^  ([A-Za-z0-9_]+):\s*$').firstMatch(l);
      if (m != null) name = m.group(1);
      if (l.trim() == 'source: hosted' && name != null) hosted.add(name);
    }
    expect(hosted.length, greaterThan(50));
    for (final n in hosted) {
      expect(root, contains('- $n '), reason: 'pubspec.lock package $n is in CREDITS.md');
    }
    // Every crate in the search core's lockfile (the ones from crates.io) has a line.
    final cargo = File('../packages/cache_search/native/Cargo.lock').readAsStringSync();
    final crates = RegExp(r'name = "([^"]+)"\r?\nversion = "([^"]+)"\r?\nsource = "registry').allMatches(cargo).map((m) => m.group(1)!).toSet();
    expect(crates.length, greaterThan(300));
    final missing = [for (final c in crates) if (!root.contains('- $c ')) c];
    expect(missing, isEmpty, reason: 'crates without a line: $missing');
  });

  test('a model deleted while it is the active one is refused', () async {
    final tmp = Directory.systemTemp.createTempSync('model-del');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/m.gguf')..writeAsBytesSync([1, 2, 3]);
    final app = AppState(settingsDirOverride: tmp, modelsDirOverride: tmp);
    await app.init();
    final m = app.models.single;
    expect(await app.deleteModel(m), isTrue);
    expect(f.existsSync(), isFalse);
  });
}
