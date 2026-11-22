// Web links offline (390 wide, light): what a tap does now (before) and with the helper (after). The pages themselves are a stand-in
// (a PDF page and a ZIM page cannot be drawn in a test): the dialog and the snackbars are the app's own.
// flutter test test_shots/web_links_renders_test.dart --update-goldens  (pictures in test_shots/web_links/)
import 'package:cache/net/web_link.dart';
import 'package:cache/pdf/pdf_reader_screen.dart' show askToOpenPdfLink;
import 'package:cache/settings/data_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

class _Offline implements ConnectionProbe {
  @override
  Future<ConnectionKind> current() async => ConnectionKind.none;
  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

Widget _page(String title, VoidCallback onTap) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('For the full list of safe water practices, see the guidance published by the health service.', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 12),
          InkWell(key: const ValueKey('the-link'), onTap: onTap, child: const Text('https://example.org/safe-water', style: TextStyle(fontSize: 16, color: Color(0xFFA0521C), decoration: TextDecoration.underline))),
        ]),
      ),
    );

void main() {
  setUpAll(loadShotFonts);
  setUp(() => WebLinks.probe = _Offline());
  const folder = 'web_links';

  Future<void> run(WidgetTester tester, String name, String title, void Function(BuildContext) tap) async {
    phone(tester, size: const Size(390, 600), ratio: 2);
    await tester.pumpWidget(shotApp(Builder(builder: (c) => _page(title, () => tap(c)))));
    await tester.tap(find.byKey(const ValueKey('the-link')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await snap(tester, folder, name);
  }

  testWidgets('before, a PDF', (tester) => run(tester, 'before-pdf', 'A book (PDF)', (c) => askToOpenPdfLink(c)));
  testWidgets('before, a ZIM page', (tester) => run(tester, 'before-zim', 'A ZIM page', (c) {
        ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('That link is on the web. It is not available offline.')));
      }));
  testWidgets('after, a PDF', (tester) => run(tester, 'after-pdf', 'A book (PDF)', (c) => openWebLink(c, 'https://example.org/safe-water')));
  testWidgets('after, a ZIM page', (tester) => run(tester, 'after-zim', 'A ZIM page', (c) => openWebLink(c, 'https://example.org/safe-water')));
}
