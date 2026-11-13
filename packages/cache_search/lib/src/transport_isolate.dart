import 'dart:async';
import 'dart:isolate';

import 'core_dispatch.dart';
import 'core_transport.dart';
import 'errors.dart';

/// The phone's transport: a long-lived background isolate owns the handle and runs the [CoreDispatcher] (a handle is used
/// from one thread at a time, and open, search, read and the jobs can take time).
class IsolateTransport implements CoreTransport {
  IsolateTransport._(this._isolate, this._toWorker, this._fromWorker);

  /// Starts the worker. [native] must be a top-level or static function because it runs inside the worker isolate.
  static Future<IsolateTransport> spawn(CsNativeFactory native) async {
    final rp = ReceivePort();
    final errors = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, [rp.sendPort, native], debugName: 'cache_search', onError: errors.sendPort);
    final events = StreamIterator<dynamic>(rp);
    await events.moveNext();
    final t = IsolateTransport._(isolate, events.current as SendPort, rp);
    errors.listen((dynamic e) => t._failAll(CacheSearchException('internal', 'The search core crashed: ${(e as List).first}')));
    t._errors = errors;
    // The rest of the worker's messages are replies.
    unawaited(() async {
      while (await events.moveNext()) {
        t._onReply(events.current as Map);
      }
    }());
    return t;
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  ReceivePort? _errors;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  /// Each pending call's op and the clock started when it was sent ([CoreCallTimes]).
  final Map<int, (String, Stopwatch)> _sent = {};

  void _onReply(Map m) {
    final id = m['id'] as int;
    final sent = _sent.remove(id);
    if (sent != null) {
      final (op, clock) = sent;
      CoreCallTimes.answered(op, clock.elapsed, Duration(microseconds: (m['runUs'] as int?) ?? 0));
    }
    final c = _pending.remove(id);
    if (c == null) return;
    final err = m['error'];
    if (err is List) {
      c.completeError(CacheSearchException(err[0] as String, err[1] as String));
    } else {
      c.complete(m['result']);
    }
  }

  void _failAll(CacheSearchException e) {
    for (final c in _pending.values) {
      c.completeError(e);
    }
    _pending.clear();
    _sent.clear();
  }

  @override
  Future<dynamic> call(String op, Map<String, dynamic> args) {
    final id = _nextId++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _sent[id] = (op, Stopwatch()..start());
    _toWorker.send({'id': id, 'op': op, 'args': args});
    return c.future;
  }

  @override
  Future<void> close() async {
    _failAll(const CacheSearchException('internal', 'The search core is closed'));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _fromWorker.close();
    _errors?.close();
  }
}

void _workerMain(List<dynamic> init) {
  final toMain = init[0] as SendPort;
  final dispatcher = CoreDispatcher(init[1] as CsNativeFactory);
  final rp = ReceivePort();
  toMain.send(rp.sendPort);

  rp.listen((dynamic m) {
    final msg = m as Map;
    final id = msg['id'] as int;
    final a = (msg['args'] as Map).cast<String, dynamic>();
    // How long the call ran here; the rest of its time on the main side was the wait in this queue.
    final ran = Stopwatch()..start();
    try {
      final result = dispatcher.handle(msg['op'] as String, a);
      toMain.send({'id': id, 'result': result, 'runUs': ran.elapsedMicroseconds});
    } on CacheSearchException catch (e) {
      toMain.send({'id': id, 'error': [e.code, e.message], 'runUs': ran.elapsedMicroseconds});
    } catch (e) {
      toMain.send({'id': id, 'error': ['internal', e.toString()], 'runUs': ran.elapsedMicroseconds});
    }
  });
}
