import 'package:cache/location/coords.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decimal has five places and a comma', () {
    expect(formatDecimal(42.536123, -113.792456), '42.53612, -113.79246');
    expect(formatDecimal(-0.5, 0), '-0.50000, 0.00000');
  });

  test('a dropped pin is named "Pin" and its position to two places', () {
    expect(pinName(40.760801, -111.891), 'Pin 40.76, -111.89');
    expect(pinName(-0.5, 0), 'Pin -0.50, 0.00');
  });

  test('degrees minutes seconds with hemispheres', () {
    expect(formatDms(42.536123, -113.792456), '42°32\'10.0"N 113°47\'32.8"W');
    expect(formatDms(-33.8688, 151.2093), '33°52\'7.7"S 151°12\'33.5"E');
  });

  test('rounding carries into minutes and degrees', () {
    expect(formatDms(10.99999999, 20.0), '11°0\'0.0"N 20°0\'0.0"E');
    expect(formatDms(0, 0), '0°0\'0.0"N 0°0\'0.0"E');
  });
}
