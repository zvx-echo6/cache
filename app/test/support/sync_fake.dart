import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lines of the link code under the QR on "Show my link code" (one line, or two when it does not fit one).
List<String> linkCodeLines(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byKey(const ValueKey('link-code-text')), matching: find.byType(Text)))
    .map((t) => t.data!)
    .toList();

/// A sync engine with no network: remembers shares and peers, and answers like the real one.
class FakeSync implements SyncCoreLike {
  final calls = <String>[];
  /// Each call's arguments, by method.
  final argsOf = <String, List<Map<String, Object?>>>{};
  final policies = <Map<String, Object?>>[];
  final shares = <Map<String, Object?>>[];
  final peers = <Map<String, Object?>>[];
  String name = 'Test phone';

  /// When set, `link` fails with it (as the engine does).
  Object? linkError;

  /// The code `link_code` answers (a test of the QR gives a real-sized one).
  String codeOverride = 'CACHE-7KQF-M2XD-P4WN-R7TA-H3JC-V6YB-Q5LE-W2FS-ZQ';

  /// The free space and the kept-free reserve `status` answers.
  int freeBytes = 10 << 30;
  int reserveBytes = 1 << 30;

  /// This device's key.
  String id = 'me';
  bool closed = false;

  /// The keys given for each device (`set_secrets`), as last set.
  final secrets = <String, Map<String, String>>{};

  /// What `take_secrets` hands over next, by device.
  final inbox = <String, Map<String, String>>{};

  /// What `share_items` answers, by share id (rows as the engine gives them: name, files, bytes, peers).
  final items = <String, List<Map<String, Object?>>>{};

  /// The items switched off, by share id, as `set_off` last left them.
  final off = <String, List<String>>{};

  /// Makes a peer report how it is reached now: `via` is 'direct', 'relay' or 'wifi' (Reticulum's local discovery), and it was just seen.
  void reach(String peer, String via) {
    final p = peers.firstWhere((p) => p['id'] == peer);
    p['via'] = via;
    p['last_seen'] = DateTime.now().millisecondsSinceEpoch;
    p['error'] = null;
  }

  /// The entry points (what `entry_points` answers), each `{id, host, port, private, network_name, has_passphrase, on, cap_bytes, t,
  /// dev, status, checked}`; a test sets `status` by hand to walk the states the engine reports.
  final entries = <Map<String, Object?>>[];

  /// What `status` lists as waiting (step 3): `{peer, peer_name, share_id, share, path, what, size, reason}`.
  final waiting = <Map<String, Object?>>[];

  /// Makes a peer reach through the entry point [entryId] and be judged [speed] ("fast", "medium" or "slow").
  void reachThrough(String peer, String entryId, {String speed = 'fast'}) {
    reach(peer, 'entry:$entryId');
    peers.firstWhere((p) => p['id'] == peer)['speed'] = speed;
  }

  /// Adds an entry point as the engine lists one.
  Map<String, Object?> addEntry(String id, String host, int port, {bool private = false, String? network, bool pass = false, bool on = true, String status = 'connected', int cap = 50 << 20}) {
    final e = <String, Object?>{
      'id': id, 'host': host, 'port': port, 'private': private, 'network_name': network, 'has_passphrase': pass, 'on': on,
      'cap_bytes': cap, 't': 1, 'dev': 'me', 'status': on ? status : 'off', 'checked': DateTime.now().millisecondsSinceEpoch,
    };
    entries.add(e);
    return e;
  }

  // Nearby linking (the engine's `pairing_*` and `nearby_*` calls). A test sets [nearbyDevices] and [nearbyState] by hand to walk the
  // states the engine goes through; the three `nearbyAfter` fields are what the person's own taps leave behind.

  /// True between `pairing_open` and `pairing_close`.
  bool pairingOpen = false;

  /// When set, `pairing_open` fails with it (an engine with no Nearby here).
  Object? pairingOpenError;

  /// What `nearby_list` answers: `{id, name (null: not known yet), via}`.
  final nearbyDevices = <Map<String, Object?>>[];

  /// What `nearby_state` answers.
  Map<String, Object?> nearbyState = {'state': 'idle'};

