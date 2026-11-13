import 'dart:ui' as ui show BoxHeightStyle;

import 'package:cache/screens/home_screen.dart' show homeConditionsLine;
import 'package:cache/weather/weather_state.dart';
import 'package:cache/weather/words.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A no-break space: the high and the low of the Home weather line are each one piece ("High 61 °F", "low 42 °F").
const _nb = '\u00A0';

/// [line] as a reader sees it: a no-break space looks like any space.
String _read(String line) => line.replaceAll(_nb, ' ');

// 1.0.27 feedback: the Home weather card read "rain · High 61 °F, low 42 °F". A condition that starts a line starts with a capital.
void main() {
  test('the Home weather line starts with a capital', () {
    expect(_read(homeConditionsLine(const HomeWeather(conditions: 'rain', high: '61 °F', low: '42 °F'))), 'Rain · High 61 °F, low 42 °F');
    expect(homeConditionsLine(const HomeWeather(conditions: 'partly cloudy')), 'Partly cloudy');
    expect(_read(homeConditionsLine(const HomeWeather(high: '58 °F', low: '42 °F'))), 'High 58 °F, low 42 °F');
  });

  // 1.1 audit: with no reading (the forecast's "Now" has ended) the line is the day's forecast under the day's own label, as the
  // Weather screen lists it; a label alone says nothing.
  test('a forecast period on the Home weather line comes under its own label', () {
    expect(_read(homeConditionsLine(const HomeWeather(period: 'Wed Nov 11', conditions: 'overcast', high: '52 °F', low: '30 °F'))), 'Wed Nov 11 · Overcast · High 52 °F, low 30 °F');
    expect(homeConditionsLine(const HomeWeather(period: 'Tonight', conditions: 'light rain')), 'Tonight · Light rain');
    expect(homeConditionsLine(const HomeWeather(period: 'Wed Nov 11')), '');
  });

  // 1.1 feedback: on a phone the line took a second line and left "°F" alone on it ("... High 52 °F, low 31" then "°F").
  test('the high and the low of the Home weather line are each one piece: the same words, with no-break spaces inside', () {
    expect(unbroken('High 52 °F'), 'High${_nb}52$_nb°F');
    expect(unbroken('Rain'), 'Rain');
    final line = homeConditionsLine(const HomeWeather(conditions: 'mostly cloudy', high: '52 °F', low: '31 °F'));
    expect(line, 'Mostly cloudy · High${_nb}52$_nb°F, low${_nb}31$_nb°F');
    expect(_read(line), 'Mostly cloudy · High 52 °F, low 31 °F');
    // The line can still break at each "·" and between the high and the low.
    expect(' '.allMatches(line), hasLength(4));
    expect(homeConditionsLine(const HomeWeather(period: 'Thu Nov 12', conditions: 'light rain', high: '9 °C', low: '-2 °C')), 'Thu Nov 12 · Light rain · High${_nb}9$_nb°C, low$_nb-2$_nb°C');
  });

  test('on two lines the Home weather line breaks between its parts, never inside the high or the low', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final line = homeConditionsLine(const HomeWeather(conditions: 'mostly cloudy', high: '52 °F', low: '31 °F'));
    const parts = ['High${_nb}52$_nb°F', 'low${_nb}31$_nb°F'];

    // The parts of [text] that are laid out on more than one line when the line is [width] wide, in the card's 13 point type.
    List<String> split(String text, List<String> parts, double width) {
      final painter = TextPainter(text: TextSpan(text: text, style: const TextStyle(fontSize: 13)), textDirection: TextDirection.ltr)..layout(maxWidth: width);
      final out = <String>[];
      for (final part in parts) {
        final at = text.indexOf(part);
        final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: at, extentOffset: at + part.length), boxHeightStyle: ui.BoxHeightStyle.max);
        if ({for (final b in boxes) b.top.round()}.length > 1) out.add(part);
      }
      painter.dispose();
      return out;
    }

    // Every width from one that holds the longest part with room to spare ("High 52 °F," is 11 letters; a letter of the test's
    // type is as wide as it is tall) to one that holds the whole line.
    var broken = 0;
    for (var width = 12 * 13.0; width <= (line.length + 1) * 13.0; width += 1) {
      expect(split(line, parts, width), isEmpty, reason: 'at $width wide');
      // The same words with ordinary spaces are broken inside a part at some of these widths: the fault.
      if (split(_read(line), [for (final p in parts) _read(p)], width).isNotEmpty) broken++;
    }
    expect(broken, greaterThan(0), reason: 'the line with ordinary spaces was never broken inside a part, so this test shows nothing');
  });

  test('lineStart only changes the first letter', () {
    expect(lineStart('rain'), 'Rain');
    expect(lineStart('Clear sky'), 'Clear sky');
    expect(lineStart('45 °F · rain'), '45 °F · rain');
    expect(lineStart(''), '');
    expect(lineStart('éclaircies'), 'Éclaircies');
  });
}
