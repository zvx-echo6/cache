import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/crisis.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fires on the messages it is given, and records what it was asked.
class _Fires implements CrisisDetector {
  _Fires(this.on);

  final Set<String> on;
  final List<(String, String)> asked = [];

  @override
  Future<bool> check(String previousUserTurn, String message) async {
    asked.add((previousUserTurn, message));
    return on.contains(message);
  }
}

void main() {
  test('no detector yet: nothing fires', () async {
    final w = CrisisWatch();
    final m = ChatMessage.user('a');
    await w.checkSent([m], m);
    expect(w.turnOf(m), isNull);
  });

  test('the detector reads the message with the user turn before it; the first triggering turn is in full, the next in a row is one line', () async {
    final d = _Fires({'b', 'c', 'e'});
    final w = CrisisWatch(detector: d);
    final msgs = <ChatMessage>[];
    ChatMessage send(String t) {
      final m = ChatMessage.user(t);
      msgs
        ..add(m)
        ..add(ChatMessage.assistant());
      return m;
    }

    final a = send('a');
    await w.checkSent(msgs, a);
    final b = send('b');
    await w.checkSent(msgs, b);
    final c = send('c');
    await w.checkSent(msgs, c);
    final dd = send('d');
    await w.checkSent(msgs, dd);
    final e = send('e');
    await w.checkSent(msgs, e);
    expect(d.asked, [('', 'a'), ('a', 'b'), ('b', 'c'), ('c', 'd'), ('d', 'e')]);
    expect(w.turnOf(a), isNull);
    expect(w.turnOf(b)!.open, isTrue, reason: 'the first triggering turn shows the card in full');
    expect(w.turnOf(c)!.open, isFalse, reason: 'the next triggering turn in a row starts as the one line');
    expect(w.turnOf(dd), isNull);
    expect(w.turnOf(e)!.open, isTrue, reason: 'not in a row: in full again');
    w.setOpen(c, true);
    expect(w.turnOf(c)!.open, isTrue, reason: 'the one line opens on tap');
    w.setOpen(b, false);
    expect(w.turnOf(b)!.open, isFalse, reason: 'Close');
  });

  test('a detector that fails fires nothing', () async {
    final w = CrisisWatch(detector: _Throws());
    final m = ChatMessage.user('x');
    await w.checkSent([m], m);
    expect(w.turnOf(m), isNull);
  });
}

class _Throws implements CrisisDetector {
  @override
  Future<bool> check(String previousUserTurn, String message) async => throw StateError('no model');
}
