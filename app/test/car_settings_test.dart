import 'package:cache/car/car_support.dart';
import 'package:cache/car/route_pushes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    carScreenSupported.value = false;
    messenger.setMockMethodCallHandler(kBuildChannel, null);
  });

  group('the car screen gate (cache/build)', () {
    test('true only when the Android build says it has Android Auto', () async {
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async => {'androidAuto': true});
      expect(await readCarScreenSupport(android: true), isTrue);
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async => {'androidAuto': false});
      expect(await readCarScreenSupport(android: true), isFalse);
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async => throw PlatformException(code: 'x'));
      expect(await readCarScreenSupport(android: true), isFalse);
    });

    test('false off Android without asking', () async {
      var asked = false;
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async {
        asked = true;
        return {'androidAuto': true};
      });
      expect(await readCarScreenSupport(android: false), isFalse);
      expect(asked, isFalse);
    });
  });

  // Bug: a navigation request's "geo:" address reached Flutter as a route to push, and the app threw on the unknown route.
  group('an address pushed by the platform as a route', () {
    Future<void> pushRoute(WidgetTester t, String location) => t.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/navigation', const JSONMethodCodec().encodeMethodCall(MethodCall('pushRouteInformation', {'location': location, 'state': null})), (_) {});

    testWidgets('is taken and nothing opens or throws', (t) async {
      final guard = IgnoreRoutePushes();
      WidgetsBinding.instance.addObserver(guard);
      addTearDown(() => WidgetsBinding.instance.removeObserver(guard));
      await t.pumpWidget(const MaterialApp(home: Text('home')));
      await pushRoute(t, 'geo:0,0?q=Made+Up+Clinic');
      await pushRoute(t, 'geo:42.5,-113.5');
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('home'), findsOneWidget);
    });
  });
}
