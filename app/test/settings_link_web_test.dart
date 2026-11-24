// A linked device's Settings pages in a browser (Cache Server is the device): the same pages as on a phone, on SharingState's web
// driver against the fake sharing host (app/test/support/sharing_host_fake.dart, the host's ops and answers). The question and the four
// choices and What's included go to the host as the link record; API keys list the names the server's keystore holds that can
// sync and tick through the host's key ops. No page shows a key value, and nothing here asks for the keys themselves.

import 'dart:convert';
import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/screens/settings/widgets.dart' show SwitchRow;
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sharing_host_fake.dart';

const _secrets = ['OWM-SECRET-1', 'KAGI-SECRET-2', 'ZZZ-SECRET-3'];

FakeSharingHost _host() {
  final h = FakeSharingHost(table: {
    'library': {'library': '/srv/zims'},
  })
    ..enabled = true;
  h.sync.peers.add({
    'id': 'p1',
    'name': 'Desk',
    'linked': 1,
    'last_seen': 1,
    'via': 'direct',
    'error': null,
    'link_known': true,
    'link': {'mode': 'match', 'from': 'me'},
  });
  h.keyValues
    ..['live.key.owm'] = _secrets[0]
    ..['search.kagi.key'] = _secrets[1]
    ..['live.key.zzz'] = _secrets[2];
  return h;
}

class _Rig {
  _Rig(this.host, this.dir) {
    sharing = SharingState(policy: testPolicy(), supportDir: () async => dir, kinds: const [], remote: host);
    sync = SettingsSync(
      sharing: sharing,
      settings: [
        SyncedSetting(
          key: 'appearance.theme',
          group: SettingsGroupId.appearance,
          label: 'Theme',
          listenable: theme,
          read: () => theme.value,
          write: (v) async {
            theme.value = v as String;
            return true;
          },
          shows: () => theme.value,
        ),
      ],
      // What the tab works out for itself: the labels the phone shows. (A tab's own list is never what is shown, the server's names are.)
      keys: () => [SyncedKey(name: 'live.key.owm', label: 'OpenWeatherMap', read: () async => null)],
      storeKey: (n, v) async => false,
      dir: () async => null,
      every: const Duration(hours: 1),
    );
  }

  final FakeSharingHost host;
  final Directory dir;
  final theme = ValueNotifier<String>('dark');
  late final SharingState sharing;
  late final SettingsSync sync;

  Future<void> start(WidgetTester tester) async {
    await sharing.init();
    sync.watchServerKeys();
    await _settle(tester);
  }

  Widget page() => MaterialApp(theme: buildTheme(CacheThemeId.dark), home: SharingDevicePage(sharing: sharing, peer: 'p1', settingsSync: sync));

