// Sharing and sync, part A (1.1.0): the main screen (each kind one row with its switch, Sync all now), a kind's page (its
// switch, Sync all, every item with its own switch and Sync now) and a linked device's page (status, free space, Sync now,
// Rename, Unlink), opened from Settings as the app does, at 390, 820, 1180 and 1440 points wide, light and dark.
// flutter test test_shots/sharing_renders_test.dart --update-goldens  (pictures in test_shots/sharing/)

import 'dart:io';

import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'beta_sizes.dart';
import 'shot_kit.dart';

const _out = 'sharing';

/// The sizes drawn (the beta checklist's with BETA_SIZES, see beta_sizes.dart).
final Map<String, Size> _sizes = kBeta ? kBetaSizes : const {
  '390': Size(390, 844),
  '820': Size(820, 1180),
  '1180': Size(1180, 820),
  '1440': Size(1440, 900),
};

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, Size size, CacheThemeId theme) async {
  final ratio = kBeta ? betaRatio(size) : (size.width < 600 ? 3.0 : (size.width >= 1280 ? 1.0 : 2.0));
  phone(tester, size: size, ratio: ratio);
  final insets = kBeta ? betaInsets(size) : (size.width < 600 ? null : (size.width >= 1280 ? EdgeInsets.zero : const EdgeInsets.only(top: 24, bottom: 20)));
  await tester.pumpWidget(shotApp(page, theme: theme, insets: insets));
  await _settle(tester);
}

/// Brings [f] into view: built (scrolled to in the page's list, as a short window has it below the fold), then on screen.
Future<void> _reach(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 200, scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last);
  }
  await tester.ensureVisible(f);
}

const int _mb = 1 << 20;
const int _gb = 1 << 30;

