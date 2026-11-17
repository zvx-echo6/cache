import 'dart:math' as math;

import 'package:cache/maps/ui/map_mouse_ring.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the browser map opens its ring menu from the mouse', () {
    late int started, stopped;
    late void Function(double, double, double, double) fire;
    late List<(Offset, math.Point<double>)> rings;

    Widget app({bool web = true}) {
      started = stopped = 0;
      rings = [];
      return Directionality(
        textDirection: TextDirection.ltr,
        child: MapMouseRing(
          web: web,
          onRing: (page, inMap) => rings.add((page, inMap)),
          listen: (cb) {
            started++;
            fire = cb;
            return () => stopped++;
          },
          child: const Text('the map'),
        ),
      );
    }

    testWidgets('a right-click or a hold reaches the ring, with the spot in the page and in the map', (tester) async {
      await tester.pumpWidget(app());
      expect(started, 1);
      fire(300, 200, 280, 150);
      expect(rings, [(const Offset(300, 200), const math.Point<double>(280, 150))]);
    });

    test('the ring is centred on the spot in the map box, not the page (a side rail shifts the page point)', () {
      expect(mouseRingCentre(const Offset(1282, 380), const math.Point<double>(1050, 380)), const Offset(1050, 380));
    });

    testWidgets('it stops listening when the map goes away', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpWidget(const SizedBox());
      expect(stopped, 1);
    });

    testWidgets('not a browser (a phone): nothing is listened to', (tester) async {
      await tester.pumpWidget(app(web: false));
      expect(started, 0);
    });
  });
}
