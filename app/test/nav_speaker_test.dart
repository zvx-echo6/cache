import 'package:cache/nav/speaker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

class RecordingTts extends FlutterTts {
  final events = <String>[];
  @override
  Future<dynamic> setSharedInstance(bool value) async => events.add('shared:$value');
  @override
  Future<dynamic> autoStopSharedSession(bool value) async => events.add('autoStop:$value');
  @override
  Future<dynamic> setIosAudioCategory(IosTextToSpeechAudioCategory category,
      List<IosTextToSpeechAudioCategoryOptions> options,
      [IosTextToSpeechAudioMode mode = IosTextToSpeechAudioMode.defaultMode]) async {
    expect(category, IosTextToSpeechAudioCategory.playback);
    expect(mode, IosTextToSpeechAudioMode.voicePrompt);
    expect(options, contains(IosTextToSpeechAudioCategoryOptions.duckOthers));
    expect(options, contains(IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers));
    events.add('iosAudio');
  }
  @override
  Future<dynamic> setAudioAttributesForNavigation() async => events.add('androidAudio');
  @override
  Future<dynamic> speak(String text, {bool focus = false}) async => events.add('speak:$text');
  @override
  Future<dynamic> stop() async => events.add('stop');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'), (_) async => 1,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'), null,
    );
  });
  test('iOS voice prompts configure lock-screen playback before speaking, only once', () async {
    final tts = RecordingTts();
    final speaker = FlutterTtsSpeaker(tts: tts, isIOS: true);
    await speaker.speak('Turn left');
    await speaker.speak('Then turn right');
    await speaker.stop();
    expect(tts.events, ['shared:true', 'autoStop:true', 'iosAudio', 'speak:Turn left', 'speak:Then turn right', 'stop']);
  });
  test('Android keeps navigation audio attributes and never configures the iOS session', () async {
    final tts = RecordingTts();
    final speaker = FlutterTtsSpeaker(tts: tts, isIOS: false);
    await speaker.speak('Turn left');
    expect(tts.events, ['androidAudio', 'speak:Turn left']);
  });
}