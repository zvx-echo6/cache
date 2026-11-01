import 'dart:io';

import 'package:cache/layout/adaptive.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// A two-pane page as Settings, Regions, Notebooks, Library and the guide build one: a list with "Hide list" in its top bar
/// and rows that open their page in the detail pane, whose top bar has "Show Things" while the list is hidden.
class _List extends StatelessWidget {
  const _List();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Things'), actions: [?paneHideButton(context)]),
        body: ListView(children: [
          for (final n in ['Alpha', 'Bravo'])
            ListTile(title: Text(n), onTap: () => openDetail(context, key: n, builder: (_) => _Detail(n))),
        ]),
      );
}

class _Detail extends StatelessWidget {
  const _Detail(this.name);
  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(leading: paneShowButton(context), title: Text('$name page')),
        body: Center(child: TextButton(onPressed: () {}, child: Text('$name action'))),
      );
}

/// The screen-reader node of an icon button with [key]: there, read out as [tooltip], and with the tap action.
SemanticsNode? _button(WidgetTester tester, String key, String tooltip) {
  final f = find.byKey(ValueKey(key));
  if (f.evaluate().isEmpty) return null;
  final node = tester.getSemantics(f);
  final data = node.getSemanticsData();
  expect(data.tooltip, tooltip);
  expect(data.hasAction(SemanticsAction.tap), isTrue, reason: '"$tooltip" can be activated by a screen reader');
  return node;
}

/// Every label and tooltip in the semantics tree (what a screen reader can reach).
List<String> _reachable(WidgetTester tester) {
  final out = <String>[];
  bool visit(SemanticsNode n) {
    if (n.label.isNotEmpty) out.add(n.label);
    if (n.tooltip.isNotEmpty) out.add(n.tooltip);
    n.visitChildren(visit);
    return true;
  }

  visit(tester.getSemantics(find.byType(Navigator).first).owner!.rootSemanticsNode!);
  return out;
}

void main() {
  for (final size in [const Size(1920, 1080), const Size(1180, 820)]) {
    testWidgets('at ${size.width.toInt()}x${size.height.toInt()} the shown list is in the semantics tree and works; a hidden one is not',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('panes-');
      PanePrefs.testDir = dir;
      addTearDown(() {
        PanePrefs.testDir = null;
        dir.deleteSync(recursive: true);
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: TwoPane(id: 'things', listName: 'Things', list: const _List(), initialKey: 'Alpha', initial: (_) => const _Detail('Alpha')),
      ));
      await tester.pumpAndSettle();

      // Shown: the rows and "Hide list" are there for a screen reader, beside the detail page.
      expect(find.bySemanticsLabel('Alpha'), findsOneWidget);
      expect(find.bySemanticsLabel('Bravo'), findsOneWidget);
      expect(_button(tester, 'pane-hide', 'Hide list'), isNotNull);
      expect(find.bySemanticsLabel('Alpha page'), findsOneWidget);
      expect(find.bySemanticsLabel('Alpha action'), findsOneWidget);
      // and they work: a row opens its page in the detail pane
      final bravo = tester.getSemantics(find.bySemanticsLabel('Bravo'));
      expect(bravo.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      bravo.owner!.performAction(bravo.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Bravo page'), findsOneWidget);
      expect(find.bySemanticsLabel('Alpha'), findsOneWidget, reason: 'the list is still there after the detail page changed');

      // "Hide list" hides it: its rows and button leave the tree, "Show Things" comes.
      final hide = _button(tester, 'pane-hide', 'Hide list')!;
      hide.owner!.performAction(hide.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(_reachable(tester), isNot(anyOf(contains('Alpha'), contains('Bravo'), contains('Hide list'))));
      expect(_reachable(tester), contains('Bravo page'));
      expect(_button(tester, 'pane-show', 'Show Things'), isNotNull);
      expect(find.bySemanticsLabel('Bravo page'), findsOneWidget);

      // "Show Things" brings it back, in the tree again.
      final show = _button(tester, 'pane-show', 'Show Things')!;
      show.owner!.performAction(show.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(_reachable(tester), containsAll(['Alpha', 'Bravo', 'Hide list']));
      expect(_button(tester, 'pane-hide', 'Hide list'), isNotNull);
      semantics.dispose();
    });
  }
}
