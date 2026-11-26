// The tick and the buzz of the CPR metronome as they go to the platform: one call each, a WAV for the tick, nothing where there is
// no phone, and a missing native side never stops the beat.

import 'dart:typed_data';

import 'package:cache/firstaid/cpr_feedback.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(kCprChannel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(kCprChannel, null));

  test('the tick is a short mono 16-bit WAV with a sound in it', () {
    final wav = cprTickWav();
    final d = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(d.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(d.getUint16(34, Endian.little), 16);
    final rate = d.getUint32(24, Endian.little);
    expect(rate, 44100);
    final n = d.getUint32(40, Endian.little) ~/ 2;
    expect(wav.length, 44 + n * 2);
    expect(n / rate, lessThan(0.05), reason: 'a short tick');
    var peak = 0;
    for (var i = 0; i < n; i++) {
      peak = peak < d.getInt16(44 + i * 2, Endian.little).abs() ? d.getInt16(44 + i * 2, Endian.little).abs() : peak;
    }
    expect(peak, greaterThan(15000), reason: 'it is audible');
    expect(d.getInt16(44 + (n - 1) * 2, Endian.little).abs(), lessThan(500), reason: 'and has died away at the end');
  });

  test('begin gives the platform the WAV, a tick and a buzz are one call each, end lets go', () async {
    final f = ChannelCprFeedback(available: true);
    await f.begin();
    await f.tick();
    await f.buzz();
    await f.end();
    expect(calls.map((c) => c.method), ['begin', 'tick', 'buzz', 'end']);
    expect((calls[0].arguments as Map)['wav'], isA<Uint8List>());
    expect((calls[2].arguments as Map)['ms'], kCprBuzzMs);
    expect(kCprBuzzMs, 40);
  });

  test('the breaths cue is a double tone and a double buzz, each only when its switch is on', () async {
    final f = ChannelCprFeedback(available: true);
    await f.breathsCue(sound: true, vibration: true);
    expect(calls.map((c) => c.method), ['tick', 'buzz', 'tick', 'buzz']);
    calls.clear();
    await f.breathsCue(sound: false, vibration: true);
    expect(calls.map((c) => c.method), ['buzz', 'buzz']);
    calls.clear();
    await f.breathsCue(sound: true, vibration: false);
    expect(calls.map((c) => c.method), ['tick', 'tick']);
  });

  test('where there is no phone (a computer, a browser) nothing is asked of the platform', () async {
    final f = ChannelCprFeedback(available: false);
    await f.begin();
    await f.tick();
    await f.buzz();
    await f.breathsCue(sound: true, vibration: true);
    await f.end();
    expect(calls, isEmpty);
  });

  test('a platform without the native side, or one that refuses, does not stop anything', () async {
    messenger.setMockMethodCallHandler(kCprChannel, null);
    final f = ChannelCprFeedback(available: true);
    await f.tick(); // MissingPluginException is swallowed
    messenger.setMockMethodCallHandler(kCprChannel, (call) async => throw PlatformException(code: 'no_audio'));
    await f.begin();
    await f.tick();
  });
}
