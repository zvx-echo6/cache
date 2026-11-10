import 'dart:typed_data';

/// A file on the computer the browser is on. It is only a handle: nothing of it is read into memory until [readAll], which is for
/// small files (a settings file) only.
abstract class LocalFile {
  String get name;
  int get size;

  /// The whole file. Only for a small file; an upload never goes through this.
  Future<Uint8List> readAll();
}

/// An upload under way.
abstract class UploadTask {
  /// Completes with the device's answer (the `result` of its JSON reply). Completes with a [DeviceException] when the device refused
  /// or the connection broke, and with [UploadCancelled] after [cancel].
  Future<Map<String, dynamic>> get done;

  /// Stops sending. The device throws away what it had received.
  void cancel();
}

class UploadCancelled implements Exception {
  const UploadCancelled();
}

typedef UploadProgress = void Function(int sent, int total);

/// Sends a [LocalFile] to the device without reading it into memory.
abstract class Uploader {
  UploadTask start(LocalFile file, {required String kind, required String name, required UploadProgress onProgress});
}

/// Sends a [LocalFile] to an address on the device (the body is the file, streamed; the device wants its `Content-Length`).
abstract class RawUploader {
  UploadTask post(LocalFile file, String url, UploadProgress onProgress);
}

/// Where a file chosen from a folder sat in it, for the files a folder brought ("books/sub/a.pdf"); the file's name when it came alone.
String relativePathOf(LocalFile f) => f is PathedFile ? f.relativePath : f.name;

/// A [LocalFile] that knows where it was in the folder it came from.
abstract class PathedFile implements LocalFile {
  String get relativePath;
}
