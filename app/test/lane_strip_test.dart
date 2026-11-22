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

    /// [n] lanes with the lanes at [use] (counted from 0, left to right) marked.
    String say(int n, Iterable<int> use) => laneLabel([for (var i = 0; i < n; i++) use.contains(i) ? l(active: D.through) : l()]);

    test('one lane at an edge: keep left or right', () {
      expect(say(4, [0]), 'Lanes: keep left');
      expect(say(4, [3]), 'Lanes: keep right');
      expect(say(2, [0]), 'Lanes: keep left');
      expect(say(2, [1]), 'Lanes: keep right');
    });

    test('a group touching an edge: use the N left or right lanes', () {
      expect(say(4, [2, 3]), 'Lanes: use the 2 right lanes');
      expect(say(3, [0, 1]), 'Lanes: use the 2 left lanes');
      expect(say(8, [5, 6, 7]), 'Lanes: use the 3 right lanes');
      expect(say(8, [0, 1, 2, 3, 4, 5, 6]), 'Lanes: use the 7 left lanes');
    });

    test('every lane works, or none is marked: use any lane', () {
      expect(say(2, [0, 1]), 'Lanes: use any lane');
      expect(say(5, [0, 1, 2, 3, 4]), 'Lanes: use any lane');
      expect(say(4, []), 'Lanes: use any lane');
      expect(say(1, [0]), 'Lanes: use any lane');
    });

    test('one lane not at an edge is counted from the nearer edge, and the exact middle of an odd count is the middle lane', () {
      expect(say(4, [1]), 'Lanes: use the 2nd lane from the left');
      expect(say(4, [2]), 'Lanes: use the 2nd lane from the right');
      expect(say(8, [2]), 'Lanes: use the 3rd lane from the left');
      expect(say(8, [5]), 'Lanes: use the 3rd lane from the right');
      expect(say(3, [1]), 'Lanes: use the middle lane');
      expect(say(5, [2]), 'Lanes: use the middle lane');
      expect(say(5, [1]), 'Lanes: use the 2nd lane from the left');
      expect(say(5, [3]), 'Lanes: use the 2nd lane from the right');
    });

    test('a tie between the edges is the left', () {
      expect(say(4, [1, 2]), 'Lanes: use the 2nd or 3rd lane from the left');
      expect(say(6, [1, 4]), 'Lanes: use the 2nd or 5th lane from the left');
      expect(say(4, [0, 3]), 'Lanes: use the 1st or 4th lane from the left');
    });

    test('a group not touching an edge, and scattered lanes, are listed from the nearer edge of the set', () {
      expect(say(6, [1, 2]), 'Lanes: use the 2nd or 3rd lane from the left');
      expect(say(8, [1, 2, 3]), 'Lanes: use the 2nd, 3rd or 4th lane from the left');
      expect(say(6, [3, 4]), 'Lanes: use the 2nd or 3rd lane from the right');
      expect(say(8, [4, 5, 6]), 'Lanes: use the 2nd, 3rd or 4th lane from the right');
      expect(say(4, [0, 2, 3]), 'Lanes: use the 1st, 3rd or 4th lane from the left');
      expect(say(5, [0, 2]), 'Lanes: use the 1st or 3rd lane from the left');
      expect(say(5, [2, 4]), 'Lanes: use the 1st or 3rd lane from the right');
      expect(say(8, [4, 6]), 'Lanes: use the 2nd or 4th lane from the right');
    });

    test('ordinals end correctly, including 11th, 12th, 13th, 21st, 22nd and 23rd', () {
      expect([for (final n in [1, 2, 3, 4, 10, 11, 12, 13, 14, 21, 22, 23, 24, 101, 111]) laneOrdinal(n)],
          ['1st', '2nd', '3rd', '4th', '10th', '11th', '12th', '13th', '14th', '21st', '22nd', '23rd', '24th', '101st', '111th']);
      expect(say(50, [10]), 'Lanes: use the 11th lane from the left');
      expect(say(50, [11]), 'Lanes: use the 12th lane from the left');
      expect(say(50, [12]), 'Lanes: use the 13th lane from the left');
      expect(say(50, [20]), 'Lanes: use the 21st lane from the left');
      expect(say(50, [21, 22]), 'Lanes: use the 22nd or 23rd lane from the left');
      expect(say(50, [8]), 'Lanes: use the 9th lane from the left');
    });

    test('never says "stay in"', () {
      for (var n = 2; n <= 9; n++) {
        for (var m = 1; m < (1 << n) - 1; m++) {
          final s = say(n, [for (var i = 0; i < n; i++) if (m & (1 << i) != 0) i]);
          expect(s, startsWith('Lanes: '));
          expect(s.contains('stay'), isFalse);
          expect(RegExp(r'^Lanes: (keep (left|right)|use (the (\d+ (left|right) lanes|middle lane|\d+(st|nd|rd|th)(, \d+(st|nd|rd|th))*( or \d+(st|nd|rd|th))? lane from the (left|right))|any lane))$').hasMatch(s), isTrue, reason: s);
        }
      }
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
