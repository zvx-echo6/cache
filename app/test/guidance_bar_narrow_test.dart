// The guidance bar on a narrow phone (320, 360, 390 wide): arrival time, time left and distance to go stay three separate, whole,
// readable values (no overlap, no ellipsis, a gap between them) even with the longest values. The 390 bar is the form of before and
// is held as it was: it must lay out whole and not overlap, but its gap between values is whatever its three equal cells leave.

import 'package:cache/nav/ui/guidance_panels.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../test_shots/shot_kit.dart';
import 'nav_fakes.dart';
import 'support/lane_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fmt = Fmt(UnitSystem.imperial);
  final rig = LaneRig();
  setUpAll(loadShotFonts);
  setUp(rig.setUp);
  tearDown(rig.tearDown);

  Future<void> pumpBar(WidgetTester tester, double width, {required DateTime eta, required int seconds, required double metres}) async {
    tester.view.physicalSize = Size(width, 568) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await rig.guide();
    final j = fakeProgressJson(rig.route, 0.3);
    rig.nav.progress = MapProgress.fromJson({
      ...j,
      'remaining': {'distance_m': metres, 'duration_s': seconds, 'eta': eta.toIso8601String()},
    });
    rig.nav.poke();
    await tester.pumpWidget(shotApp(
      insets: EdgeInsets.zero,
      Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ListenableBuilder(listenable: rig.nav, builder: (_, _) => GuidanceBar(nav: rig.nav, fmt: fmt)),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  const keys = [ValueKey('bar-eta'), ValueKey('bar-time'), ValueKey('bar-distance')];
  final longest = (eta: DateTime(2026, 11, 13, 12, 59), seconds: 83 * 60, metres: 999 * 1609.344);
  final typical = (eta: DateTime(2026, 11, 13, 19, 2), seconds: 23 * 60, metres: 17 * 1609.344);

  for (final width in [320.0, 360.0, 390.0]) {
    for (final (name, v) in [('the longest values', longest), ('ordinary values', typical)]) {
      testWidgets('${width.toInt()} wide, $name: three separate whole values', (tester) async {
        await pumpBar(tester, width, eta: v.eta, seconds: v.seconds, metres: v.metres);
        final narrow = width < 384; // the card is 24 less: narrower than 360
        expect(tester.takeException(), isNull, reason: 'the bar overflowed');
        final rects = [for (final k in keys) tester.getRect(find.byKey(k))];
        for (var i = 0; i < 3; i++) {
          final text = tester.widget<Text>(find.byKey(keys[i]));
          expect(text.overflow, isNull, reason: 'a value that can be cut with an ellipsis');
          expect(tester.renderObject<RenderParagraph>(find.byKey(keys[i])).didExceedMaxLines, isFalse);
          // laid out whole: the on-screen size is a scale of the laid-out size, and the type stays readable (11.5 points or more).
          final scale = rects[i].width / tester.getSize(find.byKey(keys[i])).width;
          expect(text.style!.fontSize! * scale, greaterThanOrEqualTo(narrow ? 11.5 : 0), reason: 'value ${text.data} is drawn too small to read');
        }
        for (var i = 0; i < 2; i++) {
          expect(rects[i + 1].left - rects[i].right, greaterThanOrEqualTo(narrow ? 6 : 0), reason: '${(keys[i]).value} and ${(keys[i + 1]).value} run together');
        }
        // The voice switch and End stay on the screen, clear of the values.
        final voice = tester.getRect(find.byKey(const ValueKey('guidance-voice')));
        final end = tester.getRect(find.byKey(const ValueKey('guidance-end')));
        expect(rects.first.left - voice.right, greaterThanOrEqualTo(narrow ? 6 : 0));
        expect(end.left - rects.last.right, greaterThanOrEqualTo(narrow ? 6 : 0));
        expect(end.right, lessThanOrEqualTo(width));
      });
    }
  }
}
