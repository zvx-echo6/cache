import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/system_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';

String _prompt(Map<String, dynamic> request) => ((request['messages'] as List).first as Map)['content'] as String;

void main() {
  test('voice mode is per conversation: the voice line is on every request while it is on, and a new chat is text', () async {
    final backend = ScriptedBackend([(_) => say('Hello')]);
    final chat = ChatController(tools: const [])..setBackend(backend);
    expect(chat.voice, isFalse);
    await chat.send('hi');
    expect(_prompt(backend.requests.last), isNot(contains(kVoiceLine)));

    chat.setVoice(true);
    await chat.send('and now by voice');
    expect(_prompt(backend.requests.last), endsWith('\n$kVoiceLine'));
    await chat.send('still by voice');
    expect(_prompt(backend.requests.last), endsWith('\n$kVoiceLine'));

    chat.setVoice(false);
    await chat.send('typing again');
    expect(_prompt(backend.requests.last), isNot(contains(kVoiceLine)));

    chat.setVoice(true);
    chat.newChat();
    expect(chat.voice, isFalse);
    await chat.send('a new chat');
    expect(_prompt(backend.requests.last), isNot(contains(kVoiceLine)));
  });
}
