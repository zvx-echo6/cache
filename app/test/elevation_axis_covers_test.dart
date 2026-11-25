// The elevation chart's height axis covers the stated Highest and Lowest: the labelled lines run from one at or below the lowest point
// to one at or above the highest, all inside the drawn window, and the stated values are the very samples the line is drawn from.
// Every height here is made up.

import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:flutter_test/flutter_test.dart';

const _ft = 0.3048;
const _mi = 1609.344;

/// A profile that rises from [loFt] to [hiFt] and falls back over [miles] (a hump), so its stated points are interior samples.
ElevationProfile _hump(double loFt, double hiFt, double miles) {
  final total = miles * _mi;
  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= total; x += kProfileStepM) {
    d.add(x);
    final t = x / total;
    final bump = t < 0.5 ? t * 2 : (1 - t) * 2;
    e.add((loFt + (hiFt - loFt) * bump) * _ft);
  }
  return ElevationProfile.fromSamples(d, e, totalM: total);
}

void main() {
  const floor = kChartMinSpanM * 3.28084;

  group('the axis covers the stated highest and lowest', () {
    // The case of the owner's picture: highest 5,700 ft under a top line of 5,500.
    test('4,610 to 5,700 ft: the top line is at or above 5,700 and the bottom at or below 4,610 (full chart and preview)', () {
      for (final full in [true, false]) {
        final ph = full ? 98.0 : 64.0;
        final (yMin, yMax) = chartWindow(4610, 5700, floor: floor, plotHeight: ph);
        final lines = chartGridLines(4610, 5700, floor: floor, plotHeight: ph, full: full);
        expect(lines.last, greaterThanOrEqualTo(5700), reason: 'full=$full $lines');
        expect(lines.first, lessThanOrEqualTo(4610), reason: 'full=$full $lines');
        expect(lines.every((g) => g >= yMin - 1e-6 && g <= yMax + 1e-6), isTrue, reason: '$lines in $yMin..$yMax');
      }
    });

    test('a sweep of profiles: the lines bracket the lowest and the highest, and the window holds the lines and the profile', () {
      for (final full in [true, false]) {
        for (var lo = 0.0; lo <= 9000; lo += 137) {
          for (final span in [0.0, 12.0, 90.0, 200.0, 330.0, 331.0, 500.0, 1090.0, 2000.0, 5400.0]) {
            final hi = lo + span;
            final ph = full ? 98.0 : 64.0;
            // As the chart's painter asks for them: the window and the lines for the plot's own height.
            final (yMin, yMax) = chartWindow(lo, hi, floor: floor, plotHeight: ph);
            final lines = chartGridLines(lo, hi, floor: floor, plotHeight: ph, full: full);
            final why = 'lo=$lo hi=$hi full=$full lines=$lines window=$yMin..$yMax';
            expect(lines, isNotEmpty, reason: why);
            expect(lo, inInclusiveRange(yMin, yMax), reason: why);
            expect(hi, inInclusiveRange(yMin, yMax), reason: why);
            expect(lines.first, lessThanOrEqualTo(lo + 1e-6), reason: why);
            expect(lines.last, greaterThanOrEqualTo(hi - 1e-6), reason: why);
            expect(lines.every((g) => g >= yMin - 1e-6 && g <= yMax + 1e-6), isTrue, reason: why);
          }
        }
      }
    });

    test('the stated Highest and Lowest are the samples the line is drawn from', () {
      final p = _hump(4610, 5700, 11.2);
      final drawn = p.elevM.where((e) => !e.isNaN);
      expect(p.highest!.elevM, drawn.reduce((a, b) => a > b ? a : b));
      expect(p.lowest!.elevM, drawn.reduce((a, b) => a < b ? a : b));
      // What the panel prints is that height, and the axis (built from the same samples) covers it.
      final hiFt = p.highest!.elevM / _ft, loFt = p.lowest!.elevM / _ft;
      expect(elevationText(const Fmt(UnitSystem.imperial), p.highest!.elevM), '${_group(hiFt.round())} ft');
      final lines = chartGridLines(loFt, hiFt, floor: floor, plotHeight: 98, full: true);
      expect(lines.last, greaterThanOrEqualTo(hiFt));
      expect(lines.first, lessThanOrEqualTo(loFt));
    });
  });
}

String _group(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return n < 0 ? '-$b' : b.toString();
}
