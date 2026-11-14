// Everything on screen in Ask that points at something opens it: citation rows of every kind, the [n] marks in the answer, the
// steps list, the confirm card and the reported answers. What opens is what the shell is asked for (the callbacks here stand in
// for its routes); nothing the model reads changes.
import 'dart:io';

import 'package:cache/actions/action_registry.dart';
import 'package:cache/actions/confirm.dart';
import 'package:cache/app_state.dart';
import 'package:cache/chat/answer_markdown.dart';
import 'package:cache/chat/ask_target.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/navigation_action.dart';
import 'package:cache/chat/progress_steps.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/confirm_card.dart';
import 'package:cache/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/act_core_stand_in.dart';

const _u = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

const _sources = [
  NumberedResult(1, SourceResult(title: 'Twin Falls', snippet: '', address: 'place:osm:w1')),
  NumberedResult(2, SourceResult(title: 'Burley', snippet: '', address: 'town:osm:n98')),
  NumberedResult(3, SourceResult(title: '321 2nd Ave E', snippet: '', address: 'addr:u7/321')),
  NumberedResult(4, SourceResult(title: 'Your position', snippet: '', address: 'loc:42.5,-114.4')),
  NumberedResult(5, SourceResult(title: 'North gate', snippet: '', address: 'layer:y1/3')),
  NumberedResult(6, SourceResult(title: 'TEST1', snippet: '', address: 'repeater:l1/2')),
  NumberedResult(7, SourceResult(title: 'KD7ABC', snippet: '', address: 'repeater:0b3f6e2a-entry')),
  NumberedResult(8, SourceResult(title: 'Wind at Cabin', snippet: '', address: 'live:nws/cabin-key/wind')),
  NumberedResult(9, SourceResult(title: 'Set up: Models', snippet: '', address: 'app:setup/models')),
  NumberedResult(10, SourceResult(title: 'To Cassia Hospital', snippet: '', address: 'nav:r1')),
  // a ZIM PDF passage that came with only the index address and its page and passage
  NumberedResult(11, SourceResult(title: 'Water Handbook, p. 49', snippet: '', address: 'zimpdf:$_u/Manuals/water.pdf@3', pdfPage: 49, quote: 'If you cannot boil water')),
  // an EPUB passage with only the index address: nothing in it says where in the book it is
  NumberedResult(12, SourceResult(title: 'Field Guide', snippet: '', address: 'zimepub:$_u/Books/guide.epub@7', quote: 'Clear a firebreak')),
  NumberedResult(13, SourceResult(title: 'A web page', snippet: '', address: 'web:https://example.org/x')),
];

Future<(AppState, ChatController)> _app(WidgetTester tester, Directory dir, ChatMessage msg) async {
  tester.view.physicalSize = const Size(1200, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
  final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
  chat.messages.add(msg);
  addTearDown(() {
    app.dispose();
    chat.dispose();
  });
  return (app, chat);
}

Future<void> _show(WidgetTester tester, AppState app, ChatController chat, List<String> log, {ActionRegistry? actions}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(CacheThemeId.dark),
    home: AskScreen(
      app: app,
      chat: chat,
      onOpenSource: (a) => log.add('source $a'),
      onOpenPassage: (a, q) => log.add('passage $a | $q'),
      onOpenVideo: (l, t, lang) => log.add('video $l'),
      onOpenNavigation: (a) => log.add('navigation ${a.address}'),
      onOpenTarget: (t) => log.add('$t'),
    ),
  ));
}

