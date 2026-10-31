// The crisis safety net's screens for the owner, drawn by the app itself (sample conversation, no personal data).
// flutter test test_shots/crisis_renders_test.dart --update-goldens  (pictures in test_shots/crisis/)

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/crisis.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/crisis_card.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'crisis';

class _Help implements CrisisHelp {
  _Help({this.er = ErState.found, this.calls = true, this.signal = true, this.guides = true, this.launches = true});

  final ErState er;
  final bool calls;
  final bool? signal;
  final bool guides;
  final bool launches;

  @override
  Future<bool> canPlaceCalls() async => calls;
  @override
  Future<bool?> hasSignal() async => signal;
  @override
  Future<bool> launch(Uri uri) async => launches;
  @override
  Future<NearestEr> nearestEr() async => er == ErState.found
      ? const NearestEr(
          ErState.found,
          distance: '2.1 mi',
          place: MapPlace(id: 'place:osm:w9', type: 'place', name: 'Eastern Idaho Regional Medical Center', kind: 'Emergency room', category: 'emergency_room', lat: 43.5, lon: -112.0, phone: '+1 208 529 6111'),
        )
      : NearestEr(er);
  @override
  Future<bool> guidesInstalled() async => guides;
  @override
  void openGuides(BuildContext context) {}
  @override
  void getGuides(BuildContext context) {}
  @override
  void getMap(BuildContext context) {}
  @override
  Future<void> turnOnLocation() async {}
  @override
  void directions(BuildContext context, MapPlace place) {}
}

ChatMessage _answer(String text) => ChatMessage.assistant()
  ..text = text
  ..phase = TurnPhase.done;

const _q1 = "I can't sleep and I don't see the point of anything anymore";
const _a1 = "I'm really glad you told me. Are you safe right now? If you can, tell me where you are and whether someone is nearby.";
const _q2 = 'nobody would notice if I was gone';
const _a2 = "I would notice that you reached out, and that matters. You don't have to handle tonight alone. Can you reach one person, or call or text 988?";

