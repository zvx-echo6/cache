import 'package:cache_search/cache_search.dart';

import 'sync_fake.dart';

/// Cache Server's sharing host as a browser reaches it (`sharing.*` through `/api/core`), on a [FakeSync] engine with no network:
/// the same ops, answers and refusals as server/helper/bin/sharing_host.dart, so the web driver of SharingState runs against it.
class FakeSharingHost implements CoreTransport {
  FakeSharingHost({required this.table});

  /// The server's share table: kind id -> {share id: folder}.
  final Map<String, Map<String, String>> table;

  final FakeSync sync = FakeSync()..name = 'Cache Server';

  /// Every op asked, in order, and the arguments of each.
  final List<String> ops = [];
  final List<Map<String, dynamic>> opArgs = [];

  bool enabled = false;
  final Map<String, Set<String>> off = {};
  Map<String, dynamic> link = {'state': 'idle'};

  /// How many `sharing.state` reads still answer "linking" after `sharing.link_start` before the engine's answer arrives.
  int linkingReads = 2;
  String? _linkCode;
  int _linkReads = 0;

  /// When set, every `sharing.state` fails with it (a server that has no sharing host).
  Object? stateError;

  /// The methods a browser may call (SharingHost.browserMethods).
  static const allowed = {'link_code', 'unlink', 'set_name', 'set_peer_name', 'set_link', 'sync_now', 'share_items'};

  int count(String op) => ops.where((o) => o == op).length;

  Future<Map<String, dynamic>> _snapshot() async {
    if (_linkCode != null && _linkReads++ >= linkingReads) {
      final code = _linkCode!;
      _linkCode = null;
      try {
        final r = await sync.call('link', {'code': code});
        link = {'state': 'done', 'peer': r['peer'], 'name': r['name']};
      } catch (e) {
        link = {'state': 'failed', 'error': e is CacheSearchException ? e.message : '$e'};
      }
    }
    return {
      'enabled': enabled,
      'running': enabled,
      'starting': false,
      'error': null,
      'name': sync.name,
      'status': enabled ? await sync.call('status') : <String, dynamic>{},
      'ask_since': 1,
      'kinds': [for (final e in table.entries) {'id': e.key, 'label': e.key, 'shares': e.value.keys.toList()}],
      'off': {for (final e in off.entries) if (e.value.isNotEmpty) e.key: ([...e.value]..sort())},
      'changed': <String, dynamic>{},
      'link': {...link},
    };
  }

  bool _shared(String id) => sync.shares.any((s) => s['id'] == id);

  Future<void> _addKind(String kind) async {
    for (final e in table[kind]!.entries) {
      if (!_shared(e.key)) await sync.call('share_add', {'id': e.key, 'name': e.key, 'path': e.value});
    }
  }

  @override
  Future<dynamic> call(String op, Map<String, dynamic> args) async {
    ops.add(op);
    opArgs.add(Map.of(args));
    switch (op) {
      case 'sharing.state':
        if (stateError != null) throw stateError!;
        return _snapshot();
      case 'sharing.setup':
        enabled = true;
        return _snapshot();
      case 'sharing.set_kind':
        final kind = args['kind'] as String;
        if (!table.containsKey(kind)) throw CacheSearchException('bad_args', 'No such kind to share: $kind');
        if (args['on'] == true) {
          off.remove(kind);
          await _addKind(kind);
        } else {
          for (final id in table[kind]!.keys) {
            if (_shared(id)) await sync.call('share_remove', {'id': id, 'keep_history': true});
          }
        }
        return _snapshot();
      case 'sharing.set_item':
        final kind = args['kind'] as String, key = args['key'] as String, on = args['on'] == true;
        final kindOn = table[kind]!.keys.any(_shared);
        if (on && !kindOn) {
          final all = args['all'];
          if (all is! List) throw const CacheSearchException('bad_args', 'Switching an item on in a kind that is off needs "all": every item of the kind');
          off[kind] = {for (final x in all) if (x != key) '$x'};
          await _addKind(kind);
        } else {
          final set = off.putIfAbsent(kind, () => <String>{});
          on ? set.remove(key) : set.add(key);
        }
        return _snapshot();
      case 'sharing.link_start':
        link = {'state': 'linking'};
        _linkCode = args['code'] as String;
        _linkReads = 0;
        return {...link};
      case 'sharing.call':
        final method = args['method'] as String;
        final a = (args['args'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
        if (method == 'status') return sync.call('status');
        if (!allowed.contains(method)) throw CacheSearchException('forbidden', 'Not available from a browser: $method');
        return sync.call(method, a);
    }
    throw CacheSearchException('unsupported', 'No such sharing op: $op');
  }

  @override
  Future<void> close() async {}
}
