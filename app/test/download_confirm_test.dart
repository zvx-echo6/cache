import 'package:cache/screens/download_confirm.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1 << 30;

void main() {
  DownloadChoice? chosen;
  bool? deleted;
  var storageOpened = 0;

  Future<void> open(WidgetTester tester, Future<void> Function(BuildContext) show) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => show(c), child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    chosen = null;
    deleted = null;
    storageOpened = 0;
    openStorageForSpace = (_) => storageOpened++;
  });
  tearDown(() => openStorageForSpace = null);

  testWidgets('it fits: the items with their sizes, the storage bar and what is free after, Cancel and Download', (tester) async {
    await open(tester, (c) async => chosen = await confirmDownload(
      c,
      title: 'Download WikiMed?',
      lines: const [DownloadLine('WikiMed, medical encyclopedia', 2 * _gb + _gb ~/ 10)],
      space: const Space(free: 103 * _gb, reserve: 20 * _gb),
    ));
    expect(find.text('Download WikiMed?'), findsOneWidget);
    expect(find.text('WikiMed, medical encyclopedia'), findsOneWidget);
    expect(find.text('2.1 GB'), findsOneWidget);
    expect(find.text('103.0 GB free, 100.9 GB after'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await tester.pumpAndSettle();
    expect(chosen, DownloadChoice.now);
  });

  testWidgets('it does not fit: how much more is needed and why, and Free up space opens Storage', (tester) async {
    await open(tester, (c) async => chosen = await confirmDownload(
      c,
      title: 'Download Wikipedia (full)?',
      lines: const [DownloadLine('Wikipedia (full)', 111 * _gb)],
      space: const Space(free: 103 * _gb, reserve: 20 * _gb),
    ));
    expect(find.text('Needs 28.0 GB more. Cache always leaves 20.0 GB for the phone.'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-download')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('free-up-space')));
    await tester.pumpAndSettle();
    expect(chosen, DownloadChoice.cancel);
    expect(storageOpened, 1);
  });

  testWidgets('on mobile data with mobile data downloads off it says so, and Wait for Wi-Fi is the default', (tester) async {
    await open(tester, (c) async => chosen = await confirmDownload(
      c,
      title: 'Download Gemma 4 E2B?',
      lines: const [DownloadLine('Gemma 4 E2B', 3 * _gb), DownloadLine('Search model (once, for searching by meaning)', 605 << 20)],
      space: const Space(free: 103 * _gb, reserve: 20 * _gb),
      mobileBlocked: true,
    ));
    expect(find.text('Search model (once, for searching by meaning)'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-mobile')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Wait for Wi-Fi'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wait-for-wifi')));
    await tester.pumpAndSettle();
    expect(chosen, DownloadChoice.whenWifi);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-now')));
    await tester.pumpAndSettle();
    expect(chosen, DownloadChoice.now);
  });

  testWidgets('delete always asks first, in the same shape, with a red Delete', (tester) async {
    await open(tester, (c) async => deleted = await confirmDelete(c, name: 'Wikipedia (full)', bytes: 111 * _gb, free: 103 * _gb));
    expect(find.text('Delete Wikipedia (full)?'), findsOneWidget);
    expect(find.text('Frees'), findsOneWidget);
    expect(find.text('103.0 GB free now, 214.0 GB after'), findsOneWidget);
    expect(find.text('You can download it again later.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isFalse);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });
}
