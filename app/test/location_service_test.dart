import 'dart:async';
import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSource implements PositionSource {
  LocationPermissionState state = LocationPermissionState.notAsked;
  LocationPermissionState afterPrompt = LocationPermissionState.granted;
  bool service = true;
  int prompts = 0;
  int permissionReads = 0;
  int serviceReads = 0;
  int currentCalls = 0;
  int streamStarts = 0;
  Future<LocationPermissionState>? pendingPermission;
  Future<LocationPermissionState>? pendingPrompt;
  Future<bool>? pendingService;
  Future<Fix>? pendingFix;
  Fix next = Fix(lat: 42.5, lon: -113.8, accuracyM: 12, time: DateTime(2026, 10, 25, 14, 20, 5));
  final StreamController<Fix> controller = StreamController<Fix>.broadcast();

  @override
  Future<LocationPermissionState> permission() async {
    permissionReads++;
    return pendingPermission == null ? state : await pendingPermission!;
  }
  @override
  Future<LocationPermissionState> requestPermission() async {
    prompts++;
    return state = pendingPrompt == null ? afterPrompt : await pendingPrompt!;
  }

  @override
  Future<bool> serviceEnabled() async {
    serviceReads++;
    return pendingService == null ? service : await pendingService!;
  }
  @override
  Future<Fix> current() async {
    currentCalls++;
    return pendingFix == null ? next : await pendingFix!;
  }
  @override
  Stream<Fix> stream() {
    streamStarts++;
    return controller.stream;
  }
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('loc'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<LocationService> make(FakeSource s, {void Function(Fix?)? onFix}) async {
    final l = LocationService(source: s, settingsDirOverride: dir, onFix: onFix);
    await l.init();
    addTearDown(l.dispose);
    return l;
  }

  test('init never asks for permission', () async {
    final s = FakeSource();
    final l = await make(s);
    expect(s.prompts, 0);
    expect(l.fix, isNull);
  });

  test('the first need shows the reason; a no there means no system prompt', () async {
    final s = FakeSource();
    final l = await make(s);
    var explained = 0;
    expect(await l.request(explain: () async => ++explained < 0), isFalse);
    expect(explained, 1);
    expect(s.prompts, 0);
  });

  test('a yes asks the system, reads a fix and keeps listening', () async {
    final s = FakeSource();
    final l = await make(s);
    expect(await l.request(explain: () async => true), isTrue);
    expect(s.prompts, 1);
    expect(l.fix!.lat, 42.5);
    expect(l.fix!.accuracyM, 12);
    s.controller.add(Fix(lat: 43, lon: -114, accuracyM: 5, time: DateTime(2026, 10, 25, 14, 21)));
    await Future<void>.delayed(Duration.zero);
    expect(l.fix!.lat, 43);
  });

  test('a granted permission does not ask again', () async {
    final s = FakeSource()..state = LocationPermissionState.granted;
    final l = await make(s);
    var explained = 0;
    await l.request(explain: () async => ++explained > 0);
    expect(explained, 0);
    expect(s.prompts, 0);
    expect(l.fix, isNotNull);
  });

  test('refused and blocked are reported', () async {
    final s = FakeSource()..afterPrompt = LocationPermissionState.denied;
    final l = await make(s);
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.permissionDenied);
    s.state = LocationPermissionState.deniedForever;
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.permissionBlocked);
  });

  test('the phone\'s location switch being off is reported', () async {
    final s = FakeSource()
      ..state = LocationPermissionState.granted
      ..service = false;
    final l = await make(s);
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.serviceOff);
  });

  test('turning it off forgets the fix, stops listening, and is remembered', () async {
    final s = FakeSource();
    final l = await make(s);
    await l.request(explain: () async => true);
    await l.setEnabled(false);
    expect(l.fix, isNull);
    s.controller.add(Fix(lat: 1, lon: 1, accuracyM: 1, time: DateTime.now()));
    await Future<void>.delayed(Duration.zero);
    expect(l.fix, isNull);
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.off);

    final again = await make(s);
    expect(again.enabled, isFalse);
  });

  Future<void> resume(LocationService l) async {
    l.didChangeAppLifecycleState(AppLifecycleState.paused);
    l.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
  }

  test('routine resume never asks or labels an unasked permission denied', () async {
    final s = FakeSource();
    final l = await make(s);
    await resume(l);
    expect(s.prompts, 0);
    expect(l.permission, LocationPermissionState.notAsked);
    expect(l.problem, isNull);
    expect(s.currentCalls, 0);
    expect(s.streamStarts, 0);
  });

  test('grant in Settings recovers a fresh fix and stream without prompting', () async {
    final s = FakeSource()..state = LocationPermissionState.deniedForever;
    final fixes = <Fix?>[];
    final l = await make(s, onFix: fixes.add);
    s.state = LocationPermissionState.granted;
    await resume(l);
    expect(l.permission, LocationPermissionState.granted);
    expect(l.fix, same(s.next));
    expect(fixes.last, same(s.next));
    expect(l.problem, isNull);
    expect(s.currentCalls, 1);
    expect(s.streamStarts, 1);
    expect(s.prompts, 0);
    final next = Fix(lat: 43, lon: -114, accuracyM: 5, time: DateTime.now());
    s.controller.add(next);
    await Future<void>.delayed(Duration.zero);
    expect(l.fix, same(next));
  });

  for (final denied in [LocationPermissionState.notAsked, LocationPermissionState.deniedForever]) {
    test('Settings revocation ($denied) clears the fix and core', () async {
      final s = FakeSource()..state = LocationPermissionState.granted;
      final fixes = <Fix?>[];
      final l = await make(s, onFix: fixes.add);
      await l.request(explain: () async => true);
      s.state = denied;
      await resume(l);
      expect(l.fix, isNull);
      expect(fixes.last, isNull);
      expect(l.problem, denied == LocationPermissionState.deniedForever
          ? LocationProblem.permissionBlocked : LocationProblem.permissionDenied);
      expect(s.controller.hasListener, isFalse);
      expect(s.prompts, 0);
    });
  }

  test('system location off clears core; switching it back on recovers', () async {
    final s = FakeSource()..state = LocationPermissionState.granted;
    final fixes = <Fix?>[];
    final l = await make(s, onFix: fixes.add);
    await l.request(explain: () async => true);
    s.service = false;
    await resume(l);
    expect(l.fix, isNull);
    expect(fixes.last, isNull);
    expect(l.problem, LocationProblem.serviceOff);
    expect(s.controller.hasListener, isFalse);
    s.service = true;
    await resume(l);
    expect(l.fix, same(s.next));
    expect(l.problem, isNull);
    expect(s.controller.hasListener, isTrue);
    expect(s.prompts, 0);
  });

  test('disabled location does not query or restart on resume', () async {
    final s = FakeSource()..state = LocationPermissionState.granted;
    final l = await make(s);
    await l.setEnabled(false);
    final reads = s.permissionReads;
    await resume(l);
    expect(s.permissionReads, reads);
    expect(s.currentCalls, 0);
    expect(s.controller.hasListener, isFalse);
    expect(l.fix, isNull);
  });

  test('resume while guidance holds location does not acquire a fix or stream', () async {
    final s = FakeSource()..state = LocationPermissionState.granted;
    final l = await make(s);
    l.holdStream(true);
    final starts = s.streamStarts;
    await resume(l);
    expect(s.serviceReads, 1);
    expect(s.currentCalls, 0);
    expect(s.streamStarts, starts);
    l.publish(s.next);
    expect(l.fix, same(s.next));
    l.holdStream(false);
    expect(s.streamStarts, starts + 1);
  });

  test('service off while guidance holds cannot restart on release', () async {
    final s = FakeSource()..state = LocationPermissionState.granted;
    final l = await make(s);
    l.holdStream(true);
    l.publish(s.next);
    s.service = false;
    await resume(l);
    l.holdStream(false);
    expect(l.fix, isNull);
    expect(l.problem, LocationProblem.serviceOff);
    expect(s.controller.hasListener, isFalse);
    expect(s.currentCalls, 0);
  });

  for (final stage in ['permission', 'service', 'fix']) {
    test('dispose during awaited resume $stage ignores its completion', () async {
      final s = FakeSource()..state = LocationPermissionState.granted;
      final fixes = <Fix?>[];
      final l = await make(s, onFix: fixes.add);
      final permission = Completer<LocationPermissionState>();
      final service = Completer<bool>();
      final fix = Completer<Fix>();
      if (stage == 'permission') s.pendingPermission = permission.future;
      if (stage == 'service') s.pendingService = service.future;
      if (stage == 'fix') s.pendingFix = fix.future;
      await resume(l);
      final starts = s.streamStarts;
      l.dispose();
      permission.complete(LocationPermissionState.granted);
      service.complete(true);
      fix.complete(s.next);
      await Future<void>.delayed(Duration.zero);
      expect(fixes, isEmpty);
      expect(s.streamStarts, starts);
      expect(s.controller.hasListener, isFalse);
    });
  }

  for (final interruption in ['background', 'disabled', 'guidance']) {
    test('pending resume fix is ignored after $interruption', () async {
      final s = FakeSource()..state = LocationPermissionState.granted;
      final fixes = <Fix?>[];
      final l = await make(s, onFix: fixes.add);
      final fix = Completer<Fix>();
      s.pendingFix = fix.future;
      await resume(l);
      if (interruption == 'background') {
        l.didChangeAppLifecycleState(AppLifecycleState.paused);
      } else if (interruption == 'disabled') {
        await l.setEnabled(false);
      } else {
        l.holdStream(true);
      }
      final published = fixes.length;
      fix.complete(s.next);
      await Future<void>.delayed(Duration.zero);
      expect(fixes.length, published);
      expect(l.fix, isNull);
      expect(s.controller.hasListener, isFalse);
    });
  }

  test('an older resume cannot overwrite a newer permission result', () async {
    final s = FakeSource()..state = LocationPermissionState.granted;
    final fixes = <Fix?>[];
    final l = await make(s, onFix: fixes.add);
    final old = Completer<LocationPermissionState>();
    s.pendingPermission = old.future;
    await resume(l);
    s.pendingPermission = null;
    s.state = LocationPermissionState.deniedForever;
    await resume(l);
    final count = fixes.length;
    old.complete(LocationPermissionState.granted);
    await Future<void>.delayed(Duration.zero);
    expect(l.permission, LocationPermissionState.deniedForever);
    expect(l.problem, LocationProblem.permissionBlocked);
    expect(fixes.length, count);
    expect(s.currentCalls, 0);
    expect(s.controller.hasListener, isFalse);
  });

  test('permission-dialog resume does not run recovery alongside a request', () async {
    final s = FakeSource();
    final l = await make(s);
    final prompt = Completer<LocationPermissionState>();
    s.pendingPrompt = prompt.future;
    final request = l.request(explain: () async => true);
    await Future<void>.delayed(Duration.zero);
    expect(l.busy, isTrue);
    final reads = s.permissionReads;
    await resume(l);
    expect(s.permissionReads, reads);
    expect(s.currentCalls, 0);
    prompt.complete(LocationPermissionState.granted);
    expect(await request, isTrue);
    expect(s.currentCalls, 1);
    expect(s.prompts, 1);
    // A later trip to Settings is still rechecked normally.
    s.state = LocationPermissionState.deniedForever;
    await resume(l);
    expect(l.fix, isNull);
    expect(l.problem, LocationProblem.permissionBlocked);
  });
}
