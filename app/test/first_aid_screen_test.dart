// The First aid module's screens: the tile in Modules, the home row, and the CPR metronome in each state. Every name is made up.

import 'dart:io';

import 'package:cache/firstaid/cpr_metronome.dart';
import 'package:cache/firstaid/cpr_prefs.dart';
import 'package:cache/firstaid/emergency_number.dart';
import 'package:cache/firstaid/first_aid_screen.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/layout/modules_screen.dart';
import 'package:cache/net/web_link.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/cpr_fakes.dart';
import 'support/settings_rig.dart';

class _Wifi implements ConnectionProbe {
  @override
  Future<ConnectionKind> current() async => ConnectionKind.wifi;
  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

class _Rig {
  final clock = FakeClock();
  late final FakeFeedback feedback = FakeFeedback(clock);
  final awake = AwakeLog();
  late CprPrefs prefs;
  late Directory dir;
  int dials = 0;

  CprMetronome metronome({CprMode mode = CprMode.handsOnly}) => CprMetronome(feedback: feedback, mode: mode, now: () => clock.now, timer: clock.timer, keepAwake: awake.call);

  Future<void> show(WidgetTester tester, {CprMode mode = CprMode.handsOnly, bool canCall = true}) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    dir = Directory.systemTemp.createTempSync('cpr-prefs');
    prefs = CprPrefs(settingsDirOverride: dir);
    await tester.runAsync(prefs.init);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.parchment),
      home: CprScreen(prefs: prefs, metronome: metronome(mode: mode), canCall: canCall, openDialer: () async {
        dials++;
        return true;
      }),
    ));
  }

  /// Time moves on and the screen follows.
  Future<void> advance(WidgetTester tester, Duration d) async {
    clock.advance(d);
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    prefs.dispose();
    dir.deleteSync(recursive: true);
  }
}

