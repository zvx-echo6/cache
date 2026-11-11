import 'package:cache/nav/guidance.dart';
import 'package:cache/nav/ui/guidance_panels.dart';
import 'package:cache/nav/ui/lane_strip.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/lane_rig.dart';

typedef D = LaneDirection;

List<Map<String, dynamic>> _four() => [
      laneJson({D.through}),
      laneJson({D.through}),
      laneJson({D.through, D.right}, valid: D.through),
      laneJson({D.right}, active: D.right),
    ];

LaneGlyphPainter _glyph(WidgetTester tester, int i) => tester.widget<CustomPaint>(find.byKey(ValueKey('lane-glyph-$i'))).painter! as LaneGlyphPainter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fmt = Fmt(UnitSystem.imperial);
  final rig = LaneRig();
  setUp(rig.setUp);
  tearDown(rig.tearDown);

  Widget banner(ThemeData t, {double width = 390}) => laneHost(t, () => ListenableBuilder(listenable: rig.nav, builder: (_, _) => GuidanceBanner(nav: rig.nav, fmt: fmt)), width: width);

  final far = GuidanceEngine(fmt: fmt, mode: 'drive', destination: '').stages[0];

  group('when it shows', () {
    testWidgets('within the far voice stage, and not beyond it (read from the engine)', (tester) async {
      await rig.guide();
      expect(rig.nav.farStageM, far);
      await tester.pumpWidget(banner(buildTheme(CacheThemeId.light)));
      rig.turnAhead(far + 50, _four());
      await tester.pump();
      expect(find.byKey(const ValueKey('lane-strip')), findsNothing);
      rig.turnAhead(far - 50, _four());
      await tester.pump();
      expect(find.byKey(const ValueKey('lane-strip')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is LaneGlyphPainter).evaluate().length, 4);
      expect(tester.takeException(), isNull);
    });

    testWidgets('walking follows the walking far stage, not the driving one', (tester) async {
      await rig.guide(mode: 'walk');
      final walk = GuidanceEngine(fmt: fmt, mode: 'walk', destination: '').stages[0];
      expect(walk, lessThan(far));
      expect(rig.nav.farStageM, walk);
      await tester.pumpWidget(banner(buildTheme(CacheThemeId.light)));
      rig.turnAhead(walk + 40, _four());
      await tester.pump();
      expect(find.byKey(const ValueKey('lane-strip')), findsNothing);
      rig.turnAhead(walk - 40, _four());
      await tester.pump();
      expect(find.byKey(const ValueKey('lane-strip')), findsOneWidget);
    });

    testWidgets('hidden when the maneuver has no lanes', (tester) async {
      await rig.guide();
      await tester.pumpWidget(banner(buildTheme(CacheThemeId.light)));
      rig.turnAhead(300, const []);
      await tester.pump();
      expect(find.byKey(const ValueKey('lane-strip')), findsNothing);
      expect(find.byKey(const ValueKey('banner-distance')), findsOneWidget);
    });
  });

  group('the lanes', () {
    testWidgets('a lane that is only "none" (unmarked) is drawn as a plain straight arrow', (tester) async {
      await rig.guide();
      await tester.pumpWidget(banner(buildTheme(CacheThemeId.light)));
      rig.turnAhead(300, [laneJson({D.none}), laneJson({D.none}), laneJson({D.right}, active: D.right)]);
      await tester.pump();
      expect([for (final a in _glyph(tester, 0).arrows) a.direction], [D.through]);
      expect([for (final a in _glyph(tester, 1).arrows) a.direction], [D.through]);
      expect(laneGlyphDirections(const Lane()), [D.through]);
      expect(laneGlyphDirections(const Lane(directions: {D.none, D.left})), [D.left]);
    });

    for (final id in CacheThemeId.values) {
      testWidgets('lane to be in, lanes that also work, and lanes that do not, in the ${id.label} theme', (tester) async {
        final theme = buildTheme(id);
        final k = theme.extension<CacheTokens>()!;
        await rig.guide();
        await tester.pumpWidget(banner(theme));
        rig.turnAhead(300, _four());
        await tester.pump();
        // The lane to be in: its arrow in the accent colour, over an accent-tinted cell.
        final active = _glyph(tester, 3);
        expect(active.role, LaneRole.active);
        expect(active.arrows.last.direction, D.right);
        expect(active.arrows.last.color, k.accent);
        final cell = tester.widget<Container>(find.byKey(const ValueKey('lane-3')));
        expect((cell.decoration! as BoxDecoration).color, k.accent.withValues(alpha: 0.18));
        // Another lane that works: the secondary tone, no tint.
        final valid = _glyph(tester, 2);
        expect(valid.role, LaneRole.valid);
        expect({for (final a in valid.arrows) a.color}, {laneValidColor(k)});
        expect(tester.widget<Container>(find.byKey(const ValueKey('lane-2'))).decoration, isNull);
        // Lanes that do not work: dimmed.
        final dim = _glyph(tester, 0);
        expect(dim.role, LaneRole.dim);
        expect(dim.arrows.single.color, laneDimColor(k));
        expect(dim.arrows.single.color.a, 1.0);
        // Valid and dim must be told apart at a glance in every theme.
        expect((valid.arrows.first.color.computeLuminance() - dim.arrows.single.color.computeLuminance()).abs(), greaterThan(0.08));
      });
    }

    testWidgets('lanes with no hint of which work are all drawn alike, not all dimmed', (tester) async {
      await rig.guide();
      await tester.pumpWidget(banner(buildTheme(CacheThemeId.light)));
      rig.turnAhead(300, [laneJson({D.left}), laneJson({D.through})]);
      await tester.pump();
      expect(_glyph(tester, 0).role, LaneRole.plain);
      expect(_glyph(tester, 1).role, LaneRole.plain);
    });

    for (final width in [390.0, 300.0]) {
      testWidgets('8 lanes fit in ${width.toInt()} px wide, with no overflow and no scrolling', (tester) async {
        await rig.guide();
        await tester.pumpWidget(banner(buildTheme(CacheThemeId.light), width: width));
        rig.turnAhead(300, [for (var i = 0; i < 8; i++) laneJson({D.through, if (i > 5) D.right}, active: i > 5 ? D.right : null, valid: i == 5 ? D.through : null)]);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final strip = tester.getRect(find.byKey(const ValueKey('lane-strip')));
        final bannerBox = tester.getRect(find.byKey(const ValueKey('guidance-banner')));
        expect(strip.width, lessThanOrEqualTo(bannerBox.width - 20));
        expect(strip.left, greaterThanOrEqualTo(bannerBox.left));
        expect(find.byType(Scrollable), findsNothing);
        expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is LaneGlyphPainter).evaluate().length, 8);
      });
    }
  });

  group('the screen-reader label', () {
    Lane l({LaneDirection? active, LaneDirection? valid}) => Lane(directions: const {D.through}, active: active, valid: valid);

    test('names the lanes to use, from the data', () {
      expect(laneLabel([l(), l(), l(valid: D.through), l(active: D.right)]), 'Lanes: use the 2 right lanes');
      expect(laneLabel([l(active: D.left), l(valid: D.left), l()]), 'Lanes: use the 2 left lanes');
      expect(laneLabel([l(), l(), l(active: D.right)]), 'Lanes: use the right lane');
      expect(laneLabel([l(active: D.left), l(), l()]), 'Lanes: use the left lane');
      expect(laneLabel([l(), l(active: D.through), l()]), 'Lanes: use lane 2');
      expect(laneLabel([l(active: D.through), l(), l(active: D.through), l(active: D.through)]), 'Lanes: use lanes 1, 3 and 4');
      expect(laneLabel([l(), l()]), 'Lanes: use any lane');
    });

    testWidgets('is on the strip', (tester) async {
      final h = tester.ensureSemantics();
      await rig.guide();
      await tester.pumpWidget(banner(buildTheme(CacheThemeId.light)));
      rig.turnAhead(300, _four());
      await tester.pump();
      expect(find.bySemanticsLabel('Lanes: use the 2 right lanes'), findsOneWidget);
      h.dispose();
    });
  });
}
