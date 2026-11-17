import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/battery.dart';
import 'index_scheduler.dart';
import 'index_status.dart' show indexDoingWords, indexStatusLine;

/// In a browser: the server's index work, as the overview line and the queue sheet show it (the same as on a phone). The server
/// does the work; this only holds what its `index.state` said last (the `_queue` it adds, and its `hold`), and passes the
/// person's Pause all, Resume and Retry on to it. SourcesState's one `index.state` watcher hands every answer to [update]: there is
/// no poller of its own. A server that sends no `_queue` (an older one) leaves this with no work, so nothing is shown.
class ServerIndexProgress extends ChangeNotifier implements IndexProgress {
  ServerIndexProgress({required this.setPaused, required this.retryKey, this.titleOf});

  /// Pause all (true) or Resume (false), as `index.pause` does it.
  final Future<void> Function(bool paused) setPaused;

  /// `index.retry` for the work [key] (the server's own key).
  final Future<void> Function(String key) retryKey;

  /// The work's name from the server's key ("seal:zim/<id>", "zim-epub/<id>", or a ZIM's path): the ZIM's title; null when not known.
  final String? Function(String key)? titleOf;

  List<IndexItem> _items = const [];
  int _done = 0;
  int _total = 0;
  IndexWait _hold = IndexWait.none;
  bool _paused = false;
  bool _have = false;
  String _sig = '';

  /// What the server's step names, as the phone's kinds of work say them.
  static String kindOfStep(String? step, String key) => switch (step) {
    'pdfs' => 'zim-pdf',
    'epubs' => 'zim-epub',
    'captions' => 'zim-captions',
    'keywords' || 'seal' => 'zim',
    _ => key.contains('/') ? key.substring(0, key.indexOf('/')) : key,
  };

  /// The server's answer to `index.state`: its `_queue` (null when it has none) and its hold ("heat" or "memory", null for none).
  void update(Object? queue, {String? hold}) {
    final sig = '${queue == null ? '-' : jsonEncode(queue)}|${hold ?? ''}|$_paused';
    if (sig == _sig) return;
    _sig = sig;
    _hold = switch (hold) {
      'heat' => IndexWait.heat,
      'memory' => IndexWait.memory,
      _ => IndexWait.none,
    };
    _read(queue);
    notifyListeners();
  }

  /// The person's Pause all, as the server last said it.
  void setPausedState(bool paused) {
    if (paused == _paused) return;
    _paused = paused;
    _sig = '';
    _read(_lastQueue);
    notifyListeners();
  }

  Object? _lastQueue;

  void _read(Object? queue) {
    _lastQueue = queue;
    if (queue is! Map || queue['items'] is! List) {
      _have = false;
      _items = const [];
      _done = _total = 0;
      return;
    }
    _have = true;
    final out = <IndexItem>[];
    var place = 0;
    for (final raw in queue['items'] as List) {
      if (raw is! Map || raw['key'] is! String) continue;
      final key = raw['key'] as String;
      final step = raw['step'] as String?;
      final kind = kindOfStep(step, key);
      final d = raw['done'] as num?, t = raw['total'] as num?;
      final progress = d != null && t != null && t > 0 ? (d.toInt(), t.toInt()) : null;
      final title = titleOf?.call(key) ?? '';
      final state = raw['state'];
      if (state == 'done') {
        out.add(IndexItem(key: key, state: IndexState.done, title: title, kindOverride: kind));
      } else if (state == 'stuck' || state == 'failed') {
        out.add(IndexItem(key: key, state: IndexState.held, title: title, why: IndexWait.stuck, position: ++place, progress: progress, step: indexDoingWords(kind), kindOverride: kind));
      } else if (state == 'running' && !_paused) {
        out.add(IndexItem(key: key, state: IndexState.running, title: title, why: _hold, progress: progress, kindOverride: kind));
      } else {
        // queued (and, while the person has paused it all, what ran too): nothing runs, the person's pause is the reason
        out.add(IndexItem(key: key, state: _paused ? IndexState.held : IndexState.queued, title: title, why: _paused ? IndexWait.person : IndexWait.none, position: ++place, progress: progress, kindOverride: kind));
      }
    }
    _items = out;
    _done = (queue['done'] as num?)?.toInt() ?? out.where((i) => i.state == IndexState.done).length;
    _total = (queue['total'] as num?)?.toInt() ?? out.length;
  }

  @override
  List<IndexItem> get items => _items;

  @override
  bool get busy => _have && _total > 0 && _done < _total;

  @override
  bool get pausedAll => _paused;

  @override
  int get doneCount => _done;

  @override
  int get totalCount => _total;

  @override
  String? get running => _items.where((i) => i.state == IndexState.running).firstOrNull?.key;

  @override
  IndexWait get reason {
    if (_paused) return IndexWait.person;
    if (_hold != IndexWait.none) return _hold;
    for (final i in _items) {
      if (i.why != IndexWait.none) return i.why;
    }
    return IndexWait.none;
  }

  @override
  BatteryReading? get reading => null;

  @override
  bool get deviceWarm => false;

  @override
  double get fraction {
    if (_total <= 0) return 1;
    var sum = 0.0;
    for (final i in _items) {
      final p = i.progress;
      if (i.state == IndexState.done) {
        sum += 1;
      } else if (p != null && p.$2 > 0) {
        sum += (p.$1 / p.$2).clamp(0.0, 1.0);
      }
    }
    return (sum / _total).clamp(0.0, 1.0);
  }

  @override
  String? get line => indexStatusLine(this);

  @override
  IndexItem? statusOf(String key) => _items.where((i) => i.key == key).firstOrNull;

  @override
  Future<void> pauseAll() async {
    if (_paused) return;
    setPausedState(true);
    await setPaused(true);
  }

  @override
  Future<void> resumeAll() async {
    if (!_paused) return;
    setPausedState(false);
    await setPaused(false);
  }

  @override
  Future<void> retry(String key) => retryKey(key);
}
