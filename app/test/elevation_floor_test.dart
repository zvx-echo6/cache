import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_shots/shot_kit.dart';
import 'nav_fakes.dart';

const _ft = 0.3048;
const _mi = 1609.344;

/// A profile that climbs [riseFt] (feet) evenly over [miles].
ElevationProfile _ramp(double riseFt, double miles) {
  final total = miles * _mi;
  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= total; x += kProfileStepM) {
    d.add(x);
    e.add(1500 * _ft + riseFt * _ft * x / total);
  }
  return ElevationProfile.fromSamples(d, e, totalM: total);
}

ElevationChartColors get _colors => const ElevationChartColors(
      route: Color(0xFF0000FF),
      position: Color(0xFFFF0000),
      text: Color(0xFF000000),
      secondary: Color(0xFF666666),
      surface: Color(0xFFFFFFFF),
      warning: Color(0xFFFFAA00),
    );

/// The height the drawn line takes (its path's bounds), as a fraction of the chart's whole height.
double _lineShare(ElevationProfile p, {required bool full}) {
  final size = full ? const Size(360, 142) : const Size(340, 92);
  final canvas = TestRecordingCanvas();
  ElevationChartPainter(profile: p, units: UnitSystem.imperial, colors: _colors, full: full).paint(canvas, size);
  Rect? line;
  for (final i in canvas.invocations) {
    if (i.invocation.memberName != #drawPath) continue;
    final paint = i.invocation.positionalArguments[1] as Paint;
    if (paint.style != PaintingStyle.stroke || paint.strokeWidth != 2.5) continue;
    final b = (i.invocation.positionalArguments[0] as Path).getBounds();
    line = line == null ? b : line.expandToInclude(b);
  }
  return line!.height / size.height;
}

void main() {
  setUpAll(loadShotFonts);

  group('the full height never stands for less than 330 ft', () {
    for (final full in [true, false]) {
      test('a 10 ft rise is drawn small (${full ? 'guidance panel' : 'preview'})', () {
        final share = _lineShare(_ramp(10, 0.3), full: full);
        expect(share, lessThan(0.04), reason: 'it was drawn at $share of the height');
      });
    }

    test('a 2,000 ft rise still fills most of the chart', () {
      expect(_lineShare(_ramp(2000, 12), full: true), greaterThan(0.45));
    });

    test('the floor is 100 m, the car card\'s rule', () => expect(kChartMinSpanM, 100.0));
  });

  group('the numbers are not changed by the floor', () {
    test('a 10 ft route still reports its own highest and lowest points', () {
      final p = _ramp(10, 0.3);
      expect(p.highest!.elevM / _ft, closeTo(1510, 2));
      expect(p.lowest!.elevM / _ft, closeTo(1500, 2));
      expect(elevationText(const Fmt(UnitSystem.imperial), p.highest!.elevM), startsWith('1,5'));
    });
  });

  group('distance labels', () {
    for (final full in [true, false]) {
      for (final mi in [0.3, 0.1, 0.6, 1.5, 12.0]) {
        test('${full ? 'full' : 'small'} chart, $mi mi: no label repeats', () {
          final labels = [for (final (_, t) in distanceAxisLabels(mi, full: full)) t];
          expect(labels.toSet().length, labels.length, reason: '$labels');
        });
      }
    }

    test('0.3 mi reads 0.05 steps, with two decimals', () {
      final labels = [for (final (_, t) in distanceAxisLabels(0.3, full: true)) t];
      expect(labels, ['0.00', '0.05', '0.10', '0.15', '0.20', '0.25', '0.30']);
    });
  });

  group('the Highest and Lowest row', () {
    for (final (w, scale) in [(393.0, 1.0), (393.0, 1.15), (360.0, 1.0), (360.0, 1.3), (360.0, 1.6)]) {
      testWidgets('both labels show in full at $w pt, text x$scale', (tester) async {
        tester.view.physicalSize = Size(w, 800) * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final total = 8 * _mi;
        final d = <double>[], e = <double>[];
        for (var x = 0.0; x <= total; x += kProfileStepM) {
          d.add(x);
          e.add(3754 * _ft - 2000 * _ft * x / total);
        }
        final el = RouteElevation(loader: (r) async => ElevationProfile.fromSamples(d, e, totalM: total))..request(MapRoute.fromJson(fakeRouteJson()));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pumpWidget(MaterialApp(
          theme: shotTheme(),
          builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: Scaffold(
            body: Padding(
              // the route panel's own side padding (route_panel.dart)
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: RouteElevationSummary(elevation: el, fmt: const Fmt(UnitSystem.imperial), palette: mapPaletteFor(CacheThemeId.light)),
            ),
          ),
        ));
        await tester.pump();
        expect(find.textContaining('Highest 3,7'), findsOneWidget, reason: 'the highest point is about 3,754 ft');
        for (final label in ['Highest', 'Lowest']) {
          final ro = tester.renderObject<RenderParagraph>(find.textContaining(label));
          expect(ro.didExceedMaxLines, isFalse, reason: '$label was cut');
          expect(tester.takeException(), isNull);
        }
        el.dispose();
      });
    }
  });
}
