import 'package:cache/car/siri_place_names.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('co.cache/car');
  late List<List<String>> sent;
  late List<String> names;
  late int reads;
  late ChangeNotifier changed;
  late SiriPlaceNames siri;

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

  setUp(() {
    sent = [];
    names = ['Home', 'Cabin'];
    reads = 0;
    changed = ChangeNotifier();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'siriPlaces') sent.add([for (final n in (call.arguments as Map)['names'] as List) n as String]);
      return null;
    });
    siri = SiriPlaceNames(
      read: () async {
        reads++;
        return [...names];
      },
      changes: [changed],
      delay: const Duration(milliseconds: 20),
    );
  });

  tearDown(() {
    siri.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('the names go to the iPhone side once when the app starts', () async {
    siri.start();
    await settle();
    expect(sent, [
      ['Home', 'Cabin']
    ]);
  });

  test('changing the saved places sends the new names, in the order read', () async {
    siri.start();
    await settle();
    names = ['Cabin', 'Home', 'Shop'];
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    changed.notifyListeners();
    await settle();
    expect(sent.last, ['Cabin', 'Home', 'Shop']);
    expect(sent, hasLength(2));
  });

  test('names that did not change are not sent again', () async {
    siri.start();
    await settle();
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    changed.notifyListeners();
    await settle();
    expect(sent, hasLength(1));
  });

  test('a storm of changes is read once', () async {
    siri.start();
    await settle();
    final before = reads;
    names = ['Home'];
    for (var i = 0; i < 20; i++) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      changed.notifyListeners();
    }
    await settle();
    expect(reads - before, 1);
    expect(sent.last, ['Home']);
  });
}
