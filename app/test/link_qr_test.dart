import 'dart:convert';

import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/link_inbox.dart';
import 'package:cache/sharing/link_url.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/sync_fake.dart' show linkCodeLines;
import 'package:cache/update/app_update.dart' show AppUpdate, AppUpdateSource;
import 'package:cache/update/update_ui.dart' show AppUpdates, currentAppUpdates;
import 'package:cache/platform/share_or_copy.dart' show systemShareAvailable;

const _newer = 'This link code is from a newer Cache. Update Cache here, then try again.';
const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// A link code as the sync engine writes it: `CACHE1-` and the unpadded Base32 of the JSON.
String codeFor(String id, {String name = 'Desk'}) {
  final bytes = utf8.encode(jsonEncode({'a': {'id': id, 'addrs': <String>[]}, 't': 'TOKEN', 'n': name}));
  var bits = 0, acc = 0;
  final out = StringBuffer('CACHE1-');
  for (final b in bytes) {
    acc = (acc << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_b32[(acc >> bits) & 31]);
    }
    acc &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_b32[(acc << (5 - bits)) & 31]);
  return out.toString();
}

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

const _short = 'CACHE-7KQF-M2XD-P4WN-R7TA-H3JC-V6YB-Q5LE-W2FS-ZQ';

void main() {
  final code = codeFor('aa11bb22');

  group('the link form', () {
    test('builds cachelink://link/<code>', () {
      expect(buildLinkUrl('CACHE1-ABC234'), 'cachelink://link/CACHE1-ABC234');
      expect(kLinkPrefix, 'cachelink://link/');
    });

    test('the short code: the link keeps it as it is, and reads back the same', () {
      expect(buildLinkUrl(_short), 'cachelink://link/$_short');
      expect(buildLinkUrl(_short).startsWith('cachelink://'), isTrue, reason: 'lower-case scheme, which Android matches');
      expect(linkCodeFrom('cachelink://link/$_short'), _short);
      expect(linkCodeFrom('CACHELINK://LINK/$_short'), _short);
      expect(linkCodeFrom('cachelink:$_short'), _short);
      expect(linkCodeFrom(' $_short\n'), _short);
      expect(linkCodeFrom('cachelink://link/CACHE-7KQF-M2XD-P4WN-\nR7TA-H3JC-V6YB-Q5LE-W2FS-ZQ'), _short, reason: 'a line break from a wrapped paste');
      expect(isShortLinkCode(_short), isTrue);
      expect(isShortLinkCode('cache-7kqf m2xd'), isTrue, reason: 'case and spaces do not matter, as in the engine');
      expect(isShortLinkCode(code), isFalse, reason: 'a CACHE1 code is the long form');
    });

    test('parses both forms, and a bare code', () {
      expect(linkCodeFrom('cachelink://link/$code'), code);
      expect(linkCodeFrom('cachelink:$code'), code);
      expect(linkCodeFrom(code), code);
      expect(linkCodeFrom('  cachelink://link/$code\n'), code);
      expect(linkCodeFrom('cachelink://link/$code/'), code);
      expect(linkCodeFrom(buildLinkUrl(code)), code, reason: 'what is built is what is read');
    });

    test('a payload in the path survives case changes of the scheme and the host', () {
      const mixed = 'CACHE1-AbCdEf234567';
      expect(linkCodeFrom('CACHELINK://LINK/$mixed'), mixed);
      expect(linkCodeFrom('CacheLink://Link/$mixed'), mixed);
      expect(linkCodeFrom('cachelink://link/$mixed'), mixed);
      expect(linkCodeFrom('CACHELINK:$mixed'), mixed, reason: 'the payload keeps its case');
      // The engine reads the code in any case, so a payload the system lowercased still decodes.
      expect(decodeLinkCode(code.toLowerCase()).id, 'aa11bb22');
    });

    test('a query or fragment added by a scanner is dropped; percent-escapes are read', () {
      expect(linkCodeFrom('cachelink://link/$code?x=1'), code);
      expect(linkCodeFrom('cachelink://link/$code#top'), code);
      expect(linkCodeFrom('cachelink://link/CACHE1%2DABC'), 'CACHE1-ABC');
    });

    test('malformed links are refused with the existing message', () {
      for (final bad in [
        'cachelink://link/',
        'cachelink://link',
        'cachelink:',
        'cachelink://other/$code',
        'cachelink://link/CACHE1 ABC!',
        'cachelink://link/%ZZ',
        'cachelink://link/CACHE1-ABC/extra',
      ]) {
        expect(() => linkCodeFrom(bad), throwsA(isA<BadLinkCode>().having((e) => e.message, 'message', kNotACode)), reason: bad);
      }
    });

    test('an oversized payload is refused with the existing message', () {
      final big = 'CACHE1-${'A' * (kLinkMaxPayload + 1)}';
      expect(() => linkCodeFrom('cachelink://link/$big'), throwsA(isA<BadLinkCode>().having((e) => e.message, 'm', kNotACode)));
      expect(() => linkCodeFrom('cachelink:$big'), throwsA(isA<BadLinkCode>()));
      expect(() => linkCodeFrom(big), throwsA(isA<BadLinkCode>()));
      expect(linkCodeFrom('cachelink://link/CACHE1-${'A' * 1500}'), hasLength(1507), reason: 'a large real code still passes');
    });

    test('decoding a code reads its device and name, and refuses what is not a code', () {
      final i = decodeLinkCode(codeFor('abc123', name: 'Kitchen'));
      expect((i.id, i.name), ('abc123', 'Kitchen'));
      expect(() => decodeLinkCode('NOPE-AAAA'), throwsA(isA<BadLinkCode>().having((e) => e.message, 'm', kNotACode)));
      expect(() => decodeLinkCode('CACHE1-!!!!'), throwsA(isA<BadLinkCode>().having((e) => e.message, 'm', kDamagedCode)));
      expect(() => decodeLinkCode('CACHE1-TESTCODE'), throwsA(isA<BadLinkCode>().having((e) => e.message, 'm', kDamagedCode)));
      expect(() => decodeLinkCode('CACHE1-'), throwsA(isA<BadLinkCode>()));
    });

    test('a short code (build 55) passes the link form and decodes without a device; an old code still does too', () {
      const short = 'CACHE-7KQF-M2XD-P4WN-R7TA-H3JC-V6YB-Q5LE-W2FS-ZQ';
      expect(linkCodeFrom('cachelink://link/$short'), short);
      expect(linkCodeFrom('cachelink:$short'), short);
      expect(linkCodeFrom(buildLinkUrl(short)), short);
      expect(buildLinkUrl(short).length, lessThan(70), reason: 'a small QR');
      for (final c in [short, short.toLowerCase(), ' ${short.replaceAll('-', ' ')} ', short.replaceFirst('CACHE-', 'CACHE')]) {
        final i = decodeLinkCode(c);
        expect((i.id, i.name), ('', ''), reason: c);
      }
      for (final c in [short.substring(0, short.length - 1), '${short}A', 'CACHE-7KQF-1111-P4WN-R7TA-H3JC-V6YB-Q5LE-W2FS-ZQ']) {
        expect(() => decodeLinkCode(c), throwsA(isA<BadLinkCode>().having((e) => e.message, 'm', kNotACode)), reason: c);
      }
      expect(decodeLinkCode(code).id, 'aa11bb22', reason: 'an old code still reads');
    });

    test('a code from a newer Cache (CACHE2- and up, any case) says so; other codes keep their messages', () {
      for (final c in ['CACHE2-ABC', 'cache3-abc', ' CACHE12-\nAB ', 'CACHE2-', 'CACHE99999999999999999999999-X']) {
        expect(() => decodeLinkCode(c), throwsA(isA<BadLinkCode>().having((e) => e.message, 'm', _newer)), reason: c);
      }
      for (final c in ['HELLO', 'CACHE-ABC', 'CACHE0-ABC', 'CACHE2ABC']) {
        expect(() => decodeLinkCode(c), throwsA(isA<BadLinkCode>().having((e) => e.message, 'm', kNotACode)), reason: c);
      }
      expect(linkCodeFrom('cachelink://link/CACHE2-ABC'), 'CACHE2-ABC');
    });
  });

  group('the inbox', () {
    const ch = MethodChannel('co.cache/link-test');

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));

    test('cold start: a link the app was opened with is taken once at start', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      var taken = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
        if (call.method == 'take') return taken++ == 0 ? 'cachelink://link/$code' : null;
        return null;
      });
      final inbox = LinkInbox(channel: ch);
      await inbox.start();
      expect(inbox.pending, 'cachelink://link/$code');
      expect(inbox.take(), 'cachelink://link/$code');
      expect(inbox.take(), isNull, reason: 'handed over once');
    });

    test('warm start: a link pushed while running is held, one at a time', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async => null);
      final inbox = LinkInbox(channel: ch);
      await inbox.start();
      expect(inbox.pending, isNull);
      await push(ch, 'cachelink:$code');
      expect(inbox.pending, 'cachelink:$code');
      await push(ch, 'cachelink:OTHER');
      expect(inbox.pending, 'cachelink:$code', reason: 'a second link while one waits is dropped');
    });

    test('with no native side nothing happens', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final inbox = LinkInbox(channel: const MethodChannel('co.cache/none'));
      await inbox.start();
      expect(inbox.pending, isNull);
    });
  });

  group('the Sharing page', () {
    const ch = MethodChannel('co.cache/link-page');
    late List<String> clipReads;
    late List<String> clipWrites;

    Future<SettingsRig> openPage(WidgetTester tester, LinkInbox inbox, {List<String>? shared}) async {
      tall(tester);
      clipReads = [];
      clipWrites = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipWrites.add('${(call.arguments as Map)['text']}');
        if (call.method == 'Clipboard.getData') {
          clipReads.add('read');
          return {'text': 'CACHE1-FROMCLIPBOARD'};
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.sharing.setUp());
      await r.show(tester, SharingPage(sharing: r.sharing, inbox: inbox, share: (t) async => shared?.add(t)));
      await tester.pump();
      return r;
    }

    LinkInbox fresh() => LinkInbox(channel: ch);

    testWidgets('a link opening the app (cold start) lands on Enter a link code with the code filled in, and reads no clipboard', (tester) async {
      final inbox = fresh();
      inbox.offer('cachelink://link/$code'); // taken at start, before the page exists
      final r = await openPage(tester, inbox);
      await tester.pumpAndSettle();
      expect(find.text('Enter a link code'), findsWidgets);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);
      expect(clipReads, isEmpty, reason: 'the clipboard is not read');
      expect(r.sync.calls, isNot(contains('link')), reason: 'nothing links until Link is tapped');

      await tester.runAsync(() async {
        await tester.tap(find.text('Link'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.sync.argsOf['link']!.single['code'], code);
      await r.dispose(tester);
    });

    testWidgets('a link arriving while the page is open (warm start) lands on the same box', (tester) async {
      final inbox = fresh();
      final r = await openPage(tester, inbox);
      expect(find.byType(AlertDialog), findsNothing);
      inbox.offer('cachelink:$code');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);
      expect(clipReads, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r.sync.calls, isNot(contains('link')), reason: 'Cancel links nothing');
      await r.dispose(tester);
    });

    testWidgets('the clipboard is read only when Paste is tapped, never on opening the box', (tester) async {
      final r = await openPage(tester, fresh());
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(clipReads, isEmpty);
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(clipReads, hasLength(1));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    });

    testWidgets('a device that is already linked is told, and nothing changes', (tester) async {
      final inbox = fresh();
      tall(tester);
      final r = await openPage(tester, inbox);
      r.sync.peers.add({'id': 'aa11bb22', 'name': 'Desk', 'linked': 1, 'last_seen': null, 'via': null, 'error': null, 'link': {'mode': 'match'}, 'link_t': 1});
      await tester.runAsync(() => r.sharing.refresh());
      await tester.pump();
      final before = List.of(r.sync.peers.map((p) => Map.of(p)));
      inbox.offer('cachelink://link/$code');
      await tester.pumpAndSettle();
      expect(find.text('Already linked with Desk'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(r.sync.calls, isNot(contains('link')));
      expect(r.sync.peers, before, reason: 'the pair is not touched');
      await r.dispose(tester);
    });

    testWidgets("this device's own code is refused with the engine's message", (tester) async {
      final inbox = fresh();
      final r = await openPage(tester, inbox);
      inbox.offer('cachelink://link/${codeFor('me')}');
      await tester.pumpAndSettle();
      expect(find.text("that is this device's own code"), findsOneWidget);
      expect(r.sync.calls, isNot(contains('link')));
      await r.dispose(tester);
    });

    for (final bad in ['cachelink://link/', 'cachelink://link/CACHE1-%%%', 'cachelink://link/CACHE1-${'A' * 3000}', 'cachelink://other/x']) {
      testWidgets('a malformed or oversized link shows the existing message and links nothing: ${bad.length > 40 ? '${bad.substring(0, 40)}...' : bad}',
          (tester) async {
        final inbox = fresh();
        final r = await openPage(tester, inbox);
        inbox.offer(bad);
        await tester.pumpAndSettle();
        expect(find.text(kNotACode), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(r.sync.calls, isNot(contains('link')));
        await r.dispose(tester);
      });
    }

    testWidgets('a code that is not readable gives the damaged message', (tester) async {
      final inbox = fresh();
      final r = await openPage(tester, inbox);
      inbox.offer('cachelink:CACHE1-TESTCODE');
      await tester.pumpAndSettle();
      expect(find.text(kDamagedCode), findsOneWidget);
      expect(r.sync.calls, isNot(contains('link')));
      await r.dispose(tester);
    });

    testWidgets('while sharing is not set up the link waits, then lands once it runs', (tester) async {
      tall(tester);
      final inbox = fresh();
      final r = await SettingsRig.create(tester);
      inbox.offer('cachelink://link/$code');
      await r.show(tester, SharingPage(sharing: r.sharing, inbox: inbox, share: (_) async {}));
      await tester.pumpAndSettle();
      expect(find.text('Set up sharing'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(inbox.pending, isNotNull);
      await tester.runAsync(() => r.sharing.setUp());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    });

    testWidgets('the code sheet: the QR is the link, the code and Copy stay, and Share sends the link', (tester) async {
      final shared = <String>[];
      final r = await openPage(tester, fresh(), shared: shared);
      await tester.tap(find.byKey(const ValueKey('show-code')));
      await tester.pumpAndSettle();
      expect(tester.widget<LinkQr>(find.byType(LinkQr)).link, 'cachelink://link/$_short');
      expect(linkCodeLines(tester).join(), _short, reason: 'the whole code stays under the QR, never cut short');
      expect(find.text('Copy code'), findsOneWidget);
      expect(find.text('Share link'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('share-link')));
      await tester.pump();
      expect(shared, ['cachelink://link/$_short']);
      expect(clipReads, isEmpty);
      await r.dispose(tester);
    });

    testWidgets('a browser with no share sheet (navigator.share): Share link copies the link and says Link copied', (tester) async {
      final before = systemShareAvailable;
      systemShareAvailable = () => false;
      addTearDown(() => systemShareAvailable = before);
      final shared = <String>[];
      final r = await openPage(tester, fresh(), shared: shared);
      await tester.tap(find.byKey(const ValueKey('show-code')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-link')));
      await tester.pump();
      expect(shared, isEmpty, reason: 'nothing to hand it to');
      expect(clipWrites, ['cachelink://link/$_short']);
      expect(find.text('Link copied'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('a pasted link in the box links with its code', (tester) async {
      final r = await openPage(tester, fresh());
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'cachelink://link/CACHE1-TESTCODE');
      await tester.runAsync(() async {
        await tester.tap(find.text('Link'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.sync.argsOf['link']!.single['code'], 'CACHE1-TESTCODE');
      await r.dispose(tester);
    });

    for (final typed in ['CACHE2-ABCDEF', 'cache3-abcdef', 'cachelink://link/CACHE2-ABCDEF']) {
      testWidgets('a pasted or typed $typed shows the newer-Cache sentence and links nothing', (tester) async {
        final r = await openPage(tester, fresh());
        await tester.tap(find.text('Enter a link code'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), typed);
        await tester.runAsync(() async {
          await tester.tap(find.text('Link'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(_newer), findsOneWidget);
        expect(r.sync.calls, isNot(contains('link')));
        await r.dispose(tester);
      });
    }

    testWidgets('a cachelink://link/CACHE2-... link offered through the inbox shows the sentence and links nothing', (tester) async {
      final inbox = fresh();
      final r = await openPage(tester, inbox);
      inbox.offer('cachelink://link/CACHE2-ABCDEF');
      await tester.pumpAndSettle();
      expect(find.text(_newer), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(r.sync.calls, isNot(contains('link')));
      await r.dispose(tester);
    });

    testWidgets('the engine naming the kind (not its text) gives the sentence too', (tester) async {
      final r = await openPage(tester, fresh());
      r.sync.linkError = const CacheSearchException('link_code_newer', 'whatever words the engine uses');
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'CACHE1-TESTCODE');
      await tester.runAsync(() async {
        await tester.tap(find.text('Link'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_newer), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('"Update Cache here" goes to the update: the sentence carries Update Cache, which opens what the update banner opens', (tester) async {
      final opened = <String>[];
      final before = currentAppUpdates;
      currentAppUpdates = AppUpdates(source: _NoUpdate(), openUrl: (u) async => opened.add(u), android: true);
      addTearDown(() => currentAppUpdates = before);
      final inbox = fresh();
      final r = await openPage(tester, inbox);
      inbox.offer('cachelink://link/CACHE2-ABCDEF');
      await tester.pumpAndSettle();
      expect(find.text(_newer), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Update Cache'));
      await tester.pump();
      expect(opened.single, startsWith('market://details?id='));
      await r.dispose(tester);
    });
  });
}

class _NoUpdate implements AppUpdateSource {
  @override
  Future<AppUpdate?> check() async => null;
}

/// The native side pushing a link while the app runs.
Future<void> push(MethodChannel ch, String link) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(ch.name, const StandardMethodCodec().encodeMethodCall(MethodCall('opened', link)), (_) {});
}
