// Scan a link code, for review: the Enter a link code box with the Scan button, the scan screen (a placeholder where the camera
// preview goes: a test has no camera), the refused-camera state and the "isn't a Cache link code" line. 390 x 844, light and dark.
// flutter test test_shots/link_scan_renders_test.dart --update-goldens  (pictures in test_shots/link_scan/)

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/link_inbox.dart';
import 'package:cache/sharing/link_scan.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zxing/flutter_zxing.dart' show ScannerOverlayBorder;

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

/// The camera's place on the picture: a grey field with the guide square the real preview carries.
class _Placeholder implements LinkScanner {
  _Placeholder({this.problem});
  final ScanProblem? problem;
  void Function(String)? text;

  @override
  Widget view({required void Function(String text) onText, required void Function(ScanProblem problem) onProblem}) {
    text = onText;
    final p = problem;
    if (p != null) WidgetsBinding.instance.addPostFrameCallback((_) => onProblem(p));
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF55606A)),
        const Center(child: Text('camera preview goes here', style: TextStyle(color: Colors.white54, fontSize: 14))),
        Container(decoration: const ShapeDecoration(shape: ScannerOverlayBorder(cutOutSize: 0.7))),
      ],
    );
  }

  @override
  Future<void> openSettings() async {}
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    final t = theme == CacheThemeId.dark ? 'dark' : 'light';
    testWidgets('Scan a link code, $t', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      Future<void> open(_Placeholder cam) async {
        final r = await SettingsRig.create(tester);
        phone(tester, size: const Size(390, 844));
        await tester.runAsync(() => r.sharing.setUp());
        await tester.pumpWidget(shotApp(SharingPage(sharing: r.sharing, inbox: LinkInbox(channel: const MethodChannel('co.cache/shot')), scanner: cam), theme: theme));
        await tester.pump();
        await tester.tap(find.text('Enter a link code'));
        await tester.pumpAndSettle();
      }

      var cam = _Placeholder();
      await open(cam);
      await snap(tester, 'link_scan', 'scan-enter-code-$t');

      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      await snap(tester, 'link_scan', 'scan-camera-$t');

      cam.text!('https://example.com/');
      await tester.pump(const Duration(milliseconds: 300));
      await snap(tester, 'link_scan', 'scan-not-a-code-$t');

      cam = _Placeholder(problem: ScanProblem.denied);
      await open(cam);
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      await snap(tester, 'link_scan', 'scan-refused-$t');
    });
  }
}
