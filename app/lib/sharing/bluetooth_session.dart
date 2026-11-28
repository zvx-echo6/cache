import '../platform/bluetooth.dart';
import '../platform/app_log.dart';

typedef BluetoothCoreCall = Future<Map<String, dynamic>> Function(String method, Map<String, Object?> args);

/// Serializes policy and handle reconciliation on the existing Sharing poll, not a second timer. Permission prompts happen
/// only through the explicit platform action; polling never asks. Closing prevents late async work from starting an adapter.
class BluetoothSession {
  BluetoothSession(this.platform);
  final BluetoothPlatform platform;
  Future<BluetoothStatus>? _tail;
  bool _closed = false;
  int? _owned;
  (bool, bool)? _lastPolicy;

  Future<void> _policy(BluetoothCoreCall core, bool network, bool ip) async {
    if (_lastPolicy == (network, ip)) return;
    await core('set_policy', {'network': network, 'ip_network': ip});
    _lastPolicy = (network, ip);
  }

  Future<BluetoothStatus> reconcile({required bool wanted, required bool ipAllowed, required BluetoothCoreCall core}) {
    final previous = _tail;
    late final Future<BluetoothStatus> next;
    next = (previous == null ? _run(wanted, ipAllowed, core)
        : previous.then<BluetoothStatus>((_) => _run(wanted, ipAllowed, core), onError: (Object _) => _run(wanted, ipAllowed, core)))
        .whenComplete(() { if (identical(_tail, next)) _tail = null; });
    _tail = next;
    return next;
  }

  Future<BluetoothStatus> _run(bool wanted, bool ipAllowed, BluetoothCoreCall core) async {
    if (_closed) return const BluetoothStatus();
    var state = const BluetoothStatus();
    var stage = 'platform status';
    try {
      state = await platform.status();
      if (_closed) return state;
      final local = wanted && state.supported && state.enabled;
      if (!local) {
        if (_owned != null) {
          stage = 'platform stop';
          await platform.stop(_owned);
          if (_closed) return state;
          stage = 'core stop';
          await core('bluetooth_stop', const {});
          _owned = null;
        }
        if (_closed) return state;
        stage = 'idle policy';
        await _policy(core, ipAllowed, ipAllowed);
        stage = 'idle platform status';
        return _closed ? state : await platform.status();
      }
      // Verify the core supports the mobile contract before allowing a non-IP round; an old core must not ignore IP policy
      // and then fall back to iroh while the new UI believes only Bluetooth is permitted.
      stage = 'core contract status';
      await core('bluetooth_status', const {});
      if (_closed) return state;
      stage = 'active policy';
      await _policy(core, true, ipAllowed);
      if (_closed) return state;
      stage = 'core start';
      final handle = (await core('bluetooth_start', const {}))['handle'] as int;
      _owned = handle;
      if (_closed) return state;
      stage = 'platform start';
      if (state.handle != handle) state = await platform.start(handle);
      stage = 'platform readiness';
      if (!state.supported || !state.enabled || state.handle != handle) throw StateError('Bluetooth adapter did not start');
      if (_closed) { await platform.stop(_owned); return state; }
      stage = 'backend status';
      final backend = await core('bluetooth_status', const {});
      if (backend['error'] != null) throw StateError('Bluetooth backend: ${backend['error']}');
      return state.withActive(state.active && backend['ready'] != false);
    } catch (error, stack) {
      // Capture the original failure before stop drops the Apple session and its stored backend error.
      // logError keeps error text/stack at Detailed, following the app's existing privacy levels.
      logError('Sharing: Bluetooth failed during $stage', error: error, stack: stack,
        detail: 'wanted=$wanted ipAllowed=$ipAllowed supported=${state.supported} enabled=${state.enabled} active=${state.active}');
      if (_owned != null) {
        try { await platform.stop(_owned); } catch (_) { /* Keep the original failure. */ }
      }
      if (!_closed) {
        try { await core('bluetooth_stop', const {}); } catch (_) { /* The core may not have opened a session. */ }
        await _policy(core, ipAllowed, ipAllowed);
      }
      _owned = null;
      return state.failed(error);
    }
  }

  Future<void> close() {
    _closed = true;
    final previous = _tail;
    Future<void> stopOwned() async {
      final handle = _owned;
      _owned = null;
      if (handle != null) await platform.stop(handle);
    }
    return previous == null ? stopOwned() : previous.then((_) => stopOwned(), onError: (Object _) => stopOwned());
  }
}
