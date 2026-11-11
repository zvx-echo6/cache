// Settings link question (1.1.0, owner's two-phone test): one question for the PAIR (Match both ways, Send mine, Take theirs, Off),
// answered once on either phone for both; the other phone's pop-up becomes a plain notice. Phone A is "Tablet", phone B is "Pixel".
// The two phones are two sync engines (fakes); what A sets is copied to B as the engine's next file list would.
// flutter test test_shots/settings_link_renders_test.dart --update-goldens  (pictures in test_shots/settings_link/)

import 'dart:async';
import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/settings/settings_link_pages.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sharing/synced_settings.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'settings_link';
const _size = Size(390, 844);

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

class _Phone {
  _Phone(this.id, this.name, this.peerId, this.peerName, this.fake, this.sharing, this.sync, this.layout);
  final String id, name, peerId, peerName;
  final FakeSync fake;
  final SharingState sharing;
  final SettingsSync sync;
  final LayoutState layout;
  Map<String, Object?> get peer => fake.peers.first;
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    final t = theme.name;
    testWidgets('settings link 390 $t', (tester) async {
      final r = await SettingsRig.create(tester);
      final now = DateTime.now().millisecondsSinceEpoch;
      Future<_Phone> make(String id, String name, String peerId, String peerName) async {
        final fake = FakeSync()
          ..id = id
          ..name = name
          ..peers.add({
            'id': peerId, 'name': peerName, 'linked': now, 'last_seen': now - 60000, 'via': 'direct', 'error': null, 'link_known': true,
            'link': {'mode': 'off', 'ask': true}, 'link_t': 0,
          });
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], deviceName: name, opener: (_) async => fake);
        final layout = LayoutState(settingsDirOverride: r.dir);
        final sync = SettingsSync(
          sharing: sharing,
          settings: appSyncedSettings(app: r.app, layout: layout, settings: r.settings, maps: r.maps, weather: r.weather),
          keys: () => const [],
          storeKey: (_, _) async => false,
          dir: () async => Directory('${r.dir.path}/$kSettingsShareDir-$id'),
          every: const Duration(hours: 1),
        );
        await tester.runAsync(() async {
          await layout.init();
          await sharing.setUp();
          await sync.start();
        });
        return _Phone(id, name, peerId, peerName, fake, sharing, sync, layout);
      }

      final a = await make('tablet', 'Tablet', 'pixel', 'Pixel');
      final b = await make('pixel', 'Pixel', 'tablet', 'Tablet');

      Future<void> ra(String label, Future<void> Function() f) async {
        stdout.writeln('step: $label');
        await tester.runAsync(() => f().timeout(const Duration(seconds: 20)));
      }

      Future<void> reset() async {
        for (final p in [a, b]) {
          p.peer['link'] = {'mode': 'off', 'ask': true};
          p.peer['link_t'] = 0;
          await ra('reset refresh', p.sharing.refresh);
        }
      }

      // What the engine does with the next file list: the other phone takes the record.
      Future<void> propagate(_Phone from, _Phone to) async {
        to.peer['link'] = Map<String, Object?>.of((from.peer['link'] as Map).cast<String, Object?>());
        to.peer['link_t'] = from.peer['link_t'];
        await tester.runAsync(to.sharing.refresh);
        await tester.pump();
      }

      Future<void> showPage(_Phone p) async {
        r.hub = SettingsHub(
          sharing: p.sharing,
          settingsSync: p.sync,
          settings: r.settings,
          policy: r.policy,
          webSearch: r.webSearch,
          storage: r.storage,
          weather: r.weather,
          openUrl: (u) async => r.opened.add(u),
        );
        phone(tester, size: _size, ratio: 3);
        await tester.pumpWidget(shotApp(SettingsScreen(deps: r.deps), theme: theme));
        await _settle(tester);
      }

      Future<void> device(_Phone p, String name) async {
        await showPage(p);
        await _tap(tester, 'settings-sharing');
        await _tap(tester, 'peer-${p.peerId}');
        await snap(tester, _out, '$name-$t');
      }

      Future<void> popup(_Phone p, String name) async {
        await showPage(p);
        unawaited(askSettingsLink(tester.element(find.byType(Scaffold).first), p.sync, p.peerId, p.peerName));
        await _settle(tester);
        await snap(tester, _out, '$name-$t');
      }

      // 1: the question, on a new link
      await popup(a, '1-popup-phone-A');

      // 2-5: A answers; A's device page, then B's pop-up (open when A answered) as a notice
      final choices = <String, SettingsLink>{'2-send-mine': SettingsLink.sending, '3-take-theirs': SettingsLink.receiving, '4-match': SettingsLink.match, '5-off': SettingsLink.off};
      for (final c in choices.entries) {
        await reset();
        await ra('answer ${c.key}', () => a.sync.answer(a.peerId, c.value));
        await propagate(a, b);
        await device(a, '${c.key}-A-device-page');
        await popup(b, '${c.key}-B-notice');
        // 6: the device page offers the four choices from either phone (here B's, after A sent)
        if (c.value == SettingsLink.sending) await device(b, '6-device-page-B-four-choices');
        // B's answer can't override the first.
        if (c.value == SettingsLink.off) continue;
        await ra('B answer', () => b.sync.answer(b.peerId, SettingsLink.off));
        expect(b.sync.linkWith(b.peerId), c.value == SettingsLink.sending ? SettingsLink.receiving : c.value == SettingsLink.receiving ? SettingsLink.sending : c.value);
      }

      await showPage(a);
      await tester.pumpWidget(shotApp(const SizedBox(), theme: theme));
      await _settle(tester);
      for (final p in [a, b]) {
        await tester.runAsync(p.sync.flush);
        p.sync.dispose();
        p.sharing.dispose();
        p.layout.dispose();
      }
      await r.dispose(tester);
    });
  }
}
