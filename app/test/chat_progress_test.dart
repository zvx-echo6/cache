import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/model_backend.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

class ProgressBackend implements ModelBackend {
  int calls = 0;
  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    if (calls++ == 0) {
      yield const PartialMessage(content: 'I will look');
      yield const PartialMessage(content: 'I will look this up.');
      yield const PartialMessage(
        content: 'I will look this up.',
        toolCalls: [
          ToolCall(id: 'c1', name: 'search', arguments: '{"query":"compass"}'),
        ],
      );
      yield const PartialMessage(
        isFinal: true,
        content: 'I will look this up.',
        toolCalls: [
          ToolCall(id: 'c1', name: 'search', arguments: '{"query":"compass"}'),
        ],
      );
    } else {
      yield const PartialMessage();
      yield const PartialMessage(content: 'The answer');
      yield const PartialMessage(isFinal: true, content: 'The answer [1].');
    }
  }

  @override
  void stop() {}
}

void main() {
  test(
    'displayed work only grows across tool detection and the next model round',
    () async {
      final chat = ChatController(
        actCore: const ActCoreStandIn(),
        tools: [
          BatchSearch([
            [hit('Compass', 'It points north.')],
          ]),
        ],
      )..setBackend(ProgressBackend());
      final visible = <String>[];
      chat.addListener(() {
        if (chat.messages.isEmpty || chat.messages.last.isUser) return;
        final m = chat.messages.last;
        final text = [
          ...m.toolNotes,
          if (m.text.isNotEmpty) m.text,
        ].join('\n\n');
        if (text.isNotEmpty) visible.add(text);
      });
      await chat.send('compass?');
      expect(visible, isNotEmpty);
      for (var i = 1; i < visible.length; i++) {
        expect(
          visible[i].startsWith(visible[i - 1]),
          isTrue,
          reason: 'visible text must not disappear at a tool boundary',
        );
      }
      expect(chat.messages.last.text, 'The answer [1].');
      expect(chat.messages.last.toolNotes, ['I will look this up.']);
      expect(visible.last, 'I will look this up.\n\nThe answer [1].');
    },
  );
}
