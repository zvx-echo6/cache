// The chat model goes a while after Ask is left (AskIdleRelease, kAskIdleRelease), and first when memory is short
// (releaseOnMemoryShort): it is the most memory Cache holds by far and only Ask uses it (owner, 2026-11-13).

import 'package:cache/platform/model_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late bool busy;
  late bool loaded;
  late int released;
  late AskIdleRelease r;

  setUp(() {
    busy = false;
    loaded = true;
    released = 0;
    r = AskIdleRelease(busy: () => busy, loaded: () => loaded, release: () async => released++);
  });
  tearDown(() => r.dispose());

  test('the idle time after leaving Ask is one constant, 5 minutes (the owner\'s choice)', () {
    expect(kAskIdleRelease, const Duration(minutes: 5));
  });

  testWidgets('Ask left and nothing in use: the model goes after the idle time, not before', (tester) async {
    r.askShown(true);
    r.askShown(false);
    await tester.pump(kAskIdleRelease - const Duration(seconds: 1));
    expect(released, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(released, 1);
    await tester.pump(const Duration(minutes: 30));
    expect(released, 1, reason: 'once');
  });

  testWidgets('back on Ask within the idle time: nothing goes', (tester) async {
    r.askShown(true);
    r.askShown(false);
    await tester.pump(kAskIdleRelease - const Duration(minutes: 1));
    r.askShown(true);
    await tester.pump(const Duration(minutes: 30));
    expect(released, 0);
  });

  testWidgets('on Ask the whole time: nothing goes', (tester) async {
    r.askShown(true);
    await tester.pump(const Duration(minutes: 30));
    expect(released, 0);
  });

  testWidgets('in use when the time comes (an answer, a load or the read ahead): it waits another idle period', (tester) async {
    r.askShown(true);
    r.askShown(false);
    busy = true;
    await tester.pump(kAskIdleRelease + const Duration(seconds: 1));
    expect(released, 0);
    busy = false;
    await tester.pump(kAskIdleRelease);
    expect(released, 1);
  });

  testWidgets('no model loaded: nothing to let go', (tester) async {
    loaded = false;
    r.askShown(true);
    r.askShown(false);
    await tester.pump(const Duration(minutes: 30));
    expect(released, 0);
  });

  testWidgets('the same state twice changes nothing (a second "left" does not restart the time)', (tester) async {
    r.askShown(true);
    r.askShown(false);
    await tester.pump(const Duration(minutes: 1));
    r.askShown(false);
    await tester.pump(kAskIdleRelease - const Duration(minutes: 1) + const Duration(seconds: 1));
    expect(released, 1);
  });

  test('memory short: the chat model goes first; the search model only with no chat model, or one in use', () {
    expect(releaseOnMemoryShort(chatLoaded: true, chatBusy: false), MemoryShortRelease.chatModel);
    expect(releaseOnMemoryShort(chatLoaded: true, chatBusy: true), MemoryShortRelease.searchModel);
    expect(releaseOnMemoryShort(chatLoaded: false, chatBusy: false), MemoryShortRelease.searchModel);
    expect(releaseOnMemoryShort(chatLoaded: false, chatBusy: true), MemoryShortRelease.searchModel);
  });
}
