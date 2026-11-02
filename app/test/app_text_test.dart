import 'package:cache/chat/answer_markdown.dart';
import 'package:cache/chat/model_name.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('prettyModelName', () {
    test('formats the description for people', () {
      expect(prettyModelName('gemma4 E2B Q4_K - Medium'), 'Gemma 4 E2B · Q4_K_M');
      expect(prettyModelName('llama 8B Q4_K - Small'), 'Llama 8B · Q4_K_S');
      expect(prettyModelName('qwen3 4B Q8_0'), 'Qwen 3 4B · Q8_0');
      expect(prettyModelName('llama 7B IQ4_XS - 4.25 bpw'), 'Llama 7B · IQ4_XS');
    });
    test('unreadable input is kept as it came', () {
      expect(prettyModelName(''), '');
      expect(prettyModelName('Q4_K - Medium'), 'Q4_K - Medium');
      expect(prettyModelName('weird-model'), 'weird-model');
    });
  });

  group('protectCitations', () {
    test('escapes markers outside code only', () {
      expect(protectCitations('Cool it [1](x) and [2].'), r'Cool it \[1\](x) and \[2\].');
      expect(protectCitations('use `a[1]` [3]'), r'use `a[1]` \[3\]');
      expect(protectCitations('```\nb[2]\n```\n[4]'), '```\nb[2]\n```\n\\[4\\]');
    });
  });

  testWidgets('answers render as markdown and keep [1] as text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: const Scaffold(body: AnswerMarkdown('# Title\n\nUse **cold water** [1](http://x) now.\n\n- one\n- two')),
    ));
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('[1]', findRichText: true), findsOneWidget);
    expect(find.textContaining('**', findRichText: true), findsNothing);
  });
}
