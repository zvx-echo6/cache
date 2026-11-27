import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cache/platform/bluetooth.dart';
import 'package:cache/sharing/bluetooth_session.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

class _Platform extends BluetoothPlatform {
  BluetoothStatus state = const BluetoothStatus(supported: true, enabled: true);
  int requests = 0, stops = 0;
  final starts = <int>[];
  bool failStart = false;
  Future<BluetoothStatus> Function()? read;
  @override Future<BluetoothStatus> status() async => read == null ? state : await read!();
  @override Future<BluetoothStatus> requestPermissions() async { requests++; return state; }
  @override Future<BluetoothStatus> start(int handle) async {
    starts.add(handle);
    if (failStart) throw StateError('adapter failed');
    return state = BluetoothStatus(supported: true, enabled: true, handle: handle, active: true);
  }
  @override Future<void> stop([int? handle]) async {
    if (handle != null && state.handle != handle) return;
    stops++;
    state = BluetoothStatus(supported: state.supported, enabled: state.enabled, permissions: state.permissions);
  }
}

class _Core {
  int handle = 1, stops = 0;
  final policies = <Map<String, Object?>>[];
  final calls = <String>[];
  Future<Map<String, dynamic>> call(String method, Map<String, Object?> args) async {
    calls.add(method);
    switch (method) {
      case 'set_policy': policies.add(Map.of(args)); return {'ok': true};
      case 'bluetooth_status': return {'handle': handle};
      case 'bluetooth_start': return {'ok': true, 'handle': handle};
      case 'bluetooth_stop': stops++; return {'ok': true};
      default: throw StateError('Unexpected method $method');
    }
  }
}

class _Sync extends FakeSync {
  static int nextHandle = 100;
  int? handle;
  @override Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    switch (method) {
      case 'bluetooth_status': return {'handle': handle, 'peers': 0};
      case 'bluetooth_start': return {'ok': true, 'handle': handle ??= nextHandle++};
      case 'bluetooth_stop': handle = null; return {'ok': true};
      default: return super.call(method, args);
    }
  }
}

void main() {
  test('Sharing remembers Bluetooth before migration saves and starts paused until policy is applied', () async {
    final dir = await Directory.systemTemp.createTemp('bluetooth-sharing');
    final platform = _Platform();
    final policy = testPolicy(wifi: false);
    final sync = _Sync();
    Map<String, Object?>? opening;
    final sharing = SharingState(policy: policy, supportDir: () async => dir, kinds: const [], bluetooth: platform,
      opener: (config) async { opening = config; return sync; });
    await sharing.setUp();
    expect(opening!['network'], false);
    await sharing.setBluetooth(true);
    expect(sharing.bluetoothStatus.active, true);
    expect(sync.policies.last, {'network': true, 'ip_network': false});
    sharing.dispose();
    final flag = File('${dir.path}/sharing.json');
    final saved = jsonDecode(await flag.readAsString()) as Map<String, dynamic>;
    expect(saved['bluetooth'], true);
    saved.remove('ask_since'); // Exercise the existing migration save, not only a current-version read.
    await flag.writeAsString(jsonEncode(saved));
    final again = SharingState(policy: policy, supportDir: () async => dir, kinds: const [], bluetooth: platform,
      opener: (_) async => _Sync());
    await again.init();
    expect(again.bluetoothWanted, true);
    expect(again.bluetoothStatus.active, true);
    expect((jsonDecode(await flag.readAsString()) as Map)['bluetooth'], true);
    again.dispose();
    await Future<void>.delayed(Duration.zero);
    policy.settings.dispose();
    await dir.delete(recursive: true);
  });

  test('Bluetooth can run with IP denied, without polling waking repeated rounds', () async {
    final platform = _Platform();
    final core = _Core();
    final session = BluetoothSession(platform);
    final state = await session.reconcile(wanted: true, ipAllowed: false, core: core.call);
    expect(state.active, true);
    expect(core.policies, [{'network': true, 'ip_network': false}]);
    await session.reconcile(wanted: true, ipAllowed: false, core: core.call);
    expect(core.policies, hasLength(1));
    expect(platform.starts, [1]);
    expect(platform.requests, 0);
    await session.close();
  });

  test('missing permission never prompts from polling or starts a local session', () async {
    final platform = _Platform()..state = const BluetoothStatus(supported: true, permissions: ['scan']);
    final core = _Core();
    final session = BluetoothSession(platform);
    await session.reconcile(wanted: true, ipAllowed: false, core: core.call);
    expect(core.policies, [{'network': false, 'ip_network': false}]);
    expect(core.calls, isNot(contains('bluetooth_start')));
    expect(platform.requests, 0);
    await session.close();
  });

  test('failed adapter start rolls back without enabling disallowed IP', () async {
    final platform = _Platform()..failStart = true;
    final core = _Core();
    final session = BluetoothSession(platform);
    final state = await session.reconcile(wanted: true, ipAllowed: false, core: core.call);
    expect(state.error, isNotNull);
    expect(core.stops, 1);
    expect(core.policies.last, {'network': false, 'ip_network': false});
    expect(core.policies.every((p) => p['ip_network'] == false), true);
    await session.close();
  });

  test('a rotated core handle replaces the adapter on the next reconciliation', () async {
    final platform = _Platform();
    final core = _Core();
    final session = BluetoothSession(platform);
    await session.reconcile(wanted: true, ipAllowed: true, core: core.call);
    core.handle = 2;
    await session.reconcile(wanted: true, ipAllowed: true, core: core.call);
    expect(platform.starts, [1, 2]);
    expect(core.policies, hasLength(1));
    await session.close();
  });

  test('switching Bluetooth off stops both sides and returns non-active state', () async {
    final platform = _Platform();
    final core = _Core();
    final session = BluetoothSession(platform);
    await session.reconcile(wanted: true, ipAllowed: false, core: core.call);
    final state = await session.reconcile(wanted: false, ipAllowed: false, core: core.call);
    expect(state.active, false);
    expect(state.handle, isNull);
    expect(core.stops, 1);
    expect(core.policies.last, {'network': false, 'ip_network': false});
    await session.close();
  });

  test('closing during pending work prevents a late adapter start', () async {
    final pending = Completer<BluetoothStatus>();
    final platform = _Platform()..read = () => pending.future;
    final core = _Core();
    final session = BluetoothSession(platform);
    final work = session.reconcile(wanted: true, ipAllowed: false, core: core.call);
    await Future<void>.delayed(Duration.zero);
    final closing = session.close();
    pending.complete(const BluetoothStatus(supported: true, enabled: true));
    await work;
    await closing;
    expect(platform.starts, isEmpty);
    expect(core.calls, isEmpty);
  });

  test('a delayed old close cannot stop the replacement adapter', () async {
    final platform = _Platform();
    final first = BluetoothSession(platform);
    final core1 = _Core();
    await first.reconcile(wanted: true, ipAllowed: true, core: core1.call);
    final pending = Completer<BluetoothStatus>();
    platform.read = () => pending.future;
    final oldWork = first.reconcile(wanted: true, ipAllowed: true, core: core1.call);
    await Future<void>.delayed(Duration.zero);
    final closing = first.close();
    platform.read = null;
    final second = BluetoothSession(platform);
    final core2 = _Core()..handle = 2;
    await second.reconcile(wanted: true, ipAllowed: true, core: core2.call);
    pending.complete(const BluetoothStatus(supported: true, enabled: true, handle: 1, active: true));
    await oldWork;
    await closing;
    expect(platform.state.handle, 2);
    expect(platform.state.active, true);
    await second.close();
  });
}
