
import 'package:flutter_tts/flutter_tts.dart';
import '../platform.dart' as plat;
import '../platform/app_log.dart';

/// Speaks the guidance prompts. The real one is the phone's own text-to-speech (flutter_tts: Android's TextToSpeech and iOS's
/// AVSpeechSynthesizer), which runs on the phone with the voices it has installed. Tests give a recorder.
abstract class Speaker {
  /// Says [text], after whatever is being said.
  Future<void> speak(String text);

  /// Stops speaking and drops what was waiting.
  Future<void> stop();
}

/// A [Speaker] that says when it has said every prompt it was given ([onIdle]): the car side then lets the audio session or
/// the navigation focus go at once, so the other apps' sound comes back as the prompt ends.
abstract class IdleSpeaker {
  set onIdle(void Function()? f);
}

/// flutter_tts. Prompts queue behind each other, the voice ducks other audio like a navigation app's, and nothing is sent
/// anywhere.
///
/// A voice that has stopped moving is cleared before the next prompt: another app taking the audio (an assistant, a call)
/// can leave the system's synthesizer paused, or holding a prompt it never finishes. flutter_tts then never says a new
/// prompt: on iOS, speak() on a paused synthesizer only tries to resume the old one, and every new prompt waits behind the
/// one held. So when the voice was paused, or prompts are waiting and nothing has started or finished for [stuckAfter], the
/// voice is stopped (which empties it) and the new prompt is said on a clean voice.
class FlutterTtsSpeaker implements Speaker, IdleSpeaker {
  FlutterTtsSpeaker({FlutterTts? tts, bool? isIOS, DateTime Function()? clock, this.stuckAfter = const Duration(seconds: 30)})
      : _tts = tts ?? FlutterTts(),
        _isIOS = isIOS ?? plat.isIOS,
        _clock = clock ?? DateTime.now;

  final FlutterTts _tts;
  final bool _isIOS;
  final DateTime Function() _clock;

  /// No guidance prompt takes this long to say: prompts waiting with no start or end for this long are held by a voice that
  /// has stopped moving.
  final Duration stuckAfter;
  Future<void>? _ready;

  @override
  void Function()? onIdle;

  /// Prompts handed to the voice and not yet finished, cancelled or failed.
  int _waiting = 0;
  bool _paused = false;
  DateTime? _moved;

  Future<void> _init() => _ready ??= () async {
        Future<void> tryIt(Future<dynamic> Function() f) async {
          try {
            await f();
          } catch (_) {
            // A platform that lacks one of these settings still speaks.
          }
        }

        _tts.setStartHandler(() {
          _paused = false;
          _moved = _clock();
        });
        _tts.setContinueHandler(() {
          _paused = false;
          _moved = _clock();
        });
        void done() {
          final was = _waiting;
          if (_waiting > 0) _waiting--;
          _paused = false;
          _moved = _clock();
          // The last prompt given has been said: the car side lets the audio go now, not when its safety runs out.
          if (was > 0 && _waiting == 0) onIdle?.call();
        }

        _tts.setCompletionHandler(done);
        _tts.setErrorHandler((_) => done());
        // A cancel comes from [stop], which has already emptied the count (the prompts queued behind are dropped with it).
        _tts.setCancelHandler(() {
          _paused = false;
          _moved = _clock();
        });
        _tts.setPauseHandler(() => _paused = true);
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

  bool get _stuck {
    if (_paused) return true;
    final moved = _moved;
    return _waiting > 0 && moved != null && _clock().difference(moved) >= stuckAfter;
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _init();
    if (_stuck) {
      logInfo('Guidance: the voice had stopped moving (${_paused ? 'paused' : '$_waiting prompts waiting, none started or finished for ${stuckAfter.inSeconds}s'}); it is cleared before this prompt');
      await stop();
    }
    _waiting++;
    // A voice that was idle starts its count of time now.
    if (_waiting == 1 || _moved == null) _moved = _clock();
    try {
      await _tts.speak(text);
    } catch (_) {
      if (_waiting > 0) _waiting--;
    }
  }

  @override
  Future<void> stop() async {
    _waiting = 0;
    _paused = false;
    _moved = _clock();
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
