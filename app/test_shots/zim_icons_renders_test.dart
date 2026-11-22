// ZIM Collections with a mix of icons, and the hold menu with "Get icon from source", for review: a picture saved at download (full
// colour), a ZIM's own illustration (the fallback, cached beside the ZIM) and a letter tile, at 390 and 1440 wide in the dark, Tactical
// and light themes. The menu shows "Get icon from source" after "Change icon" with a stand-in action: the app gives that item to
// no menu yet (LibraryActions.getIcon is null everywhere), so this is only how it would look.
// flutter test test_shots/zim_icons_renders_test.dart --update-goldens  (pictures in test_shots/zim_icons/)

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/library_actions.dart';
import 'package:cache/sources/sources_state.dart' show ZimFile;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show FakeSources, catalogWith, fixture, testPolicy;
import 'shot_kit.dart';

const _out = 'zim_icons';

/// A 96 x 96 picture in full colour: a diagonal blend of [a] and [b] with a white disc.
Future<List<int>> _png(Color a, Color b) async {
  const s = 96.0;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, s, s), Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(s, s), [a, b]));
  c.drawCircle(const Offset(s / 2, s / 2), s * 0.26, Paint()..color = Colors.white);
  final img = await rec.endRecording().toImage(s.toInt(), s.toInt());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<String> _catalogue(Uri u) async {
  if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
  if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
  return fixture('kiwix_entries_wikivoyage.xml');
}

void main() {
  late Directory tmp;
  late FakeSources sources;

  setUpAll(loadShotFonts);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zimicons');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Decodes the pictures on screen (a test does not wait for a file to load by itself).
  Future<void> loadPictures(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        await precacheImage((e.widget as Image).image, e);
      }
    });
    await tester.pump();
  }

  for (final size in const {'390': Size(390, 844), '1440': Size(1440, 900)}.entries) {
    for (final theme in const [CacheThemeId.dark, CacheThemeId.tactical, CacheThemeId.light]) {
      testWidgets('ZIM Collections with mixed icons, ${size.key}, ${theme.name}', (tester) async {
        phone(tester, size: size.value, ratio: size.key == '390' ? 2 : 1);
        final z = sources.zimsDir!.path;
        sources.zims = [
          ZimFile(path: '$z/wikipedia_en_all_maxi_2026-02.zim', size: 118 << 30),
          ZimFile(path: '$z/field_manuals_2026-03.zim', size: 7700 << 20),
          ZimFile(path: '$z/cooking_notes_2026-01.zim', size: 29 << 20),
        ];
        for (final (i, t) in ['Wikipedia', 'Field manuals', 'Cooking notes'].indexed) {
          sources.titles[sources.zims[i].path] = t;
          sources.ids[sources.zims[i].path] = 'u$i';
          sources.ready.add(sources.zims[i].path);
        }
        await tester.runAsync(() async {
          // saved at download time, from the catalogue
          File('${sources.zims[0].path}.icon.png').writeAsBytesSync(await _png(const Color(0xFFD9534F), const Color(0xFF3B6EA8)));
          // read from the ZIM itself, cached beside it
          File('${sources.zims[1].path}.illustration.png').writeAsBytesSync(await _png(const Color(0xFF3E9B5C), const Color(0xFFE8B13A)));
          // the third has neither: a letter
        });
        final b = BrowseState(
          sources: sources,
          catalog: catalogWith(_catalogue),
          policy: testPolicy(),
          settingsDirOverride: Directory('${tmp.path}/s')..createSync(),
          iconFetch: (_) async => null,
          phoneLanguage: 'en',
        );
        await tester.runAsync(b.init);
        await tester.pumpWidget(shotApp(BrowseScreen(browse: b, active: true), theme: theme, insets: const EdgeInsets.only(top: 44, bottom: 30)));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('library-zims')));
        await settle(tester);
        await loadPictures(tester);
        await snap(tester, _out, '${size.key}-zims-${theme.name}');
      });
    }
  }

  for (final theme in const [CacheThemeId.light, CacheThemeId.tactical]) {
    testWidgets('the hold menu with Get icon from source, 390, ${theme.name}', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 2);
      await tester.pumpWidget(shotApp(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showLibraryMenu(
                  context,
                  LibraryActions(
                    title: 'Wikipedia',
                    bytes: 118 << 30,
                    free: 90 << 30,
                    checkUpdate: () async {},
                    changeIcon: () async {},
                    getIcon: () async {},
                    addToHome: () {},
                    delete: () async {},
                  ),
                ),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
        theme: theme,
        insets: const EdgeInsets.only(top: 44, bottom: 30),
      ));
      await settle(tester);
      await tester.tap(find.text('Open menu'));
      await settle(tester);
      expect(find.text('Get icon from source'), findsOneWidget);
      await snap(tester, _out, '390-menu-${theme.name}');
    });
  }
}
