// The tick and the buzz of the CPR metronome on a phone. A short dry tick is made here as a small WAV (no sound file is shipped) and
// played by the platform: Android plays it on the alarm stream with audio focus (the ringer mode does not mute it), iOS in a playback
// audio session (the silent switch does not mute it). Elsewhere (a computer, a browser) there is no sound or buzz: the screen shows the beat.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cpr_metronome.dart';

/// The channel the platform side listens on (MainActivity.kt, AppDelegate.swift).
const MethodChannel kCprChannel = MethodChannel('co.cache/cpr');

/// How long a compression's vibration lasts, in milliseconds.
const int kCprBuzzMs = 40;

/// The gap between the two tones of the breaths cue.
const Duration kCprCueGap = Duration(milliseconds: 170);

/// A dry tick as a mono 16-bit WAV: a short burst of 1.8 kHz that dies away within about 30 ms.
Uint8List cprTickWav({int sampleRate = 44100, double seconds = 0.035}) {
  final n = (sampleRate * seconds).round();
  final data = ByteData(44 + n * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final attack = math.min(1.0, i / (sampleRate * 0.001));
    final v = math.sin(2 * math.pi * 1800 * t) * math.exp(-t / 0.009) * attack * 0.9;
    data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Whether this platform has the tick and the buzz (a phone).
bool get cprHasFeedback => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// The phone's tick and buzz; on any other platform it does nothing.
class ChannelCprFeedback implements CprFeedback {
  ChannelCprFeedback({this.channel = kCprChannel, bool? available}) : _available = available ?? cprHasFeedback;

  final MethodChannel channel;
  final bool _available;

  Future<void> _call(String method, [Object? args]) async {
    if (!_available) return;
    try {
      await channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Flutter-only tests and hosts without the native side.
    } on PlatformException {
      // No sound is better than a beat that stops.
    }
  }

  @override
  Future<void> begin() => _call('begin', {'wav': cprTickWav()});

  @override
  Future<void> end() => _call('end');

  @override
  Future<void> tick() => _call('tick');

  @override
  Future<void> buzz() => _call('buzz', {'ms': kCprBuzzMs});

  @override
  Future<void> breathsCue({required bool sound, required bool vibration}) async {
    if (sound) await tick();
    if (vibration) await buzz();
    await Future<void>.delayed(kCprCueGap);
    if (sound) await tick();
    if (vibration) await buzz();
  }
}
