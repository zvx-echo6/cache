import 'dart:io';

import 'package:cache/platform/battery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(kBatteryChannel, null));

  test('the phone answers through the channel: level and plugged in', () async {
    Object? answer = {'percent': 42, 'charging': true};
    messenger.setMockMethodCallHandler(kBatteryChannel, (call) async {
      expect(call.method, 'read');
      return answer;
    });
    final r = await readBattery(mobile: true);
    expect(r?.percent, 42);
    expect(r?.charging, isTrue);
    expect(r?.low, isFalse);
    answer = {'percent': 15, 'charging': false};
    expect((await readBattery(mobile: true))?.low, isTrue);
    // How warm it is comes along: moderate and above is hot.
    answer = {'percent': 60, 'charging': false, 'thermal': 'moderate'};
    expect((await readBattery(mobile: true))?.thermal, Thermal.moderate);
    expect((await readBattery(mobile: true))?.thermal.hot, isTrue);
    answer = {'percent': 60, 'charging': false, 'thermal': 'light'};
    expect((await readBattery(mobile: true))?.thermal.hot, isFalse);
    answer = {'percent': 60, 'charging': false};
    expect((await readBattery(mobile: true))?.thermal, Thermal.unknown, reason: 'an older native side says nothing');
    // The phone cannot say: no reading.
    answer = {'percent': -1, 'charging': false};
    expect(await readBattery(mobile: true), isNull);
  });

  test('no native side (a desktop or a test): no reading, no error', () async {
    expect(await readBattery(mobile: true), isNull);
  });

  test('Linux: the first battery in the power-supply folder', () {
    final root = Directory.systemTemp.createTempSync('power');
    addTearDown(() => root.deleteSync(recursive: true));
    final ac = Directory('${root.path}/AC')..createSync();
    File('${ac.path}/type').writeAsStringSync('Mains\n');
    expect(readLinuxBattery(root.path), isNull);
    final bat = Directory('${root.path}/BAT0')..createSync();
    File('${bat.path}/type').writeAsStringSync('Battery\n');
    File('${bat.path}/capacity').writeAsStringSync('77\n');
    File('${bat.path}/status').writeAsStringSync('Discharging\n');
    final r = readLinuxBattery(root.path)!;
    expect((r.percent, r.charging), (77, false));
    File('${bat.path}/status').writeAsStringSync('Charging\n');
    expect(readLinuxBattery(root.path)!.charging, isTrue);
    expect(readLinuxBattery('${root.path}/none'), isNull);
  });
}
