import 'package:flutter/foundation.dart';

import 'chat_controller.dart' show ChatMessage;

/// Decides whether a user message may come from someone in crisis (spec: cache-crisis-safety-net). It reads the message with the
/// previous user turn (empty when there is none); it never changes what the model sees. The detector by meaning (bge-m3
/// exemplars, a k-nearest vote with its threshold) plugs in here once its exemplars pass the bar; until then [NoCrisisDetector].
abstract class CrisisDetector {
  Future<bool> check(String previousUserTurn, String message);
}

/// No detector yet: nothing fires. "Need help now?" in Ask is always there.
class NoCrisisDetector implements CrisisDetector {
  const NoCrisisDetector();

  @override
  Future<bool> check(String previousUserTurn, String message) async => false;
}

/// How a triggering turn shows its card: in full (the first of a run of triggering turns), or as the one line "Help is available:
/// 988 · nearest ER" (a later turn in a row, or a card the person closed), which opens in full on tap.
class CrisisTurn {
  CrisisTurn({required this.repeat});

  /// A later turn in a run of triggering turns: it starts as the one line.
  final bool repeat;

  /// Shown in full now.
  late bool open = !repeat;
}

/// The cards of the chat on screen: which user messages triggered one, and whether each is open. Kept with the message objects
/// (the chat's own list), so a new chat starts with none. It never touches the turn's text or what the model sees.
class CrisisWatch extends ChangeNotifier {
  CrisisWatch({CrisisDetector? detector}) : detector = detector ?? const NoCrisisDetector();

  CrisisDetector detector;
  final Expando<CrisisTurn> _turns = Expando('crisis');

  /// The card of user message [m], or null when it did not trigger one.
  CrisisTurn? turnOf(ChatMessage m) => _turns[m];

  /// Checks the user message [m] just sent in [messages] (the chat's list, [m] in it) and gives it a card when it triggers: in full
  /// unless the user turn before it triggered too.
  Future<void> checkSent(List<ChatMessage> messages, ChatMessage m) async {
    final users = [for (final x in messages) if (x.isUser) x];
    final i = users.indexWhere((x) => identical(x, m));
    if (i < 0) return;
    final previous = i > 0 ? users[i - 1] : null;
    bool fired;
    try {
      fired = await detector.check(previous?.text ?? '', m.text);
    } catch (_) {
      fired = false;
    }
    if (!fired) return;
    mark(m, repeat: previous != null && _turns[previous] != null);
  }

  /// Gives [m] a card (the detector's result; tests and renders call it directly).
  void mark(ChatMessage m, {bool repeat = false}) {
    _turns[m] = CrisisTurn(repeat: repeat);
    notifyListeners();
  }

  void setOpen(ChatMessage m, bool open) {
    final t = _turns[m];
    if (t == null || t.open == open) return;
    t.open = open;
    notifyListeners();
  }
}
