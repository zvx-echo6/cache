import 'dart:convert';

import '../../../packages/cache_search/lib/src/engine.dart' show CoreJob;
import '../../../packages/cache_search/lib/src/errors.dart';
import '../../../packages/cache_search/lib/src/models.dart' show JobState;
import '../../../packages/cache_search/lib/src/native_api.dart';
import 'core_open.dart' show AppDirs;
import 'line_protocol.dart';

/// The `video.*` ops: the browser's VideoCore (cache_search video_core_web.dart). The phone's VideoCore opens a core handle of its
/// own whose `video` folder is `<files>/videos`; this does the same on the server, on `<docs>/videos`, with the `indexes_dir` of the
/// engine (`<support>/indexes`), and keeps the download jobs, which run in the core's own threads, so a download goes on with no tab
/// open. Not core ops; the helper answers them before the core dispatcher.
///
///   video.info {}                          -> {dir}     the saved videos' folder (absolute)
///   video.call {op, request}               -> the JSON string `cs_video_<op>` returns (`request` a JSON string, "" for none)
///   video.jobStart {instance, video, choice?, token?, title?, label?}
///                                          -> {job}     a download; one already running for the same video is returned as it is
///   video.jobProgress {job}                -> {state, done, total, error}      (the same shape the dispatcher's jobProgress has)
///   video.jobCancel {job}                  -> null      stops it, the partial file stays (Pause); starting again continues it
///   video.jobFree {job}                    -> null      lets a finished, cancelled or failed job go
///   video.jobs {}                          -> [{job, instance, video, choice, title, label, state, done, total, error}]
///                                              every job the helper holds, so a tab opened later sees them
/// Errors are the core's own ({code, message}).
class VideoOps implements OpHandler {
  VideoOps(this.dirs, this.factory, {this.log, this.resolve});

  final AppDirs dirs;
  final CsNative Function() factory;
  final void Function(String message)? log;

  /// Swaps the keystore references (`keystore://<name>`) in a value for the stored keys. The core hook never sees `video.*` (this
  /// handler answers it), so the browser's tokens are swapped here, in `video.call`'s request and `video.jobStart`'s token. Null: no swap.
  final Object? Function(Object? value)? resolve;

  /// The finished, cancelled and failed jobs kept at most (a tab frees them as it sees them; this only bounds one that never does).
  static const int keepStopped = 50;

  CsNative? _native;
  int _handle = 0;
  final Map<int, _Entry> _jobs = {};
  int _next = 1;

  String get dir => '${dirs.docs.path}/videos';

  @override
  bool handles(String op) => op.startsWith('video.');

  CsNative _open() {
    final existing = _native;
    if (existing != null && _handle != 0) return existing;
    final n = _native ??= factory();
    final cfg = {
      'sources': <Object>[],
      'video': {'dir': dir},
      'indexes_dir': '${dirs.support.path}/indexes',
    };
    _handle = n.open(jsonEncode(cfg));
    if (_handle == 0) throw CacheSearchException.fromJson(n.lastError(0));
    return n;
  }

  @override
  Object? handle(String op, Map<String, dynamic> a) {
    switch (op) {
      case 'video.info':
        _open();
        return {'dir': dir};
      case 'video.call':
        final n = _open();
        final r = n.video(_handle, a['op'] as String, _swapRequest((a['request'] as String?) ?? ''));
        return r ?? (throw CacheSearchException.fromJson(n.lastError(_handle)));
      case 'video.jobStart':
        return _start(a);
      case 'video.jobProgress':
        return _progress(_entry(a['job']));
      case 'video.jobCancel':
        _entry(a['job']).job.cancel();
        return null;
      case 'video.jobFree':
        final e = _jobs.remove(a['job']);
        e?.job.free();
        return null;
      case 'video.jobs':
        return [
          for (final e in _jobs.entries.toList())
            {
              'job': e.key,
              'instance': e.value.instance,
              'video': e.value.video,
              'choice': e.value.choice,
              'title': e.value.title,
              'label': e.value.label,
              ..._progress(e.value),
            }
        ];
    }
    throw CacheSearchException('internal', 'Unknown call $op');
  }

  /// [request] (a JSON string) with its references swapped; one that is not a JSON object goes on as it is.
  String _swapRequest(String request) {
    final r = resolve;
    if (r == null || !request.contains('keystore://')) return request;
    final Object? j;
    try {
      j = jsonDecode(request);
    } catch (_) {
      return request;
    }
    return jsonEncode(r(j));
  }

  _Entry _entry(Object? id) => _jobs[id] ?? (throw const CacheSearchException('not_found', 'No such download'));

  Map<String, dynamic> _progress(_Entry e) {
    final p = e.job.progress();
    return {
      'state': p.state.name,
      'done': p.done,
      'total': p.total,
      'error': p.errorCode == null ? null : {'code': p.errorCode, 'message': p.errorMessage},
    };
  }

  Object? _start(Map<String, dynamic> a) {
    final n = _open();
    final instance = a['instance'] as String, video = a['video'] as String;
    final choice = (a['choice'] as String?) ?? 'lowest';
    // The same video again while it runs (two tabs): that job.
    for (final e in _jobs.entries) {
      final v = e.value;
      if (v.instance == instance && v.video == video && v.job.progress().state == JobState.running) {
        return {'job': e.key};
      }
    }
    // An earlier, stopped job of this video goes: the new one continues from the file.
    for (final k in _jobs.keys.toList()) {
      final v = _jobs[k]!;
      if (v.instance == instance && v.video == video) {
        _jobs.remove(k)?.job.free();
      }
    }
    final params = <String, dynamic>{
      'dir': dir,
      'instance': instance,
      'video': video,
      'choice': choice,
      if (a['token'] != null) 'token': resolve == null ? a['token'] : resolve!(a['token']),
    };
    final job = CoreJob.start(n, 'video_download', params);
    final id = _next++;
    _jobs[id] = _Entry(job, instance, video, choice, (a['title'] as String?) ?? '', (a['label'] as String?) ?? '');
    _prune();
    log?.call('video download started: $instance/$video ($choice)');
    return {'job': id};
  }

  void _prune() {
    final stopped = [
      for (final e in _jobs.entries)
        if (e.value.job.progress().state != JobState.running) e.key,
    ];
    for (var i = 0; i < stopped.length - keepStopped; i++) {
      _jobs.remove(stopped[i])?.job.free();
    }
  }
}

class _Entry {
  _Entry(this.job, this.instance, this.video, this.choice, this.title, this.label);

  final CoreJob job;
  final String instance;
  final String video;
  final String choice;
  final String title;
  final String label;
}
