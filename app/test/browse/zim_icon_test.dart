// A ZIM's icon in the Library: the saved one, else the ZIM's own (cached beside it), else a letter; and in Tactical (a single-hue
// theme) the picture is drawn in that hue while a full-colour theme leaves it alone.

import 'dart:io';

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/sources/sources_state.dart' show ZimFile;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Widget app(Widget child, [CacheThemeId theme = CacheThemeId.dark]) => MaterialApp(key: UniqueKey(), theme: buildTheme(theme), home: child);

void main() {
  late Directory tmp;
  late FakeSources sources;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zimicon');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> recorded(Uri u) async {
    if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
    if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
    return fixture('kiwix_entries_wikivoyage.xml');
  }

  BrowseState make() => BrowseState(
    sources: sources,
    catalog: catalogWith(recorded),
    policy: testPolicy(),
    settingsDirOverride: Directory('${tmp.path}/s')..createSync(),
    phoneLanguage: 'en',
  );

  testWidgets('a ZIM with no saved icon shows its own; one with neither keeps its letter; a saved icon wins', (tester) async {
    final z = sources.zimsDir!.path;
    sources.zims = [
      ZimFile(path: '$z/saved.zim', size: 10),
      ZimFile(path: '$z/own.zim', size: 10),
      ZimFile(path: '$z/plain.zim', size: 10),
    ];
    for (final f in sources.zims) {
      sources.titles[f.path] = f.name;
      sources.ready.add(f.path);
    }
    File('$z/saved.zim.icon.png').writeAsBytesSync([1]);
    File('$z/saved.zim.illustration.png').writeAsBytesSync([2]);
    File('$z/own.zim.illustration.png').writeAsBytesSync([3]);

    final b = make();
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(BrowseScreen(browse: b, active: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-zims')));
    await tester.pumpAndSettle();

    File? iconOf(String name) => tester.widget<LetterIcon>(find.descendant(of: find.byKey(ValueKey('zim-$name.zim')), matching: find.byType(LetterIcon))).file;
    expect(iconOf('saved')?.path, '$z/saved.zim.icon.png', reason: 'the saved icon is kept over the ZIM\'s own');
    expect(iconOf('own')?.path, '$z/own.zim.illustration.png');
    expect(iconOf('plain'), isNull, reason: 'a ZIM with no picture at all is a letter');
    expect(find.text('P'), findsOneWidget);
    expect(find.text('Each opens in the reader. Icons come from each source; change one from the hold menu.'), findsOneWidget);
  });

  testWidgets('the ZIM icons are drawn in the theme\'s one hue in Tactical and left in colour elsewhere; letters and others are not tinted', (tester) async {
    final z = sources.zimsDir!.path;
    sources.zims = [ZimFile(path: '$z/own.zim', size: 10)];
    sources.titles['$z/own.zim'] = 'Own';
    sources.ready.add('$z/own.zim');
    File('$z/own.zim.illustration.png').writeAsBytesSync([3]);
    final b = make();
    await tester.runAsync(b.init);

    Finder tinted() => find.descendant(of: find.byKey(const ValueKey('zim-own.zim')), matching: find.byType(ColorFiltered));
    for (final (theme, expected) in [(CacheThemeId.tactical, 1), (CacheThemeId.dark, 0), (CacheThemeId.light, 0)]) {
      await tester.pumpWidget(app(BrowseScreen(browse: b, active: true), theme));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-zims')));
      await tester.pumpAndSettle();
      expect(tinted(), findsNWidgets(expected), reason: theme.name);
    }

    // The same picture drawn as something other than a ZIM icon is left in colour, whatever the theme.
    await tester.pumpWidget(app(LetterIcon(title: 'Own', file: File('$z/own.zim.illustration.png')), CacheThemeId.tactical));
    expect(find.byType(ColorFiltered), findsNothing);
  });
}
