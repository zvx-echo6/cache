import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';

/// Speaks the guidance prompts. The real one is the phone's own text-to-speech (flutter_tts: Android's TextToSpeech and iOS's
/// AVSpeechSynthesizer), which runs on the phone with the voices it has installed. Tests give a recorder.
abstract class Speaker {
  /// Says [text], after whatever is being said.
  Future<void> speak(String text);

  /// Stops speaking and drops what was waiting.
  Future<void> stop();
}

/// flutter_tts. Prompts queue behind each other, the voice ducks other audio like a navigation app's, and nothing is sent
/// anywhere.
class FlutterTtsSpeaker implements Speaker {
  FlutterTtsSpeaker({FlutterTts? tts, bool? isIOS}) : _tts = tts ?? FlutterTts(), _isIOS = isIOS ?? Platform.isIOS;

  final FlutterTts _tts;
  final bool _isIOS;
  Future<void>? _ready;

  Future<void> _init() => _ready ??= () async {
        Future<void> tryIt(Future<dynamic> Function() f) async {
          try {
            await f();
          } catch (_) {
            // A platform that lacks one of these settings still speaks.
          }
        }

        await tryIt(() => _tts.setLanguage('en-US'));
        await tryIt(() => _tts.setSpeechRate(0.5));
        await tryIt(() => _tts.setQueueMode(1));
        if (_isIOS) {
          await tryIt(() => _tts.setSharedInstance(true));
          await tryIt(() => _tts.autoStopSharedSession(true));
          await tryIt(() => _tts.setIosAudioCategory(
            IosTextToSpeechAudioCategory.playback,
            [IosTextToSpeechAudioCategoryOptions.duckOthers, IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers],
            IosTextToSpeechAudioMode.voicePrompt,
          ));
        } else {
          await tryIt(() => _tts.setAudioAttributesForNavigation());
        }
        await tryIt(() => _tts.awaitSpeakCompletion(false));
      }();

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _init();
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
