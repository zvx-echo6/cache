// Home's Weather and alerts card as a widget: what it shows when a card made earlier is shown later, how its lines are laid
// out, and its mark for alert data that is past its time. Every place is made up.

import 'dart:async';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_screen_kit.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Widget _home(SettingsRig r, LayoutState layout) => HomeScreen(layout: layout, weather: r.weather, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {});

Finder _inCard(Finder what) => find.descendant(of: find.byKey(const ValueKey('home-weather')), matching: what);

/// Wednesday 9:00 PM at "Where I am": the forecast with its "Now", and alerts and fires checked with nothing in force (a
/// check speaks for six hours).
Future<void> _evening(WidgetTester tester, SettingsRig r) async {
  final updated = wednesday(21, 0);
  r.clock = updated;
  await useScreenSources(tester, r, kUsualSources);
  store(r, 'openmeteo-forecast', storedAnswer(updated, updated, [
    nowItem(updated, temperature: 38, feels: 33, wind: '6 mph NW, gusts 11 mph', conditions: 'clear sky'),
    ...sixteenDays(updated),
  ]));
  for (final id in kUsualSources.skip(1)) {
    store(r, id, {...storedAnswer(updated, updated, const []), 'valid_until': updated.add(const Duration(hours: 6)).toIso8601String()});
  }
}

void main() {
  // The app stays in memory overnight. Home's card kept the answer of 9 PM while the next one was awaited, and showed its
  // temperature as the temperature at 7 AM until the core answered.
  testWidgets('a card made last night is not shown as the weather this morning while the next answer is awaited', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    await _evening(tester, r);
    await r.show(tester, _home(r, layout));
    await _settle(tester);
    expect(find.byKey(const ValueKey('home-temperature')), findsOneWidget);
    expect(find.text('38 °F'), findsOneWidget);
    expect(find.text('Clear sky · High 52 °F, low 31 °F'), findsOneWidget);
    expect(_inCard(find.byIcon(Icons.check_circle_outline)), findsOneWidget, reason: 'checked a moment ago, nothing in force: a tick');
    expect(find.byKey(const ValueKey('home-alerts-expired')), findsNothing);

    // Thursday 7:00 AM: Home is drawn again and asks the core, which has not answered yet.
    r.clock = DateTime(2026, 11, 12, 7, 0);
    r.liveCore.busy = Completer<void>();
    await r.show(tester, _home(r, layout));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-temperature')), findsNothing, reason: 'the 9 PM reading is not the temperature at 7 AM');
    expect(find.text('38 °F'), findsNothing);
    expect(find.text('Thu Nov 12 · Light rain · High 49 °F, low 34 °F'), findsOneWidget, reason: 'today\'s forecast under its own label');
    expect(find.text('Where I am · 10 hours old'), findsOneWidget);
    // The check of alerts from last night no longer speaks for now: the Weather screen's mark for that, not a tick.
    expect(find.text('No alerts known, data expired'), findsOneWidget);
    expect(_inCard(find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
    expect(find.byKey(const ValueKey('home-alerts-expired')), findsOneWidget);
    expect(_inCard(find.byIcon(Icons.check_circle_outline)), findsNothing);

    r.liveCore.busy!.complete();
    await _settle(tester, 2);
    layout.dispose();
    await r.dispose(tester);
  });

  // At a phone's width the conditions with the day's high and low were cut off beside the temperature ("… low 31 …").
  testWidgets('the conditions with the high and low may take a second line', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    await _evening(tester, r);
    await r.show(tester, _home(r, layout));
    await _settle(tester);
    final line = tester.widget<Text>(find.text('Clear sky · High 52 °F, low 31 °F'));
    expect(line.maxLines, 2);
    layout.dispose();
    await r.dispose(tester);
  });
}
