// The lane strip on the phone's guidance panel for review (feat/phone-lane-strip): the real turn banner and bottom bar over a fake
// progress, 390 wide, in the light, dark and Tactical themes. Lanes show once the turn is within the far voice stage (800 m by car).
// flutter test test_shots/lane_strip_renders_test.dart --update-goldens  (pictures in test_shots/lane_strip/)

import 'package:cache/nav/ui/guidance_panels.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/lane_rig.dart';
import 'shot_kit.dart';

const _out = 'lane_strip';
typedef D = LaneDirection;

class _Case {
  const _Case(this.name, this.metres, this.lanes, {this.type, this.instruction});
  final String name;
  final double metres;
  final List<Map<String, dynamic>> lanes;
  final String? type, instruction;
}

final _cases = [
  _Case('1-highway-exit', 600, [laneJson({D.through}), laneJson({D.through}), laneJson({D.through}), laneJson({D.right}, active: D.right)], type: 'exit_right', instruction: 'Take the exit on the right onto Road 1.'),
  _Case('2-left-turn', 400, [laneJson({D.left}, active: D.left), laneJson({D.left, D.through}, valid: D.left), laneJson({D.through})], type: 'left', instruction: 'Turn left onto Road 1.'),
  _Case('3-six-lanes-through-and-right', 700, [
    laneJson({D.through}),
    laneJson({D.through}),
    laneJson({D.through}),
    laneJson({D.through, D.right}, valid: D.right),
    laneJson({D.through, D.right}, active: D.right),
    laneJson({D.right}, active: D.right),
  ], type: 'right', instruction: 'Turn right onto Road 1.'),
  _Case('4-unmarked-lane', 500, [laneJson({D.none}), laneJson({D.through}), laneJson({D.through, D.right}, valid: D.through), laneJson({D.right}, active: D.right)], type: 'right', instruction: 'Turn right onto Road 1.'),
  _Case('5-beyond-800m-no-strip', 1200, [laneJson({D.through}), laneJson({D.through}), laneJson({D.through}), laneJson({D.right}, active: D.right)], type: 'exit_right', instruction: 'Take the exit on the right onto Road 1.'),
  _Case('6-eight-lanes', 600, [for (var i = 0; i < 8; i++) laneJson({D.through, if (i > 5) D.right}, active: i > 5 ? D.right : null, valid: i == 5 ? D.right : null)], type: 'right', instruction: 'Turn right onto Road 1.'),
  _Case('7-uturn-and-merge', 450, [laneJson({D.reverse}), laneJson({D.left}, active: D.left), laneJson({D.slightLeft, D.through}, valid: D.slightLeft), laneJson({D.mergeToLeft}), laneJson({D.sharpRight})], type: 'left', instruction: 'Turn left onto Road 1.'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fmt = Fmt(UnitSystem.imperial);
  final rig = LaneRig();
  setUpAll(loadShotFonts);
  setUp(rig.setUp);
  tearDown(rig.tearDown);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    for (final c in _cases) {
      testWidgets('${c.name} in the ${theme.label} theme', (tester) async {
        phone(tester, size: const Size(390, 215), ratio: 3);
        await rig.guide();
        rig.turnAhead(c.metres, c.lanes, type: c.type, instruction: c.instruction);
        final k = buildTheme(theme).extension<CacheTokens>()!;
        await tester.pumpWidget(shotApp(
          theme: theme,
          insets: EdgeInsets.zero,
          Scaffold(
            backgroundColor: Color.alphaBlend(k.secondary.withValues(alpha: 0.25), k.background),
            body: Padding(
              padding: const EdgeInsets.all(12),
              child: ListenableBuilder(
                listenable: rig.nav,
                builder: (_, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  GuidanceBanner(nav: rig.nav, fmt: fmt),
                  const Spacer(),
                  DecoratedBox(decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(20)), child: GuidanceBar(nav: rig.nav, fmt: fmt, bare: true)),
                ]),
              ),
            ),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('lane-strip')).evaluate().isNotEmpty, c.metres <= 800);
        await snap(tester, _out, '${c.name}-${theme == CacheThemeId.tactical ? 'tactical' : theme.name}');
      });
    }
  }
}