/// The spans of every rich text on screen (the answer's markdown is selectable text), grouped by their tap recognizer: the text of
/// each tappable run, with what its tap does.
Map<String, VoidCallback> _tappable(WidgetTester tester) {
  final groups = <GestureRecognizer, StringBuffer>{};
  void walk(InlineSpan s) {
    if (s is! TextSpan) return;
    final r = s.recognizer;
    if (r != null && s.text != null) (groups[r] ??= StringBuffer()).write(s.text);
    s.children?.forEach(walk);
  }

  for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(w.text);
  }
  for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    final t = w.textSpan;
    if (t != null) walk(t);
  }
  return {for (final e in groups.entries) e.value.toString(): (e.key as TapGestureRecognizer).onTap!};
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ask-links-'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('citation rows', () {
    testWidgets('each kind opens its target through the route for it', (tester) async {
      final msg = ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'See the sources.'
        ..sources = _sources
        ..navigationActions = [NavigationAction(address: 'nav:r1')];
      final (app, chat) = await _app(tester, dir, msg);
      final log = <String>[];
      await _show(tester, app, chat, log);
      await tester.tap(find.text('13 sources'));
      await tester.pumpAndSettle();

      Future<String?> tap(int n) async {
        final row = find.textContaining('[$n] ');
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        log.clear();
        await tester.tap(row);
        await tester.pump();
        return log.isEmpty ? null : log.single;
      }

      // 1. places: Maps with the place selected
      expect(await tap(1), 'AskPlace(place:osm:w1, Twin Falls, null, null)');
      expect(await tap(2), 'AskPlace(town:osm:n98, Burley, null, null)');
      expect(await tap(3), 'AskPlace(addr:u7/321, 321 2nd Ave E, null, null)');
      expect(await tap(4), 'AskPlace(loc:42.5,-114.4, Your position, null, null)');
      // 2. layer points
      expect(await tap(5), 'AskLayerPoint(layer:y1/3)');
      // 3. a repeater of a list, and a notebook entry (a repeater of a notebook is the entry's own id)
      expect(await tap(6), 'AskRepeaterPoint(repeater:l1/2)');
      expect(await tap(7), 'AskNotebookEntry(0b3f6e2a-entry)');
      // 4. live data
      expect(await tap(8), 'AskLive(live:nws/cabin-key/wind)');
      // 5. the setup: the guide section, through the shell's source route
      expect(await tap(9), 'source app:setup/models');
      // 6. a route: as the "Open navigation" button does
      expect(await tap(10), 'navigation nav:r1');
      // 7. a ZIM PDF passage with only its index address opens the PDF at its page with the passage marked
      expect(await tap(11), 'passage zim:$_u/Manuals/water.pdf#page=49 | If you cannot boil water');
      // an EPUB passage with only the index address says nothing of where it is: no target (the core's link is needed)
      expect(await tap(12), isNull);
      // a web page stays off (an owner decision is pending)
      expect(await tap(13), isNull);
    });

    test('the address kinds the core gives, and the ones that point at nothing', () {
      expect(askTargetOfAddress('place:osm:w1', 'T'), isA<AskPlace>());
      expect(askTargetOfAddress('layer:y1/3', 'T'), isA<AskLayerPoint>());
      expect(askTargetOfAddress('repeater:l1/2', 'T'), isA<AskRepeaterPoint>());
      expect(askTargetOfAddress('repeater:abc', 'T'), isA<AskNotebookEntry>());
      expect(askTargetOfAddress('live:nws/k/i', 'T'), isA<AskLive>());
      expect(askTargetOfAddress('zim:$_u/A/B', 'T'), isNull);
      expect(askTargetOfAddress('web:https://x/', 'T'), isNull);
      expect(askTargetOfAddress('place:', 'T'), isNull);
      expect(listItemParts('layer:y1/3'), (list: 'y1', ord: 3));
      expect(liveParts('live:nws/cabin/wind/x')?.placeKey, 'cabin');
    });

    test('a ZIM PDF passage keeps its page: the entry at that page, or the entry alone without one', () {
      const withPage = SourceResult(title: 't', snippet: '', address: 'zimpdf:$_u/M/w.pdf@3', pdfPage: 7);
      const without = SourceResult(title: 't', snippet: '', address: 'zimpdf:$_u/M/w.pdf@3');
      expect(withPage.readerAddress, 'zim:$_u/M/w.pdf#page=7');
      expect(without.readerAddress, 'zim:$_u/M/w.pdf');
    });
  });

  group('the [n] marks in the answer', () {
    testWidgets('a mark does what its source row does; a range does what its first does', (tester) async {
      final msg = ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'The place [1] and the town [2-3] and the set up [9] and the web page [13].'
        ..sources = _sources
        ..navigationActions = [NavigationAction(address: 'nav:r1')];
      final (app, chat) = await _app(tester, dir, msg);
      final log = <String>[];
      await _show(tester, app, chat, log);
      final marks = _tappable(tester);
      expect(marks.keys, containsAll(['[1]', '[2-3]', '[9]']));
      // [13] is a web page: its row does nothing, so its mark is plain
      expect(marks.keys, isNot(contains('[13]')));

      marks['[1]']!();
      expect(log.removeLast(), 'AskPlace(place:osm:w1, Twin Falls, null, null)');
      marks['[2-3]']!();
      expect(log.removeLast(), 'AskPlace(town:osm:n98, Burley, null, null)');
      marks['[9]']!();
      expect(log.removeLast(), 'source app:setup/models');
    });

    test('the marks become links only where asked, and web links are not touched', () {
      expect(protectCitations('a [1] b [2, 3] c'), r'a \[1\] b [2, 3] c');
      expect(protectCitations('a [1] b [2, 3] [0]', linked: (n) => n == 1 || n == 2), r'a [\[1\]](cite:1) b [\[2, 3\]](cite:2) \[0\]');
      expect(protectCitations('see `[1]` here', linked: (_) => true), 'see `[1]` here');
      expect(citeNumberOfLink('cite:4'), 4);
      expect(citeNumberOfLink('https://example.org'), isNull);
    });
  });

  group('the steps list', () {
    testWidgets('each step with a target opens it, and the ones with none stay plain', (tester) async {
      const zimPage = SourceResult(title: 'Water', snippet: '', address: 'zim:$_u/A/Water');
      final msg = ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'Done.'
        ..sources = const [NumberedResult(1, zimPage)]
        ..steps = [
          const ToolStep('search', {'query': 'boil water'}),
          const ToolStep('read', {'n': 1}, 'Water', zimPage),
          const ToolStep('read', {'n': 2}, 'Twin Falls', SourceResult(title: 'Twin Falls', snippet: '', address: 'place:osm:w1')),
          const ToolStep('nearby', {'category': 'gas_station'}),
          ToolStep('navigate', const {'to': 'Cassia Hospital'}, null, null, [NavigationAction(address: 'nav:r1')]),
          const ToolStep('calculate', {}),
          const ToolStep('locate', {}),
          const ToolStep('read', {'n': 9}, 'Gone'),
        ];
      final (app, chat) = await _app(tester, dir, msg);
      final log = <String>[];
      await _show(tester, app, chat, log);
      await tester.tap(find.byKey(const ValueKey('answer-trail-toggle')));
      await tester.pumpAndSettle();

      Future<String?> tap(String line) async {
        log.clear();
        await tester.tap(find.text(line));
        await tester.pump();
        return log.isEmpty ? null : log.single;
      }

      // "Searched your library for ..." opens Home search with that query
      expect(await tap('Searched your library for "boil water"'), 'AskHomeSearch(boil water)');
      // "Read <title>" opens what was read
      expect(await tap('Read Water'), 'source zim:$_u/A/Water');
      expect(await tap('Read Twin Falls'), 'AskPlace(place:osm:w1, Twin Falls, null, null)');
      // "Searched nearby for ..." opens Maps' search for that kind
      expect(await tap('Searched nearby for: gas station'), 'AskMapSearch(gas station)');
      // "Planned a route ..." opens the route
      expect(await tap('Planned a route to Cassia Hospital'), 'navigation nav:r1');
      // steps with no target stay plain: no tap target, nothing happens
      for (final plain in ['Calculated', 'Found where you are', 'Read Gone']) {
        expect(find.ancestor(of: find.text(plain), matching: find.byType(InkWell)), findsNothing, reason: plain);
      }
      expect(await tap('Calculated'), isNull);
      expect(await tap('Found where you are'), isNull);
    });
  });

  group('the confirm card', () {
    ConfirmCard card({ConfirmState state = ConfirmState.open}) => ConfirmCard(
          confirmId: 'c1',
          toolCallId: 't1',
          action: 'places.save',
          title: 'Save a place',
          summary: const [MapEntry('name', 'Elk camp'), MapEntry('place', '44.21, -114.93')],
          fields: const {},
          state: state,
        );

    Future<void> pump(WidgetTester tester, ConfirmCard c, CardTargets? targets, List<AskTarget> opened) => tester.pumpWidget(MaterialApp(
          theme: buildTheme(CacheThemeId.dark),
          home: Scaffold(body: ConfirmCardView(card: c, onDecide: (_) {}, targets: targets, onOpen: opened.add)),
        ));

    testWidgets('a named place and notebook open, and so does the Done line', (tester) async {
      final opened = <AskTarget>[];
      const place = AskPlace(address: 'loc:44.210000,-114.930000', title: 'Elk camp', lat: 44.21, lon: -114.93);
      const book = AskNotebook(notebookId: 'nb1');
      final targets = const CardTargets(title: book, lines: {'Place': place}, done: place);

      await pump(tester, card(), targets, opened);
      await tester.tap(find.text('Place: 44.21, -114.93'));
      await tester.tap(find.byKey(const ValueKey('confirm-title-c1')));
      expect(opened, [place, book]);
      // a line that names nothing stays plain
      opened.clear();
      await tester.tap(find.text('Name: Elk camp'));
      expect(opened, isEmpty);

      // after Done, the outcome line opens what was made
      await pump(tester, card(state: ConfirmState.done), targets, opened);
      await tester.tap(find.text('Done'));
      expect(opened, [place]);

      // not done (canceled or failed), or nothing made: the outcome line stays plain
      opened.clear();
      await pump(tester, card(state: ConfirmState.declined), targets, opened);
      await tester.tap(find.text('Canceled'));
      await pump(tester, card(state: ConfirmState.done), const CardTargets(), opened);
      await tester.tap(find.text('Done'));
      expect(opened, isEmpty);
    });

    test('a done outcome keeps what the action returned, for its Done line', () {
      final c = card();
      c.apply({'confirm_id': 'c1', 'status': 'done', 'result': {'name': 'Elk camp', 'lat': 44.21, 'lon': -114.93}});
      expect(c.state, ConfirmState.done);
      expect(c.result?['name'], 'Elk camp');
    });

    test('the registry gives a module its card targets and survives one that throws', () {
      final reg = ActionRegistry();
      reg.publish('places', [
        {'id': 'places.save', 'module': 'places', 'title': 'Save a place', 'description': 'Save.', 'effect': 'change', 'fields': {'name': {'type': 'string'}}, 'required': ['name']},
      ], {
        'places.save': (f) async => {'ok': true},
      }, cardTargets: {
        'places.save': (f, result) => CardTargets(done: result == null ? null : const AskNotebook(notebookId: 'x')),
      });
      expect(reg.cardTargets('places.save', const {}, null)?.done, isNull);
      expect(reg.cardTargets('places.save', const {}, const {'a': 1})?.done, isA<AskNotebook>());
      expect(reg.cardTargets('nothing', const {}, null), isNull);
    });
  });
}
