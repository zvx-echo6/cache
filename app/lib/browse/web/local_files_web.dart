import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'device_api.dart' show DeviceException;
import 'local_files_base.dart';

/// A file the person chose or dropped. It stays a browser `File` (a Blob): it is read only by the upload, which streams it.
class WebLocalFile implements LocalFile {
  WebLocalFile(this.file);

  final web.File file;

  @override
  String get name => file.name;

  @override
  int get size => file.size;

  @override
  Future<Uint8List> readAll() async => (await file.arrayBuffer().toDart).toDart.asUint8List();
}

/// Opens the browser's file chooser. Call it straight from the tap (a browser allows the chooser only then): nothing may be awaited
/// before it. Null when the person closes the chooser without a file.
Future<LocalFile?> pickLocalFile({List<String> accept = const []}) {
  final done = Completer<LocalFile?>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = accept.join(',');
  input.style.display = 'none';
  void finish(LocalFile? f) {
    if (!done.isCompleted) done.complete(f);
    input.remove();
  }

  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      finish(files == null || files.length == 0 ? null : WebLocalFile(files.item(0)!));
    }).toJS,
  );
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
  web.document.body!.append(input);
  input.click();
  return done.future;
}

/// A file that came out of a folder: it keeps its place in the folder.
class WebPathedFile extends WebLocalFile implements PathedFile {
  WebPathedFile(super.file, this.relativePath);

  @override
  final String relativePath;
}

/// Opens the browser's chooser for several files, or for a whole folder with [directory] (every file inside it, subfolders too). Call
/// it straight from the tap. An empty list when the person closes the chooser.
Future<List<LocalFile>> pickLocalFiles({List<String> accept = const [], bool directory = false}) {
  final done = Completer<List<LocalFile>>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..multiple = true
    ..accept = directory ? '' : accept.join(',');
  if (directory) (input as JSObject)['webkitdirectory'] = true.toJS;
  input.style.display = 'none';
  void finish(List<LocalFile> f) {
    if (!done.isCompleted) done.complete(f);
    input.remove();
  }

  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      final out = <LocalFile>[];
      if (files != null) {
        for (var i = 0; i < files.length; i++) {
          final f = files.item(i)!;
          final rel = (f as JSObject)['webkitRelativePath'];
          final path = rel.isA<JSString>() ? (rel as JSString).toDart : '';
          out.add(path.isEmpty ? WebLocalFile(f) : WebPathedFile(f, path));
        }
      }
      finish(out);
    }).toJS,
  );
  input.addEventListener('cancel', ((web.Event _) => finish(const [])).toJS);
  web.document.body!.append(input);
  input.click();
  return done.future;
}

/// The upload of a file to any address on the device (the body is the file, streamed by the browser).
RawUploader createRawUploader() => _RawXhrUploader();

class _RawXhrUploader implements RawUploader {
  @override
  UploadTask post(LocalFile file, String url, UploadProgress onProgress) {
    if (file is! WebLocalFile) throw ArgumentError('A browser upload needs a file from the browser');
    return _XhrTask(file.file, url, onProgress);
  }
}

/// The upload of a file to the device with an XMLHttpRequest: the `File` is the request body, so the browser streams it from the
/// disk and never holds it in memory, and `upload.onprogress` says how much has gone.
Uploader createBrowserUploader() => _XhrUploader();

class _XhrUploader implements Uploader {
  @override
  UploadTask start(LocalFile file, {required String kind, required String name, required UploadProgress onProgress}) {
    if (file is! WebLocalFile) throw ArgumentError('A browser upload needs a file from the browser');
    return _XhrTask(file.file, '/api/library/upload?kind=${Uri.encodeComponent(kind)}&name=${Uri.encodeComponent(name)}', onProgress);
  }
}

class _XhrTask implements UploadTask {
  _XhrTask(web.File file, String url, UploadProgress onProgress) {
    _xhr.open('POST', url);
    _xhr.upload.addEventListener(
      'progress',
      ((web.ProgressEvent e) => onProgress(e.loaded, file.size)).toJS,
    );
    _xhr.addEventListener(
      'load',
      ((web.Event _) {
        if (_done.isCompleted) return;
        final status = _xhr.status;
        Object? body;
        try {
          body = jsonDecode(_xhr.responseText);
        } catch (_) {}
        if (status >= 200 && status < 300 && body is Map && body['ok'] == true) {
          _done.complete(((body['result'] as Map?) ?? const {}).cast<String, dynamic>());
          return;
        }
        final err = body is Map ? body['error'] : null;
        _done.completeError(
          status == 401
              ? const DeviceException('unauthorized', 'Sign in again.', status: 401)
              : DeviceException(err is Map ? '${err['code']}' : 'failed', err is Map ? '${err['message']}' : 'This device answered $status.', status: status),
        );
      }).toJS,
    );
    _xhr.addEventListener(
      'error',
      ((web.Event _) {
        if (!_done.isCompleted) _done.completeError(const DeviceException('interrupted', 'The connection was lost.'));
      }).toJS,
    );
    _xhr.addEventListener(
      'abort',
      ((web.Event _) {
        if (!_done.isCompleted) _done.completeError(const UploadCancelled());
      }).toJS,
    );
    _xhr.send(file);
  }

