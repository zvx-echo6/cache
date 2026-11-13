import 'package:cache/platform/phone_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('co.cache/phone_window.test');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> fromPhone(Object? visible) async {
    await messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('changed', visible)), (_) {});
  }

  group('PhoneWindow', () {
    test('with nothing on the other side the window counts as on the screen', () async {
      final w = PhoneWindow(channel: channel);
      await w.start();
      expect(w.visible.value, isTrue);
    });

    test('it asks where the phone scene stands at start, and follows what the scene says after', () async {
      Object? answer = false;
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'get' ? answer : null);
      final w = PhoneWindow(channel: channel);
      await w.start();
      expect(w.visible.value, isFalse, reason: 'started by the car with the phone locked');
      await fromPhone(true);
      expect(w.visible.value, isTrue);
      await fromPhone(false);
      expect(w.visible.value, isFalse);
      // Something that is not yes or no changes nothing.
      await fromPhone('x');
      expect(w.visible.value, isFalse);
      // Asked again (the app came back to the screen): a missed message is made up for.
      answer = true;
      await w.refresh();
      expect(w.visible.value, isTrue);
    });
  });

  group('PhoneMapRest', () {
    test('the phone maps pause when the window leaves the screen and resume when it is back', () async {
      final visible = ValueNotifier<bool>(true);
      final rest = PhoneMapRest(visible);
      final said = <String>[];
      rest.add('a', pause: () async => said.add('a pause'), resume: () async => said.add('a resume'));
      rest.add('b', pause: () async => said.add('b pause'), resume: () async => said.add('b resume'));
      expect(said, isEmpty, reason: 'on the screen: nothing to do');
      visible.value = false;
      expect(said, ['a pause', 'b pause']);
      visible.value = true;
      expect(said, ['a pause', 'b pause', 'a resume', 'b resume']);
      // A map whose screen was closed is left alone.
      rest.remove('a');
      said.clear();
      visible.value = false;
      expect(said, ['b pause']);
      // A map made while the window is away is paused at once.
      rest.add('c', pause: () async => said.add('c pause'), resume: () async => said.add('c resume'));
      expect(said, ['b pause', 'c pause']);
      rest.dispose();
      visible.value = true;
      expect(said, ['b pause', 'c pause'], reason: 'disposed: follows nothing');
      visible.dispose();
    });

    test('a map that fails does not stop the others', () async {
      final visible = ValueNotifier<bool>(true);
      final rest = PhoneMapRest(visible);
      final said = <String>[];
      rest.add('gone', pause: () async => throw StateError('the map is gone'), resume: () async {});
      rest.add('here', pause: () async => said.add('pause'), resume: () async {});
      visible.value = false;
      await Future<void>.delayed(Duration.zero);
      expect(said, ['pause']);
      rest.dispose();
      visible.dispose();
    });
  });
}