void main() {
  setUpAll(loadShotFonts);

  Future<SettingsRig> rig(WidgetTester tester, {bool model = true, String name = 'Gemma 4 E2B · Q4_K_M'}) async {
    final r = await SettingsRig.create(tester);
    if (model) {
      final e = ModelEntry(path: '${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf', size: 3435973837);
      r.app.models = [e];
      r.app.active = e;
    }
    return r;
  }

  Future<void> show(WidgetTester tester, SettingsRig r, CrisisWatch w, CrisisHelp help, {CacheThemeId theme = CacheThemeId.light, double text = 1, Size size = const Size(390, 844)}) async {
    phone(tester, size: size, ratio: 3);
    await tester.pumpWidget(
      shotApp(Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(text)), child: AskScreen(app: r.app, chat: r.chat, crisis: w, crisisHelp: help))), theme: theme),
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// One triggering turn with its answer; the list scrolled so the card's bottom sits just above the composer.
  CrisisWatch oneTurn(SettingsRig r) {
    final u = ChatMessage.user(_q1);
    r.chat.messages
      ..clear()
      ..addAll([u, _answer(_a1)]);
    return CrisisWatch()..mark(u);
  }

  testWidgets('the inline card and its states, light and dark', (tester) async {
    final r = await rig(tester);
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme.name;
      var w = oneTurn(r);
      await show(tester, r, w, _Help(), theme: theme);
      await snap(tester, _out, 'crisis-1-inline-card-$t');
      await show(tester, r, w, _Help(), theme: theme, text: 2);
      await snap(tester, _out, 'crisis-1-inline-card-text200-$t');
      await show(tester, r, w, _Help(), theme: theme);
      await tester.tap(find.byKey(const ValueKey('crisis-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await snap(tester, _out, 'crisis-2-closing-$t');
      await tester.pump(const Duration(milliseconds: 300));
      await snap(tester, _out, 'crisis-2-closed-$t');

      for (final (name, help) in [
        ('3-no-offline-map', _Help(er: ErState.noMap)),
        ('3-no-er-in-map', _Help(er: ErState.noEr)),
        ('3-location-off', _Help(er: ErState.locationOff)),
        ('4-no-library-guide', _Help(guides: false)),
        ('5-cannot-place-calls', _Help(calls: false)),
        ('8-no-signal', _Help(signal: false)),
      ]) {
        w = oneTurn(r);
        await show(tester, r, w, help, theme: theme);
        if (name.startsWith('4')) await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 100));
        await snap(tester, _out, 'crisis-$name-$t');
      }

      w = oneTurn(r);
      await show(tester, r, w, _Help(launches: false), theme: theme);
      await tester.tap(find.byKey(const ValueKey('crisis-call-988')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await snap(tester, _out, 'crisis-8-launch-failed-$t');

      w = oneTurn(r);
      await show(tester, r, w, _Help(), theme: theme);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('crisis-call-988'))));
      await tester.pump(const Duration(milliseconds: 180));
      await snap(tester, _out, 'crisis-8-call-988-pressed-$t');
      await g.cancel();
      await tester.pump(const Duration(milliseconds: 400));

      // A second triggering turn in a row: the one line, which opens on tap.
      final u1 = ChatMessage.user(_q1), u2 = ChatMessage.user(_q2);
      r.chat.messages
        ..clear()
        ..addAll([u1, _answer(_a1), u2, _answer(_a2)]);
      w = CrisisWatch()
        ..mark(u1)
        ..setOpen(u1, false)
        ..mark(u2, repeat: true);
      await show(tester, r, w, _Help(), theme: theme);
      await snap(tester, _out, 'crisis-9-repeat-one-line-$t');
    }
    await r.dispose(tester);
  });

  testWidgets('"Need help now?" in the top bar, and its sheet', (tester) async {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme.name;
      final r = await rig(tester);
      final w = CrisisWatch();
      r.chat.messages
        ..clear()
        ..addAll([ChatMessage.user('How do I keep water safe after a flood?'), _answer('Boil it for one minute, or use 8 drops of plain bleach per gallon and wait 30 minutes.')]);
      await show(tester, r, w, _Help(), theme: theme);
      await snap(tester, _out, 'crisis-6-top-bar-$t');
      await show(tester, r, w, _Help(), theme: theme, text: 2);
      await snap(tester, _out, 'crisis-6-top-bar-text200-$t');
      r.chat.messages.clear();
      await show(tester, r, w, _Help(), theme: theme);
      await snap(tester, _out, 'crisis-6-empty-ask-$t');
      r.app.active = null;
      await show(tester, r, w, _Help(), theme: theme);
      await snap(tester, _out, 'crisis-6-no-model-$t');
      final long = ModelEntry(path: '${r.modelsDir.path}/Qwen3-4B-Instruct-2507-abliterated-Q4_K_M-imatrix.gguf', size: 2500000000);
      r.app.active = long;
      await show(tester, r, w, _Help(), theme: theme);
      await snap(tester, _out, 'crisis-6-long-model-name-$t');

      await show(tester, r, w, _Help(), theme: theme);
      await tester.tap(find.byKey(const ValueKey('need-help')));
      await tester.pumpAndSettle();
      await snap(tester, _out, 'crisis-7-sheet-phone-$t');
      for (final (n, s) in [('820-portrait', const Size(820, 1180)), ('1180-landscape', const Size(1180, 820))]) {
        await show(tester, r, w, _Help(), theme: theme, size: s);
        await tester.tap(find.byKey(const ValueKey('need-help')));
        await tester.pumpAndSettle();
        await snap(tester, _out, 'crisis-7-sheet-tablet-$n-$t');
      }
      await r.dispose(tester);
    }
  });
}