  final web.XMLHttpRequest _xhr = web.XMLHttpRequest();
  final Completer<Map<String, dynamic>> _done = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> get done => _done.future;

  @override
  void cancel() => _xhr.abort();
}

/// Files dropped anywhere on the page. [onActive] says whether a file is being dragged over the page now; [onDrop] gets every file
/// dropped, and the files inside any folder dropped. The browser does not tell the name or size of a file until it is dropped.
class DropListener {
  DropListener({required this.onActive, required this.onDrop}) {
    web.window.addEventListener('dragenter', _enter);
    web.window.addEventListener('dragover', _over);
    web.window.addEventListener('dragleave', _leave);
    web.window.addEventListener('drop', _drop);
  }

  final void Function(bool active) onActive;
  final void Function(List<LocalFile> files) onDrop;
  int _depth = 0;

  static bool _hasFiles(web.DragEvent e) {
    final types = e.dataTransfer?.types;
    if (types == null) return false;
    for (var i = 0; i < types.length; i++) {
      if (types[i].toDart == 'Files') return true;
    }
    return false;
  }

  late final JSFunction _enter = ((web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault();
    _depth++;
    onActive(true);
  }).toJS;

  late final JSFunction _over = ((web.DragEvent e) {
    if (_hasFiles(e)) e.preventDefault();
  }).toJS;

  late final JSFunction _leave = ((web.DragEvent e) {
    if (!_hasFiles(e)) return;
    _depth = _depth > 0 ? _depth - 1 : 0;
    if (_depth == 0) onActive(false);
  }).toJS;

  late final JSFunction _drop = ((web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault();
    _depth = 0;
    onActive(false);
    final dt = e.dataTransfer;
    if (dt == null) return;
    // The entries of the drop are only valid until this handler returns, so they are taken now and walked afterwards.
    final entries = <web.FileSystemEntry>[];
    final items = dt.items;
    for (var i = 0; i < items.length; i++) {
      final entry = items[i].webkitGetAsEntry();
      if (entry != null) entries.add(entry);
    }
    final plain = <LocalFile>[
      for (var i = 0; i < dt.files.length; i++) WebLocalFile(dt.files.item(i)!),
    ];
    () async {
      final out = <LocalFile>[];
      try {
        for (final entry in entries) {
          await _walk(entry, '', out);
        }
      } catch (_) {
        out.clear();
      }
      final files = out.isNotEmpty ? out : plain;
      if (files.isNotEmpty) onDrop(files);
    }();
  }).toJS;

  static Future<void> _walk(web.FileSystemEntry entry, String parent, List<LocalFile> out) async {
    final path = parent.isEmpty ? entry.name : '$parent/${entry.name}';
    if (entry.isFile) {
      final c = Completer<web.File>();
      (entry as web.FileSystemFileEntry).file(((web.File f) => c.complete(f)).toJS, ((JSAny _) => c.completeError('unreadable')).toJS);
      final f = await c.future;
      out.add(parent.isEmpty ? WebLocalFile(f) : WebPathedFile(f, path));
    } else if (entry.isDirectory) {
      final reader = (entry as web.FileSystemDirectoryEntry).createReader();
      while (true) {
        final c = Completer<List<web.FileSystemEntry>>();
        reader.readEntries(
          ((JSArray<web.FileSystemEntry> a) => c.complete(a.toDart)).toJS,
          ((JSAny _) => c.completeError('unreadable')).toJS,
        );
        final batch = await c.future;
        if (batch.isEmpty) break;
        for (final child in batch) {
          await _walk(child, path, out);
        }
      }
    }
  }

  void dispose() {
    web.window.removeEventListener('dragenter', _enter);
    web.window.removeEventListener('dragover', _over);
    web.window.removeEventListener('dragleave', _leave);
    web.window.removeEventListener('drop', _drop);
  }
}

final JSFunction _beforeUnload = ((web.Event e) {
  e.preventDefault();
  (e as JSObject)['returnValue'] = ''.toJS;
}).toJS;

/// While [on], the browser asks "Leave site?" before the tab is closed or reloaded (an upload is running).
void setLeaveWarning(bool on) {
  if (on) {
    web.window.addEventListener('beforeunload', _beforeUnload);
  } else {
    web.window.removeEventListener('beforeunload', _beforeUnload);
  }
}
