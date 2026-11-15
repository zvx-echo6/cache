// Web links (http and https) in books and ZIM pages: online a tap opens the phone's browser; offline it says "You're offline"
// with "Copy link", in place. net/web_link.dart is the one helper the PDF reader and the ZIM reader call.

import 'package:cache/net/web_link.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe implements ConnectionProbe {
  _Probe(this.kind);
  ConnectionKind kind;
  @override
  Future<ConnectionKind> current() async => kind;
  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

void main() {
  final opened = <String>[];
  final copied = <String>[];
  late _Probe probe;

  setUp(() {
    opened.clear();
    copied.clear();
    probe = _Probe(ConnectionKind.wifi);
    WebLinks.probe = probe;
    WebLinks.open = (u) async => opened.add(u);
    WebLinks.copy = (t) async => copied.add(t);
  });

  Future<void> tapLink(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) => TextButton(onPressed: () => openWebLink(c, 'https://example.org/a?b=1'), child: const Text('link'))),
      ),
    ));
    await tester.tap(find.text('link'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('online: the link opens in the browser at once, with no question and nothing said', (tester) async {
    await tapLink(tester);
    expect(opened, ['https://example.org/a?b=1']);
    expect(find.text("You're offline"), findsNothing);
    expect(find.byType(AlertDialog), findsNothing, reason: 'no "Open this link in your browser?" question');
  });

  testWidgets('on mobile data it opens too', (tester) async {
    probe.kind = ConnectionKind.mobile;
    await tapLink(tester);
    expect(opened, hasLength(1));
  });

  testWidgets('offline: "You\'re offline" with Copy link in place, and Copy link copies the address; the browser is not called', (tester) async {
    probe.kind = ConnectionKind.none;
    await tapLink(tester);
    expect(opened, isEmpty);
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800)); // the snack bar slides in
    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copied, ['https://example.org/a?b=1']);
  });

  test('only http and https are web links', () {
    expect(isWebLink(Uri.parse('https://a.org')), isTrue);
    expect(isWebLink(Uri.parse('http://a.org')), isTrue);
    expect(isWebLink(Uri.parse('mailto:a@b.org')), isFalse);
    expect(isWebLink(Uri.parse('cachelink:maps')), isFalse);
  });
}
