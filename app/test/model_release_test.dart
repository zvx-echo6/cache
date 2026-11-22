import 'package:cache/platform/memory.dart';
import 'package:cache/platform/model_release.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Chat extends ChangeNotifier {
  bool busy = false;
  void set(bool b) {
    busy = b;
    notifyListeners();
  }
}

void main() {
  late _Chat chat;
  late int released;
  late bool loaded;
  late BackgroundModelRelease r;

  setUp(() {
    chat = _Chat();
    released = 0;
    loaded = true;
    r = BackgroundModelRelease(
      busy: () => chat.busy,
      loaded: () => loaded,
      release: () async => released++,
      changes: chat,
    );
  });
  tearDown(() => r.dispose());

  test('the grace period is one constant of 30 seconds', () {
    expect(kBackgroundReleaseGrace, const Duration(seconds: 30));
  });

  testWidgets('idle in the background: the model is released after the grace period, not before', (tester) async {
    r.toBackground();
    await tester.pump(kBackgroundReleaseGrace - const Duration(seconds: 1));
    expect(released, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(released, 1);
  });

  testWidgets('back in front within the grace period cancels the release', (tester) async {
    r.toBackground();
    await tester.pump(const Duration(seconds: 10));
    r.toFront();
    await tester.pump(const Duration(minutes: 5));
    expect(released, 0);
  });

  testWidgets('an answer being written holds the release; when it ends in the back, a new grace period starts', (tester) async {
    chat.busy = true;
    r.toBackground();
    await tester.pump(const Duration(minutes: 2));
    expect(released, 0, reason: 'held while busy');
    chat.set(false);
    await tester.pump(kBackgroundReleaseGrace - const Duration(seconds: 1));
    expect(released, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(released, 1);
  });

  testWidgets('an answer that ends before the grace period ends restarts it', (tester) async {
    chat.busy = true;
    r.toBackground();
    await tester.pump(const Duration(seconds: 20));
    chat.set(false);
    await tester.pump(const Duration(seconds: 15));
    expect(released, 0, reason: '35 s after going to the back, but only 15 s idle');
    await tester.pump(const Duration(seconds: 15));
    expect(released, 1);
  });

  testWidgets('an answer held, then back in front: nothing is released', (tester) async {
    chat.busy = true;
    r.toBackground();
    await tester.pump(const Duration(minutes: 1));
    r.toFront();
    chat.set(false);
    await tester.pump(const Duration(minutes: 5));
    expect(released, 0);
  });

  testWidgets('no model loaded: nothing to release', (tester) async {
    loaded = false;
    r.toBackground();
    await tester.pump(const Duration(minutes: 5));
    expect(released, 0);
  });

  test('the old trim levels still let the chat model go at once; going to the back is the grace path', () {
    expect(releaseChatModelNowOn(kTrimRunningLow), isTrue);
    expect(releaseChatModelNowOn(15), isTrue);
    expect(releaseChatModelNowOn(19), isTrue);
    expect(releaseChatModelNowOn(5), isFalse);
    expect(releaseChatModelNowOn(kTrimUiHidden), isFalse);
    expect(releaseChatModelNowOn(40), isFalse);
    expect(trimMeansBackground(kTrimUiHidden), isTrue);
    expect(trimMeansBackground(40), isTrue);
    expect(trimMeansBackground(15), isFalse);
  });
}
