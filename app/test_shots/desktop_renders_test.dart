// The 1.0.30 desktop width class for the owner to review, drawn by the app itself with sample data (no personal data): windows
// of 1920 x 1080 and 1440 x 900, and a 12.9" iPad Pro held sideways (1366 x 1024), all in the desktop class (1280 and wider).
// flutter test test_shots/desktop_renders_test.dart --update-goldens  (pictures in test_shots/desktop/)

import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/sources/sources_state.dart' show ZimFile;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show catalogWith, fixture, testPolicy;
import '../test/nav_fakes.dart';
import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'desktop';

const Map<String, Size> kDesktops = {
  '1920x1080': Size(1920, 1080),
  '1440x900': Size(1440, 900),
  'ipad-pro-landscape-1366x1024': Size(1366, 1024),
};

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, Size size, {CacheThemeId theme = CacheThemeId.light}) async {
  phone(tester, size: size, ratio: 1);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: EdgeInsets.zero));
  await _settle(tester);
}

/// Kiwix's catalogue as sample data: sixteen collections (no icons, so nothing is fetched).
const List<(String, String, String, int)> _collections = [
  ('wikipedia_en_all', 'Wikipedia (English)', 'All articles, no images', 105 << 30),
  ('wikimed_en', 'WikiMed', 'Medical encyclopedia', 2200 << 20),
  ('wikipedia_en_simple', 'Wikipedia (Simple English)', 'Simplified articles', 3800 << 20),
  ('where_there_is_no_doctor', 'Where There Is No Doctor', 'Village health care guide', 24 << 20),
  ('appropedia_en', 'Survival and preparedness guides', 'Appropedia and field manuals', 5100 << 20),
  ('outdoors_stackexchange', 'Outdoors Stack Exchange', 'Questions and answers', 1500 << 20),
  ('wikibooks_en', 'Wikibooks (English)', 'Open textbooks', 3100 << 20),
  ('wikivoyage_en', 'Wikivoyage (English)', 'Travel guides', 1200 << 20),
  ('gardening_stackexchange', 'Gardening Stack Exchange', 'Questions and answers', 960 << 20),
  ('cooking_stackexchange', 'Cooking Stack Exchange', 'Questions and answers', 640 << 20),
  ('electronics_stackexchange', 'Electronics Stack Exchange', 'Questions and answers', 4500 << 20),
  ('ifixit_en', 'iFixit repair guides', 'Step-by-step repairs', 1800 << 20),
  ('gutenberg_en', 'Project Gutenberg', 'Public-domain books', 70 << 30),
  ('khanacademy_en', 'Khan Academy lessons', 'Video-free lessons', 13 << 30),
  ('wiktionary_en', 'Wiktionary (English)', 'Dictionary', 8 << 30),
  ('wikisource_en', 'Wikisource (English)', 'Source texts', 12 << 30),
];

String _feed() {
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">'
      '<id>sample</id><title>Entries</title><totalResults>${_collections.length}</totalResults><startIndex>0</startIndex><itemsPerPage>${_collections.length}</itemsPerPage>');
  var n = 0;
  for (final (name, title, summary, bytes) in _collections) {
    n++;
    final id = '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
    b.write('<entry><id>urn:uuid:$id</id><title>$title</title><updated>2026-10-01T00:00:00Z</updated><summary>$summary</summary>'
        '<language>eng</language><name>$name</name><flavour>maxi</flavour><category>other</category><tags>_category:other</tags>'
        '<articleCount>1000</articleCount><dc:issued>2026-10-01T00:00:00Z</dc:issued>'
        '<link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://example.invalid/$name.zim" length="$bytes"/></entry>');
  }
  b.write('</feed>');
  return b.toString();
}

Future<String> _catalogue(Uri u) async {
  if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
  if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
  return _feed();
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets('desktop: Library on Add to Library, Settings, Ask', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final libsDir = Directory('${r.dir.path}/libraries')..createSync();
    final libs = LibrariesState(sources: r.sources, dirOverride: libsDir);
    final browse = BrowseState(
      sources: r.sources,
      catalog: catalogWith(_catalogue),
      policy: testPolicy(),
      libraries: libs,
      settingsDirOverride: r.dir,
      iconFetch: (_) async => null,
      phoneLanguage: 'en',
    );
    await tester.runAsync(browse.init);
    final zims = r.sources.zimsDir!.path;
    r.sources.zims = [
      ZimFile(path: '$zims/wikipedia_en_all_maxi_2026-02.zim', size: 105 << 30),
      ZimFile(path: '$zims/wikimed_en_all_maxi_2026-01.zim', size: 2200 << 20),
      ZimFile(path: '$zims/appropedia_en_all_maxi_2026-03.zim', size: 5100 << 20),
      ZimFile(path: '$zims/outdoors.stackexchange.com_en_all_2026-02.zim', size: 1500 << 20),
    ];
    r.sources.titles
      ..['$zims/wikipedia_en_all_maxi_2026-02.zim'] = 'Wikipedia (English)'
      ..['$zims/wikimed_en_all_maxi_2026-01.zim'] = 'WikiMed'
      ..['$zims/appropedia_en_all_maxi_2026-03.zim'] = 'Survival and preparedness guides'
      ..['$zims/outdoors.stackexchange.com_en_all_2026-02.zim'] = 'Outdoors Stack Exchange';
    final nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));

    final chat = r.chat;
    chat.messages
      ..add(ChatMessage.user('How do I make water from a stream safe to drink?'))
      ..add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'Bring it to a rolling boil for one minute [1]. Above 6,500 feet, boil it for three minutes, because water boils at a '
            'lower temperature as you climb [2]. Let it cool before you drink it, and keep it covered in a clean container. If you '
            'cannot boil it, filter out what you can see through a clean cloth first, then use purification tablets as their '
            'packet says; they need time to work, often 30 minutes or more in cold water.'
        ..sources = const [
          NumberedResult(1, SourceResult(title: 'Water purification', snippet: 'Boiling kills germs: bring the water to a rolling boil for one minute.', address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Water_purification')),
          NumberedResult(2, SourceResult(title: 'Boiling at altitude', snippet: 'Water boils at a lower temperature as you climb.', address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Boiling_point')),
        ]);

    Widget shell() => Shell(app: r.app, chat: chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: browse, nav: nav, layout: layout, hub: r.hub);

    for (final e in kDesktops.entries) {
      for (final theme in [CacheThemeId.light, if (e.key == '1920x1080') CacheThemeId.dark]) {
        final t = theme == CacheThemeId.dark ? '-dark' : '';
        // Library with nothing chosen opens on Add to Library: Your own on the left, the catalogue two to a row on the right.
        await _show(tester, shell(), e.value, theme: theme);
        await tester.tap(find.text('Library').first);
        await _settle(tester);
        await snap(tester, _out, '${e.key}-library-add$t');
        // Settings: the list 380, the page beside it.
        await _show(tester, SettingsScreen(deps: r.deps), e.value, theme: theme);
        await snap(tester, _out, '${e.key}-settings$t');
        // Ask: the conversation kept to a reading width.
        await _show(tester, AskScreen(app: r.app, chat: chat, location: r.location, layout: layout, onOpenSource: (_) {}, onOpenNavigation: (_) {}), e.value, theme: theme);
        await snap(tester, _out, '${e.key}-ask$t');
      }
    }

    await _show(tester, const SizedBox(), const Size(1920, 1080));
    nav.dispose();
    browse.dispose();
    layout.dispose();
    await r.dispose(tester);
  });
}