  void dispose() {
    sync.dispose();
    sharing.dispose();
  }
}

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 5400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('settings-link-web'));
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, Object?> lastLink(FakeSharingHost h) => (h.sync.argsOf['set_link']!.last['link'] as Map).cast<String, Object?>();

  testWidgets('the four choices go to the host as the link record, and what is chosen shows', (tester) async {
    _tall(tester);
    final host = _host();
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    expect(find.text('Match both ways'), findsOneWidget);
    expect(find.text('API keys'), findsOneWidget);

    await _tap(tester, 'link-send');
    expect(lastLink(host), containsPair('mode', 'send'));
    expect(lastLink(host), containsPair('from', 'me'));
    await _tap(tester, 'link-receive');
    expect(lastLink(host), containsPair('mode', 'send'));
    expect(lastLink(host), containsPair('from', 'p1'));
    expect(find.byKey(const ValueKey('link-keys')), findsOneWidget, reason: 'read only: keys come from the device whose settings this one follows');
    expect(find.textContaining('Keys come from'), findsOneWidget);
    await _tap(tester, 'link-match');
    expect(lastLink(host), containsPair('mode', 'match'));
    await _tap(tester, 'link-off');
    expect(lastLink(host), containsPair('mode', 'off'));
    expect(find.byKey(const ValueKey('link-included')), findsNothing);
    expect(host.sync.calls, isNot(contains('set_secrets')), reason: 'the browser never gives the engine keys');
    expect(host.sync.calls, isNot(contains('take_secrets')));
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the question: the first answer sets the pair through the host, and a late one does not undo it', (tester) async {
    final host = _host();
    host.sync.peers.single
      ..['linked'] = DateTime.now().millisecondsSinceEpoch
      ..['link'] = {'mode': 'off', 'ask': true};
    final r = _Rig(host, dir);
    await r.start(tester);
    expect(r.sync.unanswered('p1'), isTrue);
    await r.sync.answer('p1', SettingsLink.sending);
    await _settle(tester);
    expect(lastLink(host), containsPair('mode', 'send'));
    expect(lastLink(host), containsPair('by', 'me'));
    expect(lastLink(host).containsKey('ask'), isFalse);
    expect(r.sync.unanswered('p1'), isFalse);
    final n = host.sync.argsOf['set_link']!.length;
    await r.sync.answer('p1', SettingsLink.off);
    expect(host.sync.argsOf['set_link']!.length, n, reason: 'once answered, a later answer is only read');
    r.dispose();
  });

  testWidgets("What's included: a group and a single setting reach the host as the link record", (tester) async {
    _tall(tester);
    final host = _host();
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    expect(find.text('1 of 6 groups'), findsOneWidget);
    await _tap(tester, 'link-included');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('group-appearance')), matching: find.byType(Switch)));
    await _settle(tester);
    expect(lastLink(host)['off_groups'], ['appearance']);
    expect(host.sync.peers.single['link'], containsPair('off_groups', ['appearance']), reason: 'the server reads the record it keeps');
    await _tap(tester, 'group-appearance');
    await _tap(tester, 'setting-appearance.theme');
    expect(lastLink(host)['off_keys'], isNot(contains('appearance.theme')), reason: 'it was ticked on, with its group, by this tap');
    expect(r.sync.settingOn('p1', 'appearance.theme'), isTrue);
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('API keys: the names the server keystore holds, with the phone\'s labels, none of them a value', (tester) async {
    _tall(tester);
    final host = _host();
    host.keyTicks['search.kagi.key'] = {'p1'};
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    expect(find.text('1 of 3 included'), findsOneWidget);
    expect(find.text('No keys saved here'), findsNothing);
    await _tap(tester, 'link-keys');
    expect(find.text('OpenWeatherMap'), findsOneWidget, reason: 'the label the app can work out');
    expect(find.text('Kagi (web search)'), findsOneWidget);
    expect(find.text('zzz'), findsOneWidget, reason: 'a source this tab does not know is its name, as on a phone');
    expect(find.byKey(const ValueKey('key-live.key.owm')), findsOneWidget);
    final on = [for (final k in ['live.key.owm', 'search.kagi.key', 'live.key.zzz']) tester.widget<SwitchRow>(find.byKey(ValueKey('key-$k'))).value];
    expect(on, [false, true, false], reason: 'the ticks are the server\'s');
    for (final v in _secrets) {
      expect(find.textContaining(v), findsNothing);
    }
    expect(jsonEncode(host.opArgs), isNot(contains('SECRET')), reason: 'no key value was sent to the host or asked of it');
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('API keys: a tick calls the host with this device and the key name, and shows what the host kept', (tester) async {
    _tall(tester);
    final host = _host();
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    expect(find.text('None included'), findsOneWidget);
    await _tap(tester, 'link-keys');
    await _tap(tester, 'key-live.key.owm');
    final i = host.opArgs.lastIndexWhere((a) => a['method'] == 'set_key_on');
    expect(host.opArgs[i], {'method': 'set_key_on', 'args': {'peer': 'p1', 'name': 'live.key.owm', 'on': true}});
    expect(host.keyTicks['live.key.owm'], {'p1'});
    expect(tester.widget<SwitchRow>(find.byKey(const ValueKey('key-live.key.owm'))).value, isTrue);
    await _tap(tester, 'key-live.key.owm');
    expect(host.opArgs.lastWhere((a) => a['method'] == 'set_key_on'), {'method': 'set_key_on', 'args': {'peer': 'p1', 'name': 'live.key.owm', 'on': false}});
    expect(host.keyTicks['live.key.owm'], isEmpty);
    expect(host.sync.calls, isNot(contains('set_secrets')));
    expect(jsonEncode(host.opArgs), isNot(contains('SECRET')));
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('API keys: a tick the host refuses does not stay ticked', (tester) async {
    _tall(tester);
    final host = _host()..keyError = const CacheSearchException('bad_args', 'No such key to send: live.key.owm');
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    await _tap(tester, 'link-keys');
    await _tap(tester, 'key-live.key.owm');
    expect(tester.widget<SwitchRow>(find.byKey(const ValueKey('key-live.key.owm'))).value, isFalse);
    expect(r.sync.keyOn('p1', 'live.key.owm'), isFalse);
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('API keys: the Include API keys switch stays on, as on a phone, while one key is left out; pressing it turns it off', (tester) async {
    _tall(tester);
    final host = _host();
    host.keyInclude.add('p1');
    host.keyTicks['live.key.owm'] = {'p1'};
    host.keyTicks['live.key.zzz'] = {'p1'}; // search.kagi.key is left out
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    await _tap(tester, 'link-keys');
    expect(tester.widget<SwitchRow>(find.byKey(const ValueKey('include-keys'))).value, isTrue, reason: 'one key left out is not the switch off');
    expect(find.text('All keys go to Desk'), findsOneWidget, reason: 'the phone\'s wording for the switch on');
    expect(tester.widget<SwitchRow>(find.byKey(const ValueKey('key-search.kagi.key'))).value, isFalse);
    await _tap(tester, 'include-keys');
    expect(host.opArgs.lastWhere((a) => a['method'] == 'set_include_keys'), {'method': 'set_include_keys', 'args': {'peer': 'p1', 'on': false}});
    expect(tester.widget<SwitchRow>(find.byKey(const ValueKey('include-keys'))).value, isFalse);
    expect(find.text('No keys go to Desk'), findsOneWidget);
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('API keys: with no key saved, switching Include API keys on is recorded, and stays on', (tester) async {
    _tall(tester);
    final host = _host()..keyValues.clear();
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    await _tap(tester, 'link-keys');
    expect(tester.widget<SwitchRow>(find.byKey(const ValueKey('include-keys'))).value, isFalse);
    await _tap(tester, 'include-keys');
    expect(host.opArgs.lastWhere((a) => a['method'] == 'set_include_keys'), {'method': 'set_include_keys', 'args': {'peer': 'p1', 'on': true}});
    expect(host.keyInclude, {'p1'});
    expect(tester.widget<SwitchRow>(find.byKey(const ValueKey('include-keys'))).value, isTrue);
    expect(find.text('All keys go to Desk'), findsOneWidget);
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a server holding no key that can sync says so, as the phone does', (tester) async {
    _tall(tester);
    final host = _host()..keyValues.clear();
    final r = _Rig(host, dir);
    await r.start(tester);
    await tester.pumpWidget(r.page());
    await _settle(tester);
    expect(find.text('No keys saved here'), findsOneWidget);
    r.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
