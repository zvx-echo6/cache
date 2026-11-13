import 'package:cache/car/car_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(kBuildChannel, null));

  void answer(Object? value) {
    messenger.setMockMethodCallHandler(kBuildChannel, (call) async => call.method == 'get' ? value : null);
  }

  test('an iPhone build made with the car screen says so', () async {
    answer({'carPlay': true});
    expect(await readCarScreenSupport(android: false, ios: true), isTrue);
  });

  test('an iPhone build made without it has no car screen', () async {
    answer({'carPlay': false});
    expect(await readCarScreenSupport(android: false, ios: true), isFalse);
  });

  test('no native answer (an older iPhone build): no car screen, and no error', () async {
    expect(await readCarScreenSupport(android: false, ios: true), isFalse);
  });

  test('an answer of another shape is a no', () async {
    answer('yes');
    expect(await readCarScreenSupport(android: false, ios: true), isFalse);
    answer({'carPlay': 'true'});
    expect(await readCarScreenSupport(android: false, ios: true), isFalse);
  });

  test('each phone reads its own flag from the answer', () async {
    answer({'androidAuto': true, 'carPlay': false});
    expect(await readCarScreenSupport(android: true, ios: false), isTrue);
    expect(await readCarScreenSupport(android: false, ios: true), isFalse);
  });

  test('neither phone: the native side is not asked', () async {
    var asked = 0;
    messenger.setMockMethodCallHandler(kBuildChannel, (call) async {
      asked++;
      return {'carPlay': true, 'androidAuto': true};
    });
    expect(await readCarScreenSupport(android: false, ios: false), isFalse);
    expect(asked, 0);
  });
}
