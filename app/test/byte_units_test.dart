import 'package:cache/platform/byte_units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('megabytes and kilobytes round down as a shift does on the Dart VM, negative counts included', () {
    for (final b in [0, 1, (1 << 20) - 1, 1 << 20, (1 << 20) + 1, 5 * (1 << 30), -1, -(1 << 20), -(1 << 20) - 1, -3 * (1 << 30) + 7]) {
      expect(mbOf(b), b >> 20, reason: '$b');
      expect(kbOf(b), b >> 10, reason: '$b');
    }
  });

  test('counts from 4 GB up, where a browser\'s 32-bit shifts went wrong', () {
    expect(mbOf(5 * (1 << 30)), 5120);
    expect(mbOf(7400000000), 7057);
    expect(mbOf(-7400000000), -7058, reason: 'rounded down, as >> 20 does');
    expect(kbOf(6 * (1 << 30)), 6 * (1 << 20));
  });
}
