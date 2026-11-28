import 'package:cache/screens/settings/link_scan_screen.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/link_inbox.dart';
import 'package:cache/sharing/link_scan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

/// A camera that is not there: the view is a plain box, and the test says what the camera "reads" or whether it was refused.
class FakeScanner implements LinkScanner {
  FakeScanner({this.problem});

  /// What the camera does as soon as it opens (null: it works).
  ScanProblem? problem;
  int opened = 0;
  int settingsOpened = 0;
  void Function(String)? _onText;

  void read(String text) => _onText!(text);

  @override
  Widget view({required void Function(String text) onText, required void Function(ScanProblem problem) onProblem}) {
    opened++;
    _onText = onText;
    final p = problem;
    if (p != null) WidgetsBinding.instance.addPostFrameCallback((_) => onProblem(p));
    return const ColoredBox(color: Color(0xFF444444));
  }

  @override
  Future<void> openSettings() async => settingsOpened++;
}

void main() {
  const long = 'CACHE1-TESTCODE';
  const short = 'CACHE-ABCD-EFGH';

  group('what a scan is read as', () {
    test('a cachelink link, a long code and a short code are Cache codes; the code is what is inside', () {
      expect(scannedLinkCode('cachelink://link/$long'), long);
      expect(scannedLinkCode(long), long);
      expect(scannedLinkCode(short), short);
      expect(scannedLinkCode('  $short\n'), short);
      expect(scannedLinkCode('cachelink://link/$short'), short);
    });

    test('anything else is not', () {
      for (final t in ['https://example.com/', 'hello', 'WIFI:S:home;T:WPA;P:pw;;', 'cachelink://other/$long', 'cachelink://link/', 'cachelink://link/not a code!', '']) {
        expect(scannedLinkCode(t), isNull, reason: t);
      }
    });
  });

  group('where Scan is offered', () {
    test('Android and iPhone only', () {
      expect(linkScannerFor(android: true, ios: false), isNotNull);
      expect(linkScannerFor(android: false, ios: true), isNotNull);
      expect(linkScannerFor(android: false, ios: false), isNull, reason: 'Linux, Windows, macOS and the web');
    });
  });

  group('Enter a link code', () {
    late FakeScanner cam;

    Future<SettingsRig> open(WidgetTester tester, {FakeScanner? scanner, bool injected = true}) async {
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      cam = scanner ?? FakeScanner();
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.sharing.setUp());
      await r.show(tester, SharingPage(sharing: r.sharing, inbox: LinkInbox(channel: const MethodChannel('co.cache/scan-test')), scanner: injected ? cam : null));
      await tester.pump();
      await tester.tap(find.text('Enter a link code'));
      await tester.pumpAndSettle();
      return r;
    }

    Future<void> afterScan(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('the Scan button is there, with the reason, and the camera is not opened until it is tapped', (tester) async {
      final r = await open(tester);
      expect(find.byKey(const ValueKey('scan-code')), findsOneWidget);
      expect(find.text('Scan a code'), findsOneWidget);
      expect(find.text('Cache uses the camera only to read the link code.'), findsOneWidget);
      expect(cam.opened, 0, reason: 'no camera, so no permission question, before Scan is tapped');
      await r.dispose(tester);
    });

    testWidgets('a scanned cachelink link fills the code and links, as if typed', (tester) async {
      final r = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      expect(find.text('Point the camera at the code on the other device'), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-cancel')), findsOneWidget);
      cam.read('cachelink://link/$long');
      await tester.pump();
      expect(find.text('Code read'), findsOneWidget, reason: 'visible feedback');
      await afterScan(tester);
      expect(find.byKey(const ValueKey('scan-screen')), findsNothing);
      expect(r.sync.argsOf['link']!.single['code'], long);
      await r.dispose(tester);
    });

    testWidgets('a scanned bare short code links', (tester) async {
      final r = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      cam.read(short);
      await afterScan(tester);
      expect(r.sync.argsOf['link']!.single['code'], short);
      await r.dispose(tester);
    });

    testWidgets('a QR that is not a Cache code says so, links nothing and keeps scanning', (tester) async {
      final r = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      cam.read('https://example.com/');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text("That isn't a Cache link code"), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-screen')), findsOneWidget, reason: 'still scanning');
      expect(r.sync.calls, isNot(contains('link')));
      cam.read(long);
      await afterScan(tester);
      expect(r.sync.argsOf['link']!.single['code'], long, reason: 'the next, right code still works');
      await r.dispose(tester);
    });

    testWidgets('Cancel goes back to the box, which still takes a typed code', (tester) async {
      final r = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scan-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(r.sync.calls, isNot(contains('link')));
      await r.dispose(tester);
    });

    testWidgets('a refused camera is said, offers settings, and typing still works', (tester) async {
      final r = await open(tester, scanner: FakeScanner(problem: ScanProblem.denied));
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      expect(find.text('Cache cannot use the camera, so it cannot read the code.'), findsOneWidget);
      expect(find.text('You can still type or paste the code instead.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scan-settings')));
      expect(cam.settingsOpened, 1);
      await tester.tap(find.byKey(const ValueKey('scan-type')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byType(TextField), long);
      await tester.runAsync(() async {
        await tester.tap(find.text('Link'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.sync.argsOf['link']!.single['code'], long);
      await r.dispose(tester);
    });

    testWidgets('Try again opens the camera again', (tester) async {
      final r = await open(tester, scanner: FakeScanner(problem: ScanProblem.denied));
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      expect(cam.opened, 1);
      cam.problem = null;
      await tester.tap(find.byKey(const ValueKey('scan-retry')));
      await tester.pumpAndSettle();
      expect(cam.opened, 2);
      expect(find.byKey(const ValueKey('scan-refused')), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('no camera: said, with no settings button', (tester) async {
      final r = await open(tester, scanner: FakeScanner(problem: ScanProblem.unavailable));
      await tester.tap(find.byKey(const ValueKey('scan-code')));
      await tester.pumpAndSettle();
      expect(find.text('The camera could not be opened, so Cache cannot read the code.'), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-settings')), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('on this machine (Linux), with no scanner given, there is no Scan button and typing works', (tester) async {
      final r = await open(tester, injected: false);
      expect(find.byKey(const ValueKey('scan-code')), findsNothing);
      expect(find.text('Scan a code'), findsNothing);
      expect(find.text('Cache uses the camera only to read the link code.'), findsNothing);
      await tester.enterText(find.byType(TextField), long);
      await tester.runAsync(() async {
        await tester.tap(find.text('Link'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.sync.argsOf['link']!.single['code'], long);
      await r.dispose(tester);
    });
  });

  testWidgets('the scan screen on its own pops with the code', (tester) async {
    final cam = FakeScanner();
    String? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) => TextButton(onPressed: () async => got = await Navigator.of(c).push<String>(MaterialPageRoute(builder: (_) => LinkScanScreen(scanner: cam))), child: const Text('go'))),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    cam.read('  cachelink://link/$long ');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(got, long);
  });
}