  /// The state after `nearby_link`, after `nearby_answer` with ok true, and with ok false.
  Map<String, Object?> nearbyAfterLink = {'state': 'exchanging', 'name': 'Pixel 8'};
  Map<String, Object?> nearbyAfterYes = {'state': 'waiting', 'name': 'Pixel 8'};
  Map<String, Object?> nearbyAfterNo = {'state': 'dropped', 'reason': 'cancelled'};

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    calls.add(method);
    argsOf.putIfAbsent(method, () => []).add(Map.of(args));
    if (method == 'set_policy') policies.add(Map.of(args));
    switch (method) {
      case 'status':
        return {
          'id': id,
          'name': name,
          'relay': 'https://relay.example',
          'network': true,
          'free_bytes': freeBytes,
          'reserve_bytes': reserveBytes,
          'peers': peers,
          'shares': [for (final s in shares) {'files': 0, 'bytes': 0, 'pending_files': 0, 'pending_bytes': 0, ...s, 'off': off[s['id']]}],
          'offers': [],
          if (waiting.isNotEmpty) 'waiting': waiting,
          'transfer': null,
          'paused': null,
          'log': [],
        };
      case 'entry_points':
        return {'entries': [for (final e in entries) Map<String, Object?>.of(e)]};
      case 'entry_point_set':
        // The engine's checks and its plain messages.
        final id = args['id'] as String?;
        final have = id == null ? null : entries.where((e) => e['id'] == id).firstOrNull;
        if (id != null && have == null) throw Exception('There is no such entry point.');
        final host = ((args['host'] ?? have?['host'] ?? '') as String).trim();
        final port = (args['port'] ?? have?['port'] ?? 0) as int;
        final private = (args['private'] ?? have?['private'] ?? false) as bool;
        final network = args.containsKey('network_name') ? (args['network_name'] as String?) : have?['network_name'] as String?;
        final pass = args['passphrase'] != null ? (args['passphrase'] as String).isNotEmpty : (have?['has_passphrase'] ?? false) as bool;
        if (host.isEmpty) throw Exception('Enter the address of the entry point.');
        if (port < 1 || port > 65535) throw Exception('The port has to be a number from 1 to 65535.');
        if (private && (network ?? '').isEmpty && !pass) throw Exception('A private entry point needs a network name or a passphrase.');
        if (entries.any((e) => e['id'] != id && e['port'] == port && (e['host'] as String).toLowerCase() == host.toLowerCase())) {
          throw Exception('That entry point is already in your list.');
        }
        final nid = id ?? 'e${entries.length + 1}${DateTime.now().microsecondsSinceEpoch}';
        final rec = <String, Object?>{
          'id': nid, 'host': host, 'port': port, 'private': private, 'network_name': private && (network ?? '').isNotEmpty ? network : null,
          'has_passphrase': private && pass, 'on': (args['on'] ?? have?['on'] ?? true) as bool, 'cap_bytes': args['cap_bytes'] ?? have?['cap_bytes'] ?? (50 << 20),
          't': ((have?['t'] as int?) ?? 0) + 1, 'dev': 'me', 'status': 'connecting', 'checked': DateTime.now().millisecondsSinceEpoch,
        };
        entries
          ..removeWhere((e) => e['id'] == nid)
          ..add(rec);
        return {'ok': true, 'id': nid};
      case 'entry_point_on':
        final e = entries.where((e) => e['id'] == args['id']).firstOrNull;
        if (e == null) throw Exception('There is no such entry point.');
        e['on'] = args['on'];
        e['status'] = args['on'] == true ? 'connecting' : 'off';
        return {'ok': true};
      case 'entry_point_remove':
        entries.removeWhere((e) => e['id'] == args['id']);
        return {'ok': true};
      case 'link_code':
        return {'code': codeOverride, 'valid_secs': 900};
      case 'link':
        if (linkError != null) throw linkError!;
        peers.removeWhere((p) => p['id'] == 'peer1');
        // As the engine makes a link: Off, waiting for the answer.
        peers.add({
          'id': 'peer1', 'name': 'Desk', 'linked': DateTime.now().millisecondsSinceEpoch, 'last_seen': null, 'via': null, 'error': null,
          'link': {'mode': 'off', 'ask': true}, 'link_t': 0,
        });
        return {'ok': true, 'peer': 'peer1', 'name': 'Desk'};
      case 'share_add':
        // Like the engine: the same id again re-points the share (its name stays).
        final have = shares.where((s) => s['id'] == args['id']).firstOrNull;
        if (have != null) {
          have['path'] = args['path'];
        } else {
          shares.add({'id': args['id'], 'name': args['name'], 'path': args['path']});
        }
        return {'ok': true, 'id': args['id']};
      case 'share_remove':
        shares.removeWhere((s) => s['id'] == args['id']);
        return {'ok': true};
      case 'set_name':
        name = args['name'] as String;
        return {'ok': true};
      case 'set_peer_name':
        final p = peers.where((p) => p['id'] == args['peer']).firstOrNull;
        if (p == null) throw Exception('that device is not linked');
        p['name'] = args['name'];
        return {'ok': true};
      case 'unlink':
        peers.removeWhere((p) => p['id'] == args['peer']);
        return {'ok': true};
      case 'set_off':
        final list = [for (final x in (args['off'] as List? ?? const [])) '$x'];
        if (list.isEmpty) {
          off.remove(args['id']);
        } else {
          off[args['id'] as String] = list;
        }
        return {'ok': true};
      case 'set_link':
        final p = peers.where((p) => p['id'] == args['peer']).firstOrNull;
        if (p == null) throw Exception('that device is not linked');
        p['link'] = Map<String, Object?>.of((args['link'] as Map).cast<String, Object?>());
        p['link_t'] = ((p['link_t'] as int?) ?? 0) + 1;
        return {'ok': true, 't': p['link_t']};
      case 'set_secrets':
        final m = {for (final e in ((args['secrets'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
        if (m.isEmpty) {
          secrets.remove(args['peer']);
        } else {
          secrets[args['peer'] as String] = m;
        }
        return {'ok': true};
      case 'take_secrets':
        final out = {for (final e in inbox.entries) e.key: Map.of(e.value)};
        inbox.clear();
        return {'secrets': out};
      case 'pairing_open':
        if (pairingOpenError != null) throw pairingOpenError!;
        pairingOpen = true;
        return {};
      case 'pairing_close':
        pairingOpen = false;
        nearbyState = {'state': 'idle'};
        return {};
      case 'nearby_list':
        return {'devices': [for (final d in nearbyDevices) Map<String, Object?>.of(d)]};
      case 'nearby_state':
        return Map<String, Object?>.of(nearbyState);
      case 'nearby_link':
        nearbyState = Map.of(nearbyAfterLink);
        return {};
      case 'nearby_answer':
        nearbyState = Map.of(args['ok'] == true ? nearbyAfterYes : nearbyAfterNo);
        return {};
      case 'share_items':
        return {'items': items[args['id']] ?? const []};
      default:
        return {'ok': true};
    }
  }

  @override
  Future<void> close() async => closed = true;
}
