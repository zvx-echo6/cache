import 'dart:io';

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

  group('another app took the audio: the voice is cleared before the next prompt, only when it has stopped moving', () {
    late DateTime now;
    late RecordingTts tts;
    late FlutterTtsSpeaker speaker;
    List<String> said() => [for (final e in tts.events) if (e.startsWith('speak:') || e == 'stop') e];
    setUp(() {
      now = DateTime(2026, 11, 14, 12);
      tts = RecordingTts();
      speaker = FlutterTtsSpeaker(tts: tts, isIOS: true, clock: () => now);
    });

    test('a voice left paused (iOS pauses it for another app) is stopped, and the new prompt said', () async {
      await speaker.speak('Turn left');
      tts.startHandler!();
      tts.pauseHandler!();
      now = now.add(const Duration(seconds: 2));
      await speaker.speak('Then turn right');
      expect(said(), ['speak:Turn left', 'stop', 'speak:Then turn right']);
    });

    test('prompts waiting with nothing started or finished for 30 s are cleared; the voice speaks again', () async {
      await speaker.speak('Turn left');
      now = now.add(const Duration(seconds: 31));
      await speaker.speak('Then turn right');
      expect(said(), ['speak:Turn left', 'stop', 'speak:Then turn right']);
      tts.startHandler!();
      tts.completionHandler!();
      now = now.add(const Duration(minutes: 5));
      await speaker.speak('Arrived');
      expect(said(), ['speak:Turn left', 'stop', 'speak:Then turn right', 'speak:Arrived']);
    });

    test('the voice says when it has said the last prompt it was given, not before', () async {
      var idle = 0;
      speaker.onIdle = () => idle++;
      await speaker.speak('Turn left');
      await speaker.speak('Then turn right');
      tts.startHandler!();
      tts.completionHandler!();
      expect(idle, 0, reason: 'one prompt is still to be said');
      tts.startHandler!();
      tts.completionHandler!();
      expect(idle, 1);
      await speaker.speak('Arrived');
      tts.errorHandler!('failed');
      expect(idle, 2, reason: 'a prompt that failed is done with too');
    });

    test('a voice that is moving is never cut: a prompt queued while one plays, or long after the last one finished', () async {
      await speaker.speak('Turn left');
      tts.startHandler!();
      now = now.add(const Duration(seconds: 10));
      await speaker.speak('Then turn right');
      tts.completionHandler!();
      tts.startHandler!();
      tts.completionHandler!();
      now = now.add(const Duration(minutes: 10));
      await speaker.speak('Arrived');
      expect(said(), ['speak:Turn left', 'speak:Then turn right', 'speak:Arrived']);
    });
  });

  test('Android: the manifest lets the app see the text-to-speech engine (Android 11 and later hide it otherwise)', () {
    final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final queries = RegExp(r'<queries>([\s\S]*?)</queries>').firstMatch(m)?.group(1) ?? '';
    expect(queries, contains('android.intent.action.TTS_SERVICE'));
  });
}
