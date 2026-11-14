import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/link_inbox.dart';
import 'package:cache/sharing/link_url.dart';
import 'package:cache/sharing/nfc_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'link_qr_test.dart' show codeFor, tall;
import 'support/settings_rig.dart';

/// Linking by NFC (lib/sharing/nfc_link.dart) with a fake native side on the channel co.cache/nfc.
void main() {
  const ch = MethodChannel('co.cache/nfc-test');
  const giveLine = 'Or hold another phone to the back of this one.';
  const receiveLine = 'Or hold the phones back to back.';
  final code = codeFor('aa11bb22');
  late List<MethodCall> calls;
  late Map<String, Object?> status;
  late String? readAnswer;

  Future<SettingsRig> open(WidgetTester tester, NfcLink nfc) async {
    tall(tester);
    calls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
      calls.add(call);
      if (call.method == 'status') return status;
      if (call.method == 'read') return readAnswer;
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
    });
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.sharing.setUp());
    await r.show(tester, SharingPage(sharing: r.sharing, inbox: LinkInbox(channel: const MethodChannel('co.cache/none')), nfc: nfc));
    await tester.pump();
    return r;
  }

  Future<void> tag(WidgetTester tester, String link) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('tag', link));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(ch.name, data, (_) {});
    await tester.pump();
  }

  setUp(() {
    status = {'available': true, 'enabled': true, 'hce': true};
    readAnswer = null;
  });

  testWidgets('the sheet sets the link when it opens and clears it when it closes', (tester) async {
    final r = await open(tester, NfcLink(channel: ch, platform: TargetPlatform.android));
    await tester.tap(find.byKey(const ValueKey('show-code')));
    await tester.pumpAndSettle();
    final serves = calls.where((c) => c.method == 'serve').toList();
    expect(serves.single.arguments, {'link': 'cachelink://link/CACHE1-TESTCODE'});
    await tester.tapAt(const Offset(20, 20)); // the barrier closes the sheet
    await tester.pumpAndSettle();
    expect(find.byType(LinkQr), findsNothing);
    expect(calls.where((c) => c.method == 'serve').last.arguments, {'link': null});
    await r.dispose(tester);
  });

  testWidgets('the Android lines show only with NFC present and on', (tester) async {
    for (final s in [
      {'available': true, 'enabled': true, 'hce': true},
      {'available': true, 'enabled': false, 'hce': true},
      {'available': false, 'enabled': false, 'hce': false},
    ]) {
      status = s;
      final on = s['available'] == true && s['enabled'] == true;
      final r = await open(tester, NfcLink(channel: ch, platform: TargetPlatform.android));
      await tester.tap(find.byKey(const ValueKey('show-code')));
      await tester.pumpAndSettle();
      expect(find.text(giveLine), on ? findsOneWidget : findsNothing, reason: '$s');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      expect(find.text(receiveLine), on ? findsOneWidget : findsNothing, reason: '$s');
      expect(calls.where((c) => c.method == 'startReader'), on ? hasLength(1) : isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    }
  });

  testWidgets('reader mode runs while the link entry is open and stops when it closes', (tester) async {
    final r = await open(tester, NfcLink(channel: ch, platform: TargetPlatform.android));
    await tester.tap(find.text('Enter a link code'));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.method), contains('startReader'));
    expect(calls.map((c) => c.method), isNot(contains('stopReader')));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'stopReader');
    await r.dispose(tester);
  });

  testWidgets('a tag read on the link entry fills the code, as a pasted or camera link does', (tester) async {
    final r = await open(tester, NfcLink(channel: ch, platform: TargetPlatform.android));
    await tester.tap(find.text('Enter a link code'));
    await tester.pumpAndSettle();
    await tag(tester, 'cachelink://link/$code');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);
    expect(r.sync.calls, isNot(contains('link')), reason: 'nothing links until Link is tapped');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await r.dispose(tester);
  });

  testWidgets('a tag that is not a link code, or damaged, says so and leaves the box alone', (tester) async {
    final r = await open(tester, NfcLink(channel: ch, platform: TargetPlatform.android));
    await tester.tap(find.text('Enter a link code'));
    await tester.pumpAndSettle();
    await tag(tester, 'https://example.com/x');
    expect(find.text(kNotACode), findsOneWidget);
    await tag(tester, 'cachelink://link/CACHE1-TESTCODE');
    expect(find.text(kDamagedCode), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await r.dispose(tester);
  });

  group('iPhone', () {
    testWidgets('the button is hidden while the flag is off, and the Android lines never show', (tester) async {
      expect(kIosNfcEnabled, isFalse, reason: 'until the entitlement is added');
      final r = await open(tester, NfcLink(channel: ch, platform: TargetPlatform.iOS));
      await tester.tap(find.byKey(const ValueKey('show-code')));
      await tester.pumpAndSettle();
      expect(find.text(giveLine), findsNothing);
      expect(calls.where((c) => c.method == 'serve'), isEmpty);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      expect(find.text('Read by NFC'), findsNothing);
      expect(find.text(receiveLine), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    });

    testWidgets('with the flag on and reading available, the button reads a link into the box', (tester) async {
      readAnswer = 'cachelink://link/$code';
      final r = await open(tester, NfcLink(channel: ch, iosEnabled: true, platform: TargetPlatform.iOS));
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      expect(find.text('Read by NFC'), findsOneWidget);
      await tester.tap(find.text('Read by NFC'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);
      // A cancelled session changes nothing.
      readAnswer = null;
      await tester.tap(find.text('Read by NFC'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    });

    testWidgets('with the flag on but reading unavailable there is no button', (tester) async {
      status = {'available': false, 'enabled': false, 'hce': false};
      final r = await open(tester, NfcLink(channel: ch, iosEnabled: true, platform: TargetPlatform.iOS));
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      expect(find.text('Read by NFC'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    });
  });
}
