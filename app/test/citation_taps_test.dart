// Every kind of citation in Ask, tapped: what opens and where (the reader at a page, a PDF page or an EPUB chapter with the
// passage marked; the player at a moment), and what does not open at all.
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/act_core_stand_in.dart';

const _u = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

/// The citations as the core numbers them (address, and where it opens: link, time, page, quote, language).
const _sources = [
  // a ZIM page
  NumberedResult(1, SourceResult(title: 'Water', snippet: '', address: 'zim:$_u/A/Water')),
  // a passage of a ZIM's PDF: its index address, and the PDF entry at the page as its link
  NumberedResult(2, SourceResult(
    title: 'Water and Shelter Handbook, p. 47',
    snippet: '',
    address: 'zimpdf:$_u/Manuals/water.pdf@3',
    link: 'zim:$_u/Manuals/water.pdf#page=49',
    pdfPage: 49,
    quote: 'If you cannot boil water',
  )),
  // a passage of an EPUB in a ZIM: the chapter at its block anchor
  NumberedResult(3, SourceResult(
    title: 'Field Guide, Wildfire',
    snippet: '',
    address: 'zimepub:$_u/Books/guide.epub@7',
    link: 'zim:$_u/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12',
    quote: 'Clear a firebreak around',
  )),
  // words said in a ZIM's video
  NumberedResult(4, SourceResult(
    title: 'Knots, at 00:12',
    snippet: '',
    address: 'zimcap:$_u/Media/knots_en.srt@4',
    link: 'zim:$_u/Media/knots.mp4',
    time: 12,
    timeEnd: 18,
    lang: 'en',
    quote: 'A loop that',
  )),
  // words said in a saved video
  NumberedResult(5, SourceResult(
    title: 'Flood Safety Basics, at 01:04',
    snippet: '',
    address: 'cap:tube.example.org/v1/captions-es.vtt@2',
    link: 'https://tube.example.org/w/v1',
    time: 64,
    lang: 'es',
    quote: 'barreras de sacos',
  )),
  // a place, a web page and a guide section: not opened from here (as before)
  NumberedResult(6, SourceResult(title: 'Twin Falls', snippet: '', address: 'place:osm:w1')),
  NumberedResult(7, SourceResult(title: 'Boiling water at altitude', snippet: '', address: 'web:https://example.org/boil')),
  NumberedResult(8, SourceResult(title: 'Cache guide: 1. Getting started: Choose a model', snippet: '', address: 'lib:cache-guide/0f6e')),
];

void main() {
  testWidgets('each citation opens where it points, and only those the reader or the player can show', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('citation-taps-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
    chat.messages.add(ChatMessage.assistant()
      ..phase = TurnPhase.done
      ..text = 'Boil it [1][2][3][4][5][6][7][8].'
      ..sources = _sources);
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: AskScreen(
        app: app,
        chat: chat,
        onOpenSource: (a) => opened.add('source $a'),
        onOpenPassage: (a, q) => opened.add('passage $a | $q'),
        onOpenVideo: (l, t, lang) => opened.add('video $l @ $t $lang'),
      ),
    ));
    await tester.tap(find.text('8 sources'));
    await tester.pumpAndSettle();

    Future<String?> tap(int n) async {
      final row = find.textContaining('[$n] ');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      opened.clear();
      await tester.tap(row);
      await tester.pump();
      return opened.isEmpty ? null : opened.single;
    }

    expect(await tap(1), 'source zim:$_u/A/Water');
    expect(await tap(2), 'passage zim:$_u/Manuals/water.pdf#page=49 | If you cannot boil water');
    expect(await tap(3), 'passage zim:$_u/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12 | Clear a firebreak around');
    expect(await tap(4), 'video zim:$_u/Media/knots.mp4 @ 12.0 en');
    expect(await tap(5), 'video https://tube.example.org/w/v1 @ 64.0 es');
    expect(await tap(6), isNull);
    expect(await tap(7), isNull);
    expect(await tap(8), isNull);

    // "Open the article" is under what opens in the reader: the page, the PDF passage and the EPUB passage
    expect(find.text('Open the article'), findsNWidgets(3));

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    chat.dispose();
  });

  test('readerAddress: what the reader can show, and nothing for the rest', () {
    expect([for (final s in _sources) s.result.readerAddress], [
      'zim:$_u/A/Water',
      'zim:$_u/Manuals/water.pdf#page=49',
      'zim:$_u/Books/guide.epub!/OEBPS/ch2.xhtml#cache-b12',
      // a caption's own address is not the reader's; it opens in the player (isVideoMoment)
      null,
      null,
      null,
      null,
      null,
    ]);
  });
}
