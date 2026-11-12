import 'package:cache/screens/home_screen.dart' show homeConditionsLine;
import 'package:cache/weather/weather_state.dart';
import 'package:cache/weather/words.dart';
import 'package:flutter_test/flutter_test.dart';

// 1.0.27 feedback: the Home weather card read "rain · High 61 °F, low 42 °F". A condition that starts a line starts with a capital.
void main() {
  test('the Home weather line starts with a capital', () {
    expect(homeConditionsLine(const HomeWeather(conditions: 'rain', high: '61 °F', low: '42 °F')), 'Rain · High 61 °F, low 42 °F');
    expect(homeConditionsLine(const HomeWeather(conditions: 'partly cloudy')), 'Partly cloudy');
    expect(homeConditionsLine(const HomeWeather(high: '58 °F', low: '42 °F')), 'High 58 °F, low 42 °F');
  });

  // 1.1 audit: with no reading (the forecast's "Now" has ended) the line is the day's forecast under the day's own label, as the
  // Weather screen lists it; a label alone says nothing.
  test('a forecast period on the Home weather line comes under its own label', () {
    expect(homeConditionsLine(const HomeWeather(period: 'Wed Nov 11', conditions: 'overcast', high: '52 °F', low: '30 °F')), 'Wed Nov 11 · Overcast · High 52 °F, low 30 °F');
    expect(homeConditionsLine(const HomeWeather(period: 'Tonight', conditions: 'light rain')), 'Tonight · Light rain');
    expect(homeConditionsLine(const HomeWeather(period: 'Wed Nov 11')), '');
  });

  test('lineStart only changes the first letter', () {
    expect(lineStart('rain'), 'Rain');
    expect(lineStart('Clear sky'), 'Clear sky');
    expect(lineStart('45 °F · rain'), '45 °F · rain');
    expect(lineStart(''), '');
    expect(lineStart('éclaircies'), 'Éclaircies');
  });
}
