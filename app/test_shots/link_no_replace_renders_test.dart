// Design renders for "Don't replace my copies from this device" (a per-link switch planned for 1.1; nothing here is built yet):
// (1) a linked device's page with the switch off and on, (2) a Library ZIM row with "Newer copy on Pixel · Get it",
// (3) the Notebooks list with a "Journal (from Pixel)" side copy. The app's own widgets, sample data; the page's switch row is
// drawn only when a render passes SharingDevicePage.noReplacePreview (null everywhere in the app). 390 and 1440 points wide,
// light, dark and Tactical.
// flutter test test_shots/link_no_replace_renders_test.dart --update-goldens  (pictures in test_shots/link_no_replace/)

import 'dart:io';

import 'package:cache/browse/browse_screen.dart' show LibraryRow;
import 'package:cache/layout/adaptive.dart' show ContentWidth;
import 'package:cache/layout/layout_state.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/templates.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart' show NotebookDeps;
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sharing/synced_settings.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'link_no_replace';

const Map<String, Size> _sizes = {'390': Size(390, 844), '1440': Size(1440, 900)};
const Map<CacheThemeId, String> _themes = {CacheThemeId.light: 'light', CacheThemeId.dark: 'dark', CacheThemeId.tactical: 'tactical'};

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, Size size, CacheThemeId theme) async {
  final ratio = size.width < 600 ? 3.0 : 1.0;
  phone(tester, size: size, ratio: ratio);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: size.width < 600 ? null : EdgeInsets.zero));
  await _settle(tester);
}

Templates _templates() => Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync());

void main() {
  setUpAll(loadShotFonts);

  for (final e in _sizes.entries) {
    for (final th in _themes.entries) {
      final t = th.value;

      testWidgets('device page ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final now = DateTime.now().millisecondsSinceEpoch;
        final sync = FakeSync()
          ..peers.add({'id': 'peer1', 'name': 'Pixel', 'linked': 1, 'last_seen': now - 120000, 'via': 'direct', 'error': null, 'free_bytes': 48 << 30, 'link_known': true, 'link': {'mode': 'match'}});
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], deviceName: 'Test phone', opener: (_) async => sync);
        final layout = LayoutState(settingsDirOverride: r.dir);
        final settingsSync = SettingsSync(
          sharing: sharing,
          settings: appSyncedSettings(app: r.app, layout: layout, settings: r.settings, maps: r.maps, weather: r.weather),
          keys: () => const [],
          storeKey: (_, _) async => false,
          dir: () async => Directory('${r.dir.path}/$kSettingsShareDir'),
          every: const Duration(hours: 1),
        );
        await tester.runAsync(() async {
          await layout.init();
          await sharing.setUp();
          await settingsSync.start();
        });
        for (final on in [false, true]) {
          await _show(tester, SharingDevicePage(sharing: sharing, peer: 'peer1', settingsSync: settingsSync, noReplacePreview: on), e.value, th.key);
          await snap(tester, _out, '1-device-${on ? 'on' : 'off'}-${e.key}-$t');
        }
        await _show(tester, const SizedBox(), e.value, th.key);
        settingsSync.dispose();
        sharing.dispose();
        layout.dispose();
        await r.dispose(tester);
      });

      testWidgets('zim row ${e.key} $t', (tester) async {
        Widget below(BuildContext c) => InkWell(
          key: const ValueKey('zim-newer'),
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('Newer copy on Pixel · Get it', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.t.accent)),
          ),
        );
        await _show(
          tester,
          Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('ZIM Collections')),
              body: ContentWidth(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    LibraryRow(title: 'Wikipedia', detail: 'English, no pictures · 38.2 GB', below: below(context), onTap: () {}),
                    LibraryRow(title: 'Wikivoyage', detail: 'English · 1.1 GB', onTap: () {}),
                    LibraryRow(title: 'Wikimed', detail: 'English · 2.4 GB', onTap: () {}),
                  ],
                ),
              ),
            ),
          ),
          e.value,
          th.key,
        );
        await snap(tester, _out, '2-zim-row-${e.key}-$t');
      });

      testWidgets('notebooks ${e.key} $t', (tester) async {
        final store = FakeNotebookBackend();
        final nb = fakeNotebook(store);
        await tester.runAsync(() async {
          await nb.start();
          await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Journal (from Pixel)', fields: [], sort: NotebookSort.recent), map: false);
          await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Family plan', fields: [], sort: NotebookSort.recent), map: false);
        });
        const places = PlaceChoices(here: _home, saved: _saved);
        final deps = NotebookDeps(notebook: nb, places: places, now: () => DateTime(2026, 10, 29, 16, 12));
        await _show(tester, NotebooksScreen(deps: deps, templates: _templates()), e.value, th.key);
        await snap(tester, _out, '3-notebooks-${e.key}-$t');
      });
    }
  }
}

Future<({double lat, double lon})?> _home() async => (lat: 43.615, lon: -116.202);
Future<List<NbPlace>> _saved() async => const [];
