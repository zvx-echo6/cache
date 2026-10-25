import 'package:flutter/foundation.dart';

import 'model_backend.dart';
import 'search_tool.dart';
import 'tool.dart';
import 'tool_loop.dart';

/// One message in the Ask screen.
class ChatMessage {
  ChatMessage.user(this.text)
      : isUser = true,
        phase = TurnPhase.done;
  ChatMessage.assistant()
      : isUser = false,
        text = '',
        phase = TurnPhase.thinking;

  final bool isUser;
  String text;
  TurnPhase phase;
  List<NumberedResult> sources = const [];
  String? error;
  bool get isDone => phase == TurnPhase.done;
  bool get streaming => !isDone;
}

/// The Ask conversation. Lives above the tabs so it survives switching between them.
class ChatController extends ChangeNotifier {
  ChatController({List<Tool>? tools}) : _tools = tools ?? [SearchTool()];

  final List<Tool> _tools;
  final List<ChatMessage> messages = [];
  ToolLoop? _loop;
  ModelBackend? _backend;
  bool busy = false;

  void setBackend(ModelBackend? backend) {
    if (identical(backend, _backend)) return;
    newChat();
    _backend = backend;
    notifyListeners();
  }

  bool get canSend => _backend != null && !busy;

  void newChat() {
    _loop?.stop();
    _loop = null;
    messages.clear();
    busy = false;
    notifyListeners();
  }

  void stop() => _loop?.stop();

  Future<void> send(String text) async {
    text = text.trim();
    final backend = _backend;
    if (text.isEmpty || backend == null || busy) return;
    final loop = _loop ??= ToolLoop(backend: backend, tools: _tools);
    final reply = ChatMessage.assistant();
    messages
      ..add(ChatMessage.user(text))
      ..add(reply);
    busy = true;
    notifyListeners();
    try {
      await for (final u in loop.ask(text)) {
        if (!identical(_loop, loop)) return; // chat was reset meanwhile
        reply
          ..phase = u.phase
          ..error = u.error;
        if (u.phase == TurnPhase.answering || u.phase == TurnPhase.done) reply.text = u.text;
        if (u.phase == TurnPhase.done) reply.sources = u.cited;
        notifyListeners();
      }
    } finally {
      reply.phase = TurnPhase.done;
      if (identical(_loop, loop)) busy = false;
      notifyListeners();
    }
  }
}
