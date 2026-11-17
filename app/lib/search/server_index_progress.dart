import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../browse/web/build_api.dart' show QueueItem;
import '../browse/web/build_state.dart' show BuildController;
import '../browse/web/build_text.dart' show queueStateWords;
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

  /// The work's name from the server's key ("seal:zim/ID", "zim-epub/ID", or a ZIM's path): the ZIM's title; null when not known.
  final String? Function(String key)? titleOf;

  /// The server's index queue (`_queue`) and the library builds the Library already reads (see [attachBuilds]), as items.
  List<IndexItem> _qItems = const [];
  List<IndexItem> _bItems = const [];
  List<IndexItem> _items = const [];
  int _qDone = 0;
  int _qTotal = 0;
  int _done = 0;
  int _total = 0;
  BuildController? _build;

  /// The libraries seen being built since the last time all was done (key, title); the ones no longer building are done.
  final Map<String, String> _seenBuilds = {};
  String _bSig = '';

  /// The server's library build queue is paused and has work (the Library's banner Pause, or this sheet's Pause all).
  bool _buildPaused = false;
  IndexWait _hold = IndexWait.none;
  bool _paused = false;
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

  /// In a browser the server builds a library from PDFs outside the index queue: the Library's own build poll (BuildController, read
  /// every 2 seconds while books are built) already knows it. Each library being built is one piece of work (`library/<id>`, as on
  /// a phone), with the books done of all; the book being built says its step ("Building passages · 16 of 308"). No poller of its own.
  void attachBuilds(BuildController build) {
    _build?.removeListener(_onBuild);
    _build = build..addListener(_onBuild);
    _onBuild();
  }

  @override
  void dispose() {
    _build?.removeListener(_onBuild);
    super.dispose();
  }

  void _onBuild() {
    final b = _build;
    if (b == null) return;
    final now = <String, (String, List<QueueItem>)>{};
    for (final l in b.libraries) {
      final items = b.itemsOf(l.id);
      if (items.any((i) => !i.finished)) now['library/${l.id}'] = (l.title, items);
    }
    // a new batch of building after all was done starts the count again
    if (now.isNotEmpty && _bItems.every((i) => i.state == IndexState.done)) _seenBuilds.clear();
    for (final e in now.entries) {
      _seenBuilds[e.key] = e.value.$1;
    }
    _buildPaused = b.queue.paused && now.isNotEmpty;
    final out = <IndexItem>[];
    for (final e in _seenBuilds.entries) {
      final cur = now[e.key];
      if (cur == null) {
        out.add(IndexItem(key: e.key, state: IndexState.done, title: e.value, kindOverride: 'library'));
        continue;
      }
      final items = cur.$2;
      final active = items.where((i) => i.active).firstOrNull;
      final finished = items.where((i) => i.finished).length;
      // the build queue paused (from here or the Library's banner): the same paused words as any work the person paused
      out.add(IndexItem(
        key: e.key,
        state: _buildPaused ? IndexState.held : (active != null ? IndexState.running : IndexState.queued),
        title: e.value,
        why: _buildPaused ? IndexWait.person : IndexWait.none,
        position: _buildPaused ? 1 : 0,
        progress: (finished, items.length),
        step: active == null || _buildPaused ? null : queueStateWords(active),
        kindOverride: 'library',
      ));
    }
    final sig = out.map((i) => '${i.key}|${i.state}|${i.progress}|${i.step}').join(';') + '|$_buildPaused';
    if (sig == _bSig) return;
    _bSig = sig;
    _bItems = out;
    _compose();
    notifyListeners();
  }

  /// The server's queue and the builds together: running first, then what waits, then what is done.
  void _compose() {
    int rank(IndexItem i) => i.state == IndexState.running ? 0 : (i.state == IndexState.done ? 2 : 1);
    final all = [..._qItems, ..._bItems];
    final sorted = [for (final r in [0, 1, 2]) ...all.where((i) => rank(i) == r)];
    _items = sorted;
    final bDone = _bItems.where((i) => i.state == IndexState.done).length;
    _done = _qDone + bDone;
    _total = _qTotal + _bItems.length;
  }

  void _read(Object? queue) {
    _lastQueue = queue;
    if (queue is! Map || queue['items'] is! List) {
      _qItems = const [];
      _qDone = _qTotal = 0;
      _compose();
      return;
    }
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
    _qItems = out;
    _qDone = (queue['done'] as num?)?.toInt() ?? out.where((i) => i.state == IndexState.done).length;
    _qTotal = (queue['total'] as num?)?.toInt() ?? out.length;
    _compose();
  }

  @override
  List<IndexItem> get items => _items;

  @override
  bool get busy => _total > 0 && _done < _total;

  @override
  bool get pausedAll => _paused || _buildPaused;

  @override
  int get doneCount => _done;

  @override
  int get totalCount => _total;

  @override
  String? get running => _items.where((i) => i.state == IndexState.running).firstOrNull?.key;

  @override
  IndexWait get reason {
    if (_paused || _buildPaused) return IndexWait.person;
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
    final b = _build;
    // both: the index queue (index.pause) and the library build queue (the Library banner's Pause)
    await Future.wait([
      if (!_paused) () async { setPausedState(true); await setPaused(true); }(),
      if (b != null && !_buildPaused && _bItems.any((i) => i.state != IndexState.done)) b.pause(),
    ]);
  }

  @override
  Future<void> resumeAll() async {
    final b = _build;
    await Future.wait([
      if (_paused) () async { setPausedState(false); await setPaused(false); }(),
      if (b != null && _buildPaused) b.resume(),
    ]);
  }

  @override
  Future<void> retry(String key) => retryKey(key);
}
