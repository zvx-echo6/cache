import 'dart:async';
import 'dart:convert';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../../../packages/cache_search/lib/src/wire.dart';

/// An op family the helper answers itself, before the core dispatcher (`fs.*`, and the helper's own `open`).
abstract class OpHandler {
  bool handles(String op);

  /// The plain result (Uint8List allowed), or throws a [CacheSearchException]. A handler that waits (the sharing host) returns
  /// a Future; the line protocol still answers one request at a time, so the next line is read after this one's reply.
  FutureOr<Object?> handle(String op, Map<String, dynamic> args);
}

/// Cache for Linux's helper protocol: UTF-8 lines on [input] and [output], one JSON object per line.
///
/// Prints `{"ready":true}` first. A request is `{"id":<int>,"op":<string>,"args":{...}}`; the reply is
/// `{"id":<int>,"ok":true,"result":<json>}` or `{"id":<int>,"ok":false,"error":{"code","message"}}`. Byte arrays travel as
/// `{"$bytes": "<base64>"}` (wire.dart). Requests are handled strictly one at a time, in order. When [input] ends, the core
/// is closed and this returns; [onEnd] runs first (the sharing host stops its engine). [log] gets diagnostics (the real helper
/// writes them to stderr).
Future<void> serveLines(
  Stream<List<int>> input,
  FutureOr<void> Function(String line) output,
  CoreDispatcher dispatcher, {
  void Function(String message)? log,
  List<OpHandler> handlers = const [],
  FutureOr<void> Function()? onEnd,
}) async {
  await output(jsonEncode({'ready': true}));
  final lines = input.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    await output(await handleLine(line, dispatcher, log: log, handlers: handlers));
  }
  try {
    await onEnd?.call();
  } catch (e) {
    log?.call('stopping at end of input failed: $e');
  }
  try {
    dispatcher.handle('close', const {});
  } catch (e) {
    log?.call('close at end of input failed: $e');
  }
}

/// One request line in, the reply line out.
Future<String> handleLine(String line, CoreDispatcher dispatcher, {void Function(String message)? log, List<OpHandler> handlers = const []}) async {
  Object? id;
  try {
    final req = jsonDecode(line);
    if (req is! Map) throw const CacheSearchException('bad_json', 'A request is a JSON object');
    id = req['id'];
    final op = req['op'];
    if (op is! String) throw const CacheSearchException('bad_json', 'A request needs an "op"');
    final rawArgs = wireDecode(req['args'] ?? const {});
    if (rawArgs is! Map) throw const CacheSearchException('bad_json', 'A request\'s "args" is a JSON object');
    final args = rawArgs.cast<String, dynamic>();
    Object? result;
    OpHandler? own;
    for (final h in handlers) {
      if (h.handles(op)) {
        own = h;
        break;
      }
    }
    result = own != null ? await own.handle(op, args) : dispatcher.handle(op, args);
    return jsonEncode({'id': id, 'ok': true, 'result': wireEncode(result)});
  } on CacheSearchException catch (e) {
    return _error(id, e.code, e.message);
  } on FormatException catch (e) {
    log?.call('bad request line: $e');
    return _error(id, 'bad_json', e.message);
  } catch (e) {
    log?.call('request failed: $e');
    return _error(id, 'internal', e.toString());
  }
}

String _error(Object? id, String code, String message) =>
    jsonEncode({'id': id, 'ok': false, 'error': {'code': code, 'message': message}});