void main() {
  setUpAll(loadShotFonts);

  for (final e in _sizes.entries) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('sharing ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        Directory dir(String name) => Directory('${r.dir.path}/share-$name')..createSync(recursive: true);
        final now = DateTime.now().millisecondsSinceEpoch;
        final sync = FakeSync()
          ..peers.addAll([
            {'id': 'peer1', 'name': 'Desk', 'linked': 1, 'last_seen': now - 120000, 'via': 'direct', 'error': null, 'free_bytes': 612 * _gb},
            {'id': 'peer2', 'name': 'Tablet', 'linked': 1, 'last_seen': now - 3600000, 'via': 'relay', 'error': null},
          ])
          // Desk holds Wikipedia, which this phone does not.
          ..items['library'] = [
            {'name': 'wikipedia_en_all_maxi_2026-10.zim', 'files': 0, 'bytes': 0, 'peers': [{'peer': 'peer1', 'peer_name': 'Desk', 'files': 1, 'bytes': (118.7 * _gb).round()}]},
          ];
        var privateOn = false;
        final kinds = [
          DataKind(
            id: 'library',
            label: 'Library',
            icon: Icons.menu_book_outlined,
            shared: () => {'library': dir('zims'), 'libraries': dir('libraries')},
            items: () => [
              const ShareItem(share: 'library', path: 'wikimed.zim', name: 'Medical encyclopedia', bytes: 1434 * _mb),
              const ShareItem(share: 'library', path: 'canning.zim', name: 'Home canning', bytes: 29 * _mb),
              const ShareItem(share: 'library', path: 'gutenberg.zim', name: 'Classic books', bytes: 235 * _mb),
              const ShareItem(share: 'libraries', path: 'preparedness', name: 'Preparedness guides', bytes: 1946 * _mb),
              const ShareItem(share: 'libraries', path: 'field-manuals', name: 'Field manuals', bytes: 7885 * _mb),
            ],
            remoteItem: (share, path, bytes) => path.startsWith('wikipedia') ? ShareItem(share: share, path: path, name: 'Wikipedia', bytes: bytes) : libraryRemoteItem(share, path, bytes),
          ),
          DataKind(
            id: 'regions',
            label: 'Regions',
            shareLabel: 'Maps',
            icon: Icons.map_outlined,
            shared: () => {'maps': dir('maps'), 'regions': dir('regions')},
            items: () => const [
              ShareItem(share: 'maps', path: 'store/streets.sqlite*', name: 'Streets', bytes: 1200 * _mb),
              ShareItem(share: 'maps', path: 'store/satellite.sqlite*', name: 'Satellite', bytes: 3100 * _mb),
              ShareItem(share: 'regions', path: '**', name: kDirectionsItemName, bytes: 740 * _mb),
            ],
            itemDepth: const {'maps': 2},
          ),
          DataKind(
            id: 'models',
            label: 'Models',
            icon: Icons.memory,
            shared: () => {'models': dir('models')},
            items: () => const [ShareItem(share: 'models', path: 'gemma.gguf', name: 'Gemma 4 E2B', bytes: 3200 * _mb)],
          ),
          DataKind(
            id: 'notebooks',
            label: 'Notebooks',
            icon: Icons.book_outlined,
            shared: () => {'notebooks': dir('notebooks')},
            items: () => [
              const ShareItem(share: 'notebooks', path: 'Journal', name: 'Journal', bytes: 14 << 10),
              const ShareItem(share: 'notebooks', path: 'Places', name: 'Places', bytes: 10 << 10),
              const ShareItem(share: 'notebooks', path: 'Repeaters', name: 'Repeaters', bytes: 6 << 10),
              ShareItem(share: 'notebooks', path: 'Health log', name: 'Health log', private: true, on: privateOn, bytes: 3 << 10),
            ],
            setPrivate: (it, on) async => privateOn = on,
          ),
          DataKind(
            id: 'videos',
            label: 'Videos and weather',
            shareLabel: 'Videos',
            icon: Icons.smart_display_outlined,
            shared: () => {'videos': dir('videos')},
            items: () => const [ShareItem(share: 'videos', path: 'downloads/v/1', name: 'Water purification', bytes: 310 * _mb)],
            itemDepth: const {'videos': 3},
          ),
        ];
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: kinds, deviceName: 'Test phone', opener: (_) async => sync);
        DataKind kind(String id) => kinds.firstWhere((k) => k.id == id);
        await tester.runAsync(() async {
          await sharing.setUp();
          for (final id in ['library', 'regions', 'notebooks']) {
            await sharing.setShared(kind(id), true);
          }
          await sharing.refreshItems();
          final lib = sharing.itemsOf(kind('library'));
          for (final name in ['Wikipedia', 'Classic books']) {
            await sharing.setItem(kind('library'), lib.firstWhere((i) => i.item.name == name).item, false);
          }
          await sharing.setItem(kind('regions'), sharing.itemsOf(kind('regions')).firstWhere((i) => i.item.name == 'Satellite').item, false);
          await sharing.setItem(kind('notebooks'), sharing.itemsOf(kind('notebooks')).firstWhere((i) => i.item.name == 'Repeaters').item, false);
        });
        r.hub = SettingsHub(
          sharing: sharing,
          settings: r.settings,
          policy: r.policy,
          webSearch: r.webSearch,
          storage: r.storage,
          weather: r.weather,
          openUrl: (u) async => r.opened.add(u),
        );

        Future<void> openSharing() async {
          await _show(tester, SettingsScreen(deps: r.deps), e.value, theme);
          final row = find.byKey(const ValueKey('settings-sharing'));
          await tester.ensureVisible(row);
          await tester.pump();
          await tester.tap(row);
          await _settle(tester);
        }

        // 1: the main screen
        await openSharing();
        await snap(tester, _out, '1-main-${e.key}-$t');

        // 2: a kind's page (Library)
        await _reach(tester, find.byKey(const ValueKey('share-library')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('share-library')));
        await _settle(tester);
        await snap(tester, _out, '2-kind-library-${e.key}-$t');

        // 3: a linked device's page (Desk)
        await openSharing();
        await _reach(tester, find.byKey(const ValueKey('peer-peer1')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('peer-peer1')));
        await _settle(tester);
        await snap(tester, _out, '3-device-${e.key}-$t');

        await _show(tester, const SizedBox(), e.value, theme);
        sharing.dispose();
        await r.dispose(tester);
      });
    }
  }
}