void main() {
  final call = find.byKey(const ValueKey('cpr-call'));

  testWidgets('Modules has a First aid tile after Notebooks', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: Directory('${r.dir.path}/layout')..createSync());
    await tester.runAsync(layout.init);
    await r.show(tester, ModulesScreen(layout: layout, app: r.app, onOpen: (_) {}), theme: CacheThemeId.light);
    expect(find.text('First aid'), findsOneWidget);
    expect(ModuleId.values[ModuleId.values.indexOf(ModuleId.notebooks) + 1], ModuleId.firstAid);
    expect(ModuleId.firstAid.label, 'First aid');
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('the First aid home has the CPR metronome row, which opens the metronome', (tester) async {
    final dir = Directory.systemTemp.createTempSync('cpr-home');
    final prefs = CprPrefs(settingsDirOverride: dir);
    await tester.runAsync(prefs.init);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: FirstAidScreen(prefs: prefs, canCall: true)));
    expect(find.text('First aid'), findsOneWidget);
    expect(find.text('CPR metronome'), findsOneWidget);
    expect(find.text('Keeps the beat for chest compressions'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('first-aid-cpr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cpr-start')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    prefs.dispose();
    dir.deleteSync(recursive: true);
  });

  group('the ready screen', () {
    testWidgets('the mode switch (Hands-only chosen, with its check mark), Start, the reminder, Call, the toggles and the source line', (tester) async {
      final r = _Rig();
      await r.show(tester);
      expect(find.text('With breaths (30:2)'), findsOneWidget);
      expect(find.text('Hands-only'), findsOneWidget);
      final switchButton = tester.widget<SegmentedButton<CprMode>>(find.byKey(const ValueKey('cpr-mode')));
      expect(switchButton.selected, {kDefaultCprMode});
      expect(kDefaultCprMode, CprMode.handsOnly);
      expect(switchButton.showSelectedIcon, isTrue, reason: 'the selected segment shows a check mark');
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
      expect(find.text(kCprReminder), findsOneWidget);
      expect(find.text('Push hard and fast in the center of the chest, 5–6 cm (2–2.4 in) deep. Let the chest come all the way back up.'), findsOneWidget);
      expect(call, findsOneWidget);
      expect(find.text('Call emergency services'), findsOneWidget);
      expect(find.text('Sound'), findsOneWidget);
      expect(find.text('Vibration'), findsOneWidget);
      expect(find.text('Source: MedlinePlus, National Library of Medicine'), findsOneWidget);
      expect(find.textContaining('Based on U.S. government'), findsNothing);
      await r.done(tester);
    });

    testWidgets('the mode switch changes the mode', (tester) async {
      final r = _Rig();
      await r.show(tester);
      await tester.tap(find.text('With breaths (30:2)'));
      await tester.pump();
      expect(tester.widget<SegmentedButton<CprMode>>(find.byKey(const ValueKey('cpr-mode'))).selected, {CprMode.withBreaths});
      await r.done(tester);
    });

    testWidgets('the source line opens the MedlinePlus page', (tester) async {
      final r = _Rig();
      final opened = <String>[];
      final oldOpen = WebLinks.open, oldProbe = WebLinks.probe;
      WebLinks.open = (u) async => opened.add(u);
      WebLinks.probe = _Wifi();
      addTearDown(() {
        WebLinks.open = oldOpen;
        WebLinks.probe = oldProbe;
      });
      await r.show(tester);
      await tester.tap(find.byKey(const ValueKey('cpr-source')));
      await tester.pump();
      expect(opened, ['https://medlineplus.gov/cpr.html']);
      expect(kFirstAidSourceUrl, 'https://medlineplus.gov/cpr.html');
      await r.done(tester);
    });

    testWidgets('the toggles are remembered on the device', (tester) async {
      final r = _Rig();
      await r.show(tester);
      await tester.tap(find.byKey(const ValueKey('cpr-sound')));
      await tester.pump();
      expect(r.prefs.sound, isFalse);
      expect(r.prefs.vibration, isTrue);
      final again = CprPrefs(settingsDirOverride: r.dir);
      await tester.runAsync(again.init);
      expect(again.sound, isFalse, reason: 'read back from the device');
      expect(again.vibration, isTrue);
      again.dispose();
      await r.done(tester);
    });
  });

  group('running', () {
    testWidgets('hands-only: "Push" with no count, "Keep pushing until help arrives", the timer, Stop and Call', (tester) async {
      final r = _Rig();
      await r.show(tester);
      await tester.tap(find.byKey(const ValueKey('cpr-start')));
      await tester.pump();
      await r.advance(tester, const Duration(seconds: 61));
      expect(find.text('Push'), findsOneWidget);
      expect(find.byKey(const ValueKey('cpr-count')), findsNothing, reason: 'hands-only has no count');
      expect(find.textContaining('/ 30'), findsNothing);
      expect(find.text('Keep pushing until help arrives'), findsOneWidget);
      expect(find.text('01:01'), findsOneWidget);
      expect(find.text('110 per minute'), findsOneWidget);
      expect(find.byKey(const ValueKey('cpr-stop')), findsOneWidget);
      expect(call, findsOneWidget);
      expect(r.awake.on, isTrue);
      await r.done(tester);
    });

    testWidgets('with breaths: the count N / 30, then the breaths prompt, its countdown, Continue, Stop and Call; it resumes by itself', (tester) async {
      final r = _Rig();
      await r.show(tester, mode: CprMode.withBreaths);
      await tester.tap(find.byKey(const ValueKey('cpr-start')));
      await tester.pump();
      expect(find.text('1 / 30'), findsOneWidget);
      expect(find.text('compressions'), findsOneWidget);
      expect(find.text('Push hard and fast'), findsOneWidget);
      expect(call, findsOneWidget);
      await r.advance(tester, Duration(microseconds: (16 * kCprBeatMicros).round() + 1000));
      expect(find.text('17 / 30'), findsOneWidget);
      await r.advance(tester, Duration(microseconds: (13 * kCprBeatMicros).round()));
      expect(find.text('Give 2 breaths'), findsOneWidget);
      expect(find.text('One second each. Watch the chest rise.'), findsOneWidget);
      expect(find.text('Pushing starts again in 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('cpr-continue')), findsOneWidget);
      expect(find.byKey(const ValueKey('cpr-stop')), findsOneWidget);
      expect(call, findsOneWidget, reason: 'Call is on the breaths screen too');
      await r.advance(tester, const Duration(seconds: 1));
      expect(find.text('Pushing starts again in 4'), findsOneWidget);
      await r.advance(tester, const Duration(seconds: 4));
      expect(find.text('1 / 30'), findsOneWidget, reason: 'pushing starts by itself, counting from 1');
      await r.done(tester);
    });

    testWidgets('Continue resumes at once; Stop goes back to the ready screen and lets the screen go', (tester) async {
      final r = _Rig();
      await r.show(tester, mode: CprMode.withBreaths);
      await tester.tap(find.byKey(const ValueKey('cpr-start')));
      await tester.pump();
      await r.advance(tester, Duration(microseconds: (29 * kCprBeatMicros).round() + 1000));
      await r.advance(tester, const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('cpr-continue')));
      await tester.pump();
      expect(find.text('1 / 30'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cpr-stop')));
      await tester.pump();
      expect(find.byKey(const ValueKey('cpr-start')), findsOneWidget);
      expect(r.awake.calls, [true, false]);
      await r.done(tester);
    });

    testWidgets('leaving the screen while it runs lets the screen go', (tester) async {
      final r = _Rig();
      await r.show(tester);
      await tester.tap(find.byKey(const ValueKey('cpr-start')));
      await tester.pump();
      expect(r.awake.on, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(r.awake.on, isFalse);
      r.prefs.dispose();
      r.dir.deleteSync(recursive: true);
    });
  });

  group('Call emergency services', () {
    testWidgets('is on every screen: ready, running, breaths and hands-only', (tester) async {
      for (final mode in CprMode.values) {
        final r = _Rig();
        await r.show(tester, mode: mode);
        expect(call, findsOneWidget, reason: '${mode.name} ready');
        await tester.tap(find.byKey(const ValueKey('cpr-start')));
        await tester.pump();
        expect(call, findsOneWidget, reason: '${mode.name} running');
        if (mode == CprMode.withBreaths) {
          await r.advance(tester, Duration(microseconds: (29 * kCprBeatMicros).round() + 1000));
          expect(find.text('Give 2 breaths'), findsOneWidget);
          expect(call, findsOneWidget, reason: 'breaths');
        }
        await r.done(tester);
      }
    });

    testWidgets('opens the dialer; the metronome keeps beating underneath', (tester) async {
      final r = _Rig();
      await r.show(tester);
      await tester.tap(find.byKey(const ValueKey('cpr-start')));
      await tester.pump();
      await tester.tap(call);
      await tester.pump();
      expect(r.dials, 1);
      final n = r.feedback.ticks;
      await r.advance(tester, const Duration(seconds: 3));
      expect(r.feedback.ticks, greaterThan(n));
      await r.done(tester);
    });

    testWidgets('where there is no dialer (a computer, a browser) the button is not drawn on any screen', (tester) async {
      final r = _Rig();
      await r.show(tester, canCall: false);
      expect(call, findsNothing);
      await tester.tap(find.byKey(const ValueKey('cpr-start')));
      await tester.pump();
      expect(call, findsNothing);
      await r.done(tester);
    });

    test('the number of the region: 911, 999, 000, 111, else 112', () {
      expect(emergencyNumberFor('US'), '911');
      expect(emergencyNumberFor('ca'), '911');
      expect(emergencyNumberFor('GB'), '999');
      expect(emergencyNumberFor('AU'), '000');
      expect(emergencyNumberFor('NZ'), '111');
      expect(emergencyNumberFor('DE'), '112');
      expect(emergencyNumberFor('FR'), '112');
      expect(emergencyNumberFor('JP'), '112');
      expect(emergencyNumberFor(null), '112');
    });

    test('the dialer gets a tel: address with the number and nothing places the call', () async {
      final opened = <String>[];
      expect(await openEmergencyDialer(number: '911', open: (u) async => opened.add(u)), isTrue);
      expect(opened, ['tel:911']);
      expect(await openEmergencyDialer(number: '112', open: (u) async => throw Exception('no dialer')), isFalse);
    });
  });
}
