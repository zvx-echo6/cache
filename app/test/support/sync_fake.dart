import 'package:cache/sharing/sharing_state.dart';

/// A sync engine with no network: remembers shares and peers, and answers like the real one.
class FakeSync implements SyncCoreLike {
  final calls = <String>[];
  final policies = <Map<String, Object?>>[];
  final shares = <Map<String, Object?>>[];
  final peers = <Map<String, Object?>>[];
  String name = 'Test phone';
  bool closed = false;

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    calls.add(method);
    if (method == 'set_policy') policies.add(Map.of(args));
    switch (method) {
      case 'status':
        return {
          'id': 'me',
          'name': name,
          'relay': 'https://relay.example',
          'network': true,
          'free_bytes': 10 << 30,
          'reserve_bytes': 1 << 30,
          'peers': peers,
          'shares': [for (final s in shares) {...s, 'files': 0, 'bytes': 0, 'pending_files': 0, 'pending_bytes': 0}],
          'offers': [],
          'transfer': null,
          'paused': null,
          'log': [],
        };
      case 'link_code':
        return {'code': 'CACHE1-TESTCODE', 'valid_secs': 900};
      case 'link':
        peers.add({'id': 'peer1', 'name': 'Desk', 'linked': 1, 'last_seen': null, 'via': null, 'error': null});
        return {'ok': true, 'name': 'Desk'};
      case 'share_add':
        shares.add({'id': args['id'], 'name': args['name'], 'path': args['path']});
        return {'ok': true, 'id': args['id']};
      case 'share_remove':
        shares.removeWhere((s) => s['id'] == args['id']);
        return {'ok': true};
      case 'set_name':
        name = args['name'] as String;
        return {'ok': true};
      default:
        return {'ok': true};
    }
  }

  @override
  Future<void> close() async => closed = true;
}
