// In a browser with no share sheet (navigator.share absent), every Share button offers Copy and Download.
import 'dart:convert';
import 'dart:io';

import 'package:cache/chat/answer_reports.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/platform/share_or_copy.dart' show saveFileInBrowser, shareOrCopy, systemShareAvailable;
import 'package:cache/screens/answer_reports_ui.dart';
import 'package:cache/screens/history_drawer.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/act_core_stand_in.dart';

class _Saved {
  _Saved(this.name, this.mime, this.text);
  final String name, mime, text;
}

void main() {
  final clipWrites = <String>[];
  final saved = <_Saved>[];
  final shared = <String>[];

  setUp(() {
    clipWrites.clear();
    saved.clear();
    shared.clear();
    final shareBefore = systemShareAvailable;
    final saveBefore = saveFileInBrowser;
    systemShareAvailable = () => false;
    saveFileInBrowser = (name, mime, Uint8List bytes) => saved.add(_Saved(name, mime, utf8.decode(bytes)));
    addTearDown(() {
      systemShareAvailable = shareBefore;
      saveFileInBrowser = saveBefore;
    });
  });

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipWrites.add('${(call.arguments as Map)['text']}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  testWidgets('chat Share as Markdown: Copy and Download; Copy fills the clipboard, Download saves the Markdown', (tester) async {
    mockClipboard(tester);
    final store = ConversationStore.memory(now: () => DateTime(2026, 10, 26, 8));
    addTearDown(store.close);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..attachStore(store);
    final c = store.create(title: 'Snake bite');
    store.addMessage(c.id, role: 'user', content: 'bite?', message: {'role': 'user', 'content': 'bite?'});
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Scaffold(
        drawer: HistoryDrawer(chat: chat, now: () => DateTime(2026, 10, 26, 14), share: (t, md) async => shared.add(md)),
        body: const SizedBox(),
      ),
    ));
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Snake bite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share as Markdown'));
    await tester.pumpAndSettle();
    expect(shared, isEmpty, reason: 'no share sheet to hand it to');
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(clipWrites.single, contains('# Snake bite'));
    expect(find.text('Copied.'), findsOneWidget);

    await tester.longPress(find.text('Snake bite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share as Markdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(saved.single.name, 'Snake bite.md');
    expect(saved.single.text, clipWrites.single, reason: 'the file has what Copy puts on the clipboard');
  });

  testWidgets('a report Share: Copy and Download with the report', (tester) async {
    mockClipboard(tester);
    final dir = Directory.systemTemp.createTempSync('web-share-reports');
    addTearDown(() => dir.deleteSync(recursive: true));
    final a = AnswerReports(dirOverride: dir);
    await tester.runAsync(() => a.add(AnswerReport(
          at: DateTime.utc(2026, 10, 27),
          question: 'How do I treat a burn?',
          answer: 'Cool it.',
          model: 'Gemma 4 E2B',
          reason: ReportReason.harmful,
        )));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: ReportedAnswersPage(reports: a, share: (t, md) async => shared.add(md))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    expect(shared, isEmpty);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(saved.single.name, 'Reported answer.md');
    expect(saved.single.text, contains('How do I treat a burn?'));
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(clipWrites.single, contains('How do I treat a burn?'));
    expect(find.text('Copied.'), findsOneWidget);
  });

  void failingClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') throw PlatformException(code: 'unavailable', message: 'clipboard blocked');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  testWidgets('Copy with a clipboard that fails says Couldn\'t copy, not Copied.', (tester) async {
    failingClipboard(tester);
    final dir = Directory.systemTemp.createTempSync('web-share-clip-fail');
    addTearDown(() => dir.deleteSync(recursive: true));
    final a = AnswerReports(dirOverride: dir);
    await tester.runAsync(() => a.add(AnswerReport(
          at: DateTime.utc(2026, 10, 27),
          question: 'How do I treat a burn?',
          answer: 'Cool it.',
          model: 'Gemma 4 E2B',
          reason: ReportReason.harmful,
        )));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: ReportedAnswersPage(reports: a, share: (t, md) async {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't copy. Use Download instead."), findsOneWidget);
    expect(find.text('Copied.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the link share with a clipboard that fails says Couldn\'t copy, not Link copied', (tester) async {
    failingClipboard(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () => shareOrCopy(context, 'cachelink://x', share: (t) async {}, copied: 'Link copied'), child: const Text('Go')),
        ),
      ),
    ));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't copy. Use Download instead."), findsOneWidget);
    expect(find.text('Link copied'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
